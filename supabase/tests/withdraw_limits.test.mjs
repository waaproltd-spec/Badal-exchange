// KYC-based withdrawal limits (migrations/*_kyc_withdraw_limits.sql): $50 a day
// and $500 a month without approved KYC, $500 and $5,000 with it; enforced by
// the server for every withdrawal (the app, a direct call, a direct insert);
// deposits untouched; failed / cancelled give the amount back; the day and the
// month start again at Somalia's midnight; requests made at once cannot add up
// past the limit; only management changes the limits. Run with: npm test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const opts = { auth: { persistSession: false, autoRefreshToken: false } };

async function login(phone) {
  const c = createClient(URL, ANON_KEY, opts);
  const { error } = await c.auth.signInWithPassword({ email: `${phone.replace(/\D/g, '')}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}
async function rpc(c, fn, args = {}) {
  const { data, error } = await c.rpc(fn, args);
  if (error) {
    const e = new Error(`${fn}: ${error.message}`);
    e.code = error.hint ?? error.code;
    throw e;
  }
  return data;
}
async function rejects(promise, code) {
  let message;
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `expected ${code}, got ${e.code}: ${e.message}`);
    message = e.message;
    return true;
  });
  return message;
}

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
let manager;
let saved;
const KEYS = ['withdraw_limits', 'withdraw_limit:unverified_daily', 'withdraw_limit:unverified_monthly',
  'withdraw_limit:verified_daily', 'withdraw_limit:verified_monthly'];
const setDefaults = (a, b, c, d) => rpc(manager, 'manage_set_withdraw_limit_settings', {
  p_unverified_daily: a, p_unverified_monthly: b, p_verified_daily: c, p_verified_monthly: d });

async function customer(balanceCents = 3000000) {
  const number = `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Limit Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u RETURNING customer_id`,
    [`252${number}`, PASSWORD, balanceCents]);
  return { c: await login(`252${number}`), number, id: u.customer_id };
}
const withdraw = (cu, amount) => rpc(cu.c, 'customer_create_withdrawal', {
  p_method: 'evc_plus', p_amount: String(amount), p_phone_number: `252${cu.number}`, p_idempotency_key: randomUUID() });
const state = (cu) => rpc(cu.c, 'customer_withdraw_limits');
const approveKyc = (cu) => db.query(
  `INSERT INTO kyc_applications (customer_id, document_type, full_name, document_number, country, status)
   VALUES ($1, 'national_id', 'Limit Test', $2, 'Somalia', 'approved')`, [cu.id, `ID${seed}${n++}`]);
const ageOrders = (cu, interval) => db.query(
  `UPDATE orders SET created_at = created_at - $2::interval WHERE customer_id = $1 AND direction = 'withdraw'`, [cu.id, interval]);

before(async () => {
  manager = await login('252610000002');
  saved = (await db.query(`SELECT key, value FROM app_settings WHERE key = ANY($1)`, [KEYS])).rows;
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'withdraw_limits'`);
  await setDefaults(50, 500, 500, 5000);
});
after(async () => {
  for (const k of KEYS) await db.query(`DELETE FROM app_settings WHERE key = $1`, [k]);
  for (const r of saved) await db.query(`INSERT INTO app_settings (key, value) VALUES ($1, $2)`, [r.key, r.value]);
  await db.query(`UPDATE app_settings SET value = 'off' WHERE key = 'withdraw_limits'`);
  await db.end();
});

test('an unverified customer: $50 a day, asked to complete KYC beyond it', async () => {
  const cu = await customer();
  let s = await state(cu);
  assert.equal(s.kyc.verified, false);
  assert.equal(s.kyc.status, 'not_submitted');
  assert.equal(s.daily.limit, '50.00');
  assert.equal(s.monthly.limit, '500.00');
  assert.equal(s.daily.remaining, '50.00');
  assert.equal(s.askKyc, true);
  assert.equal(s.warning, null);

  const msg = await rejects(withdraw(cu, 60), 'WITHDRAWAL_KYC_REQUIRED');
  assert.match(msg, /KYC/);
  await withdraw(cu, 30);
  s = await state(cu);
  assert.equal(s.daily.used, '30.00');
  assert.equal(s.daily.remaining, '20.00');
  assert.equal(s.availableNow, '20.00');
  await rejects(withdraw(cu, 25), 'WITHDRAWAL_KYC_REQUIRED');
  await withdraw(cu, 16);
  assert.equal((await state(cu)).warning, 'near_daily');
  await withdraw(cu, 4);
  s = await state(cu);
  assert.equal(s.daily.remaining, '0.00');
  assert.equal(s.canWithdraw, false);
  assert.equal(s.warning, 'daily_reached');
  await rejects(withdraw(cu, 1), 'WITHDRAWAL_KYC_REQUIRED');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM orders WHERE customer_id = $1 AND direction = 'withdraw'`, [cu.id]);
  assert.equal(rows[0].n, 3, 'refused withdrawals made no order');
});

test('a direct insert cannot get round the limit, and deposits are never limited', async () => {
  const cu = await customer();
  await assert.rejects(db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
     VALUES ($1, $2, 'withdraw', 'evc_plus', 'pending', 6000, 1, 6000, -6000)`, [`EXWL${seed}${n++}`, cu.id]),
    /KYC/);
  const d = await rpc(cu.c, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '900', p_phone_number: `252${cu.number}`, p_idempotency_key: randomUUID() });
  assert.equal(d.status, 'pending');
  assert.equal((await state(cu)).daily.used, '0.00');
});

