// Payment safety (migrations/*_payment_safety.sql): a withdrawal Sahal cannot
// cover is refused before any order exists and nothing is taken (Somali
// message); an unknown balance changes nothing; incidents the app reports are
// kept for the Telegram alerts. Run with the other suites: npm test.
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
const MESSAGE = 'Lacag-bixinta hadda cilad ayaa ka jirta. Fadlan mar kale isku day.';

async function login(phone) {
  const c = createClient(URL, ANON_KEY, opts);
  const { error } = await c.auth.signInWithPassword({ email: `${phone.replace(/\D/g, '')}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}
async function rpc(c, fn, args = {}) {
  const { data, error } = await c.rpc(fn, args);
  if (error) {
    const e = new Error(error.message);
    e.code = error.hint ?? error.code;
    throw e;
  }
  return data;
}

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
let saved;
async function customer(balanceCents = 100000) {
  const number = `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Safety Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u RETURNING customer_id`,
    [`252${number}`, PASSWORD, balanceCents]);
  return { c: await login(`252${number}`), number, id: u.customer_id };
}
const withdraw = (cu, amount, method = 'evc_plus') => rpc(cu.c, 'customer_create_withdrawal', {
  p_method: method, p_amount: String(amount), p_phone_number: `252${cu.number}`, p_idempotency_key: randomUUID() });
const wallet = async (cu) => (await rpc(cu.c, 'customer_wallet')).availableBalance;
const setBalance = (cents, minutesAgo = 0, ok = true) => db.query(
  `INSERT INTO public.sahal_balances (ok, balance_cents, error, checked_at) VALUES ($1, $2, $3, now() - make_interval(mins => $4))`,
  [ok, ok ? cents : null, ok ? null : 'down', minutesAgo]);
/** Cents already waiting for Sahal from other tests, so the room is exactly what a test sets. */
const waiting = async () => Number((await db.query(
  `SELECT COALESCE(sum(net_cents), 0) AS n FROM orders WHERE direction = 'withdraw' AND status IN ('pending', 'processing')
     AND method = ANY ((SELECT methods FROM sahal_payout_settings WHERE id))`)).rows[0].n);

before(async () => {
  saved = {
    settings: (await db.query(`SELECT mode, methods FROM sahal_payout_settings WHERE id`)).rows[0],
    check: (await db.query(`SELECT value FROM app_settings WHERE key = 'withdraw_balance_check'`)).rows[0]?.value,
  };
  await db.query(`UPDATE sahal_payout_settings SET mode = 'live', methods = ARRAY['golis', 'telesom', 'evc_plus']::order_method[] WHERE id`);
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'withdraw_balance_check'`);
});
after(async () => {
  await db.query(`UPDATE sahal_payout_settings SET mode = $1, methods = $2 WHERE id`, [saved.settings.mode, saved.settings.methods]);
  await db.query(`UPDATE app_settings SET value = $1 WHERE key = 'withdraw_balance_check'`, [saved.check ?? 'off']);
  await db.query(`DELETE FROM sahal_balances WHERE checked_at > now() - interval '1 hour' AND (balance_cents IS NULL OR balance_cents < 100000000)`);
  await db.end();
});

test('Sahal cannot cover it: refused before any order, nothing taken, Somali message', async () => {
  const cu = await customer();
  await setBalance((await waiting()) + 500); // $5 free
  await assert.rejects(withdraw(cu, 10), (e) => {
    assert.equal(e.code, 'WITHDRAWAL_PROVIDER_BALANCE');
    assert.equal(e.message, MESSAGE);
    return true;
  });
  assert.equal(await wallet(cu), '1000.00', 'the wallet is untouched');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM orders WHERE customer_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 0, 'no order exists');
});

test('enough balance: it goes on as before; what already waits for Sahal is counted', async () => {
  const cu = await customer();
  await setBalance((await waiting()) + 1500); // $15 free
  const first = await withdraw(cu, 10);
  assert.ok(first.orderCode);
  await assert.rejects(withdraw(cu, 10), (e) => e.code === 'WITHDRAWAL_PROVIDER_BALANCE');
  await withdraw(cu, 5);
});

test('an unknown balance changes nothing: old read, failed read, or a method Sahal does not pay', async () => {
  const cu = await customer();
  await setBalance(0, 20); // 20 minutes old: not trusted
  await withdraw(cu, 3);
  await setBalance(0, 0, false); // the last read failed
  await withdraw(cu, 4);
  await setBalance(0); // a real zero, but edahab is not paid by Sahal
  const e = await withdraw(cu, 5, 'edahab').catch((x) => x);
  assert.notEqual(e.code, 'WITHDRAWAL_PROVIDER_BALANCE');
});

test('with Sahal payouts off nothing is checked', async () => {
  const cu = await customer();
  await db.query(`UPDATE sahal_payout_settings SET mode = 'off' WHERE id`);
  try {
    await setBalance(0);
    await withdraw(cu, 3);
  } finally {
    await db.query(`UPDATE sahal_payout_settings SET mode = 'live' WHERE id`);
  }
});

test('the app reports a failed deposit / withdrawal; it is kept for the Telegram alerts', async () => {
  const cu = await customer();
  await rpc(cu.c, 'customer_report_payment_error', {
    p_direction: 'withdraw', p_method: 'evc_plus', p_amount: '10', p_code: 'WITHDRAWAL_PROVIDER_BALANCE', p_detail: MESSAGE });
  await rpc(cu.c, 'customer_report_payment_error', {
    p_direction: 'deposit', p_method: 'onexbet', p_amount: '7', p_code: 'NETWORK', p_detail: 'timeout' });
  const { rows } = await db.query(
    `SELECT direction, kind, method, amount_text, error_code, alerted_at FROM payment_incidents WHERE customer_id = $1 ORDER BY created_at`, [cu.id]);
  assert.deepEqual(rows.map((r) => [r.direction, r.kind, r.error_code]), [['withdraw', 'blocked', 'WITHDRAWAL_PROVIDER_BALANCE'], ['deposit', 'failed', 'NETWORK']]);
  await assert.rejects(rpc(cu.c, 'customer_report_payment_error', { p_direction: 'sideways', p_method: 'x', p_amount: '1', p_code: 'x' }));
  for (let i = 0; i < 40; i++) {
    await rpc(cu.c, 'customer_report_payment_error', { p_direction: 'deposit', p_method: 'evc_plus', p_amount: '1', p_code: 'X' });
  }
  const { rows: [c] } = await db.query(`SELECT count(*)::int AS n FROM payment_incidents WHERE customer_id = $1`, [cu.id]);
  assert.equal(c.n, 30, 'at most 30 an hour');
});