test('failed and cancelled withdrawals give their amount back', async () => {
  const cu = await customer();
  await withdraw(cu, 50);
  await rejects(withdraw(cu, 1), 'WITHDRAWAL_KYC_REQUIRED');
  await db.query(`UPDATE orders SET status = 'failed' WHERE customer_id = $1 AND direction = 'withdraw'`, [cu.id]);
  assert.equal((await state(cu)).daily.remaining, '50.00');
  await withdraw(cu, 50);
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE customer_id = $1 AND direction = 'withdraw' AND status = 'pending'`, [cu.id]);
  assert.equal((await state(cu)).daily.remaining, '50.00');
});

test('approved KYC: $500 a day and $5,000 a month; the limit message is no longer about KYC', async () => {
  const cu = await customer();
  await approveKyc(cu);
  const s = await state(cu);
  assert.equal(s.kyc.verified, true);
  assert.equal(s.daily.limit, '500.00');
  assert.equal(s.monthly.limit, '5000.00');
  assert.equal(s.askKyc, false);
  await rejects(withdraw(cu, 501), 'WITHDRAWAL_DAILY_LIMIT');
  await withdraw(cu, 500);
  const msg = await rejects(withdraw(cu, 1), 'WITHDRAWAL_DAILY_LIMIT');
  assert.match(msg, /00:00/);
  assert.equal((await state(cu)).warning, 'daily_reached');
});

test('the daily limit starts again the next day; the monthly one holds across days until the month turns', async () => {
  const cu = await customer();
  await approveKyc(cu);
  await withdraw(cu, 500);
  await ageOrders(cu, '1 day');
  const s = await state(cu);
  const monthStart = new Date((await db.query(`SELECT private.withdraw_month_start() AS m`)).rows[0].m);
  const sameMonth = new Date(Date.now() - 86400000) >= monthStart;
  assert.equal(s.daily.used, '0.00');
  assert.equal(s.monthly.used, sameMonth ? '500.00' : '0.00');
  // A month ago: counts for neither.
  await ageOrders(cu, '40 days');
  const t = await state(cu);
  assert.equal(t.daily.used, '0.00');
  assert.equal(t.monthly.used, '0.00');
  await withdraw(cu, 500);
});

test('the monthly limit stops a customer whose day is still free', async () => {
  const cu = await customer();
  await setDefaults(50, 80, 500, 5000);
  try {
    await withdraw(cu, 50);
    await ageOrders(cu, '1 minute');
    // Day 2 within the same month is not guaranteed: put the first withdrawal at the start of today's month instead.
    await db.query(`UPDATE orders SET created_at = private.withdraw_month_start() WHERE customer_id = $1`, [cu.id]);
    const s = await state(cu);
    if (s.daily.used === '0.00') {
      await withdraw(cu, 30);
      assert.equal((await state(cu)).monthly.remaining, '0.00');
      await rejects(withdraw(cu, 1), 'WITHDRAWAL_MONTHLY_LIMIT');
      assert.equal((await state(cu)).warning, 'monthly_reached');
    }
  } finally {
    await setDefaults(50, 500, 500, 5000);
  }
});

test('requests made at the same moment cannot add up past the limit', async () => {
  const cu = await customer();
  const results = await Promise.allSettled(Array.from({ length: 12 }, () => withdraw(cu, 10)));
  const ok = results.filter((r) => r.status === 'fulfilled').length;
  assert.equal(ok, 5, `exactly $50 went through, got ${ok} requests`);
  assert.equal((await state(cu)).daily.used, '50.00');
});

test('management changes the defaults; nobody else can; bad values are refused', async () => {
  const cu = await customer();
  await rejects(rpc(cu.c, 'manage_set_withdraw_limit_settings', { p_unverified_daily: 1, p_unverified_monthly: 2, p_verified_daily: 3, p_verified_monthly: 4 }), 'FORBIDDEN');
  await rejects(rpc(cu.c, 'manage_withdraw_limit_settings'), 'FORBIDDEN');
  await rejects(rpc(cu.c, 'manage_set_customer_withdraw_limits', { p_customer_id: cu.id, p_daily: 1000 }), 'FORBIDDEN');
  await rejects(setDefaults(600, 500, 500, 5000), 'VALIDATION_ERROR');
  await rejects(setDefaults(-1, 500, 500, 5000), 'VALIDATION_ERROR');
  await setDefaults(20, 200, 400, 4000);
  try {
    const s = await state(cu);
    assert.equal(s.daily.limit, '20.00');
    assert.equal(s.monthly.limit, '200.00');
    await rejects(withdraw(cu, 25), 'WITHDRAWAL_KYC_REQUIRED');
    await withdraw(cu, 20);
    const got = await rpc(manager, 'manage_withdraw_limit_settings');
    assert.equal(got.verifiedDaily, '400.00');
    assert.equal(got.unverifiedMonthly, '200.00');
  } finally {
    await setDefaults(50, 500, 500, 5000);
  }
});

test('a customer\'s own limits replace the defaults for that customer only', async () => {
  const a = await customer();
  const b = await customer();
  const set = await rpc(manager, 'manage_set_customer_withdraw_limits', { p_customer_id: a.id, p_daily: 200, p_monthly: 1000, p_note: 'trusted agent' });
  assert.equal(set.daily.limit, '200.00');
  assert.equal(set.custom.note, 'trusted agent');
  assert.equal(set.askKyc, false);
  await withdraw(a, 150);
  await rejects(withdraw(a, 60), 'WITHDRAWAL_DAILY_LIMIT');
  assert.equal((await state(b)).daily.limit, '50.00');
  // Only a daily one: the monthly limit is still the default.
  const only = await rpc(manager, 'manage_set_customer_withdraw_limits', { p_customer_id: b.id, p_daily: 10 });
  assert.equal(only.daily.limit, '10.00');
  assert.equal(only.monthly.limit, '500.00');
  await rejects(withdraw(b, 11), 'WITHDRAWAL_DAILY_LIMIT');
  await rejects(rpc(manager, 'manage_set_customer_withdraw_limits', { p_customer_id: b.id, p_daily: 600 }), 'VALIDATION_ERROR');
  // Removing them goes back to the defaults.
  const back = await rpc(manager, 'manage_set_customer_withdraw_limits', { p_customer_id: a.id });
  assert.equal(back.daily.limit, '50.00');
  assert.equal(back.custom.daily, false);
  await rejects(rpc(manager, 'manage_set_customer_withdraw_limits', { p_customer_id: randomUUID(), p_daily: 5 }), 'NOT_FOUND');
});

test('management sees a customer\'s KYC status, limits, what is left and their withdrawals', async () => {
  const cu = await customer();
  await withdraw(cu, 12);
  await withdraw(cu, 8);
  const d = await rpc(manager, 'manage_customer_withdraw_limits', { p_customer_id: cu.id });
  assert.equal(d.kyc.status, 'not_submitted');
  assert.equal(d.daily.used, '20.00');
  assert.equal(d.daily.remaining, '30.00');
  assert.equal(d.customer.id, cu.id);
  assert.equal(d.history.length, 2);
  assert.equal(d.history[0].counted, true);
  assert.equal(d.defaults.unverifiedDaily, '50.00');
  // Same numbers as the customer sees.
  const mine = await state(cu);
  assert.deepEqual({ ...mine, custom: undefined }, { ...d, customer: undefined, defaults: undefined, history: undefined, custom: undefined });

  const list = await rpc(manager, 'manage_withdraw_limit_customers', { p_query: cu.number, p_filter: 'all' });
  assert.equal(list.customers.length, 1);
  assert.equal(list.customers[0].dailyUsed, '20.00');
  assert.equal(list.customers[0].dailyRemaining, '30.00');
  assert.equal(list.customers[0].verified, false);
  assert.equal(list.settings.verifiedMonthly, '5000.00');
  assert.equal((await rpc(manager, 'manage_withdraw_limit_customers', { p_query: cu.number, p_filter: 'verified' })).customers.length, 0);
  assert.equal((await rpc(manager, 'manage_withdraw_limit_customers', { p_query: cu.number, p_filter: 'unverified' })).customers.length, 1);
  await rejects(rpc(manager, 'manage_withdraw_limit_customers', { p_filter: 'nope' }), 'VALIDATION_ERROR');
  await rejects(rpc(cu.c, 'manage_withdraw_limit_customers'), 'FORBIDDEN');
  await rejects(rpc(cu.c, 'manage_customer_withdraw_limits', { p_customer_id: cu.id }), 'FORBIDDEN');
});
