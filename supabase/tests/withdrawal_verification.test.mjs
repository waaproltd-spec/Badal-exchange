// Account verification before the first withdrawal
// (migrations/*_withdrawal_verification.sql): refused until an admin
// approves -- in the app and by direct API calls alike --; one request per
// account; approve / reject / restrict with who and when; deposits and
// balances untouched. Run with the other suites: npm test.
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
const evcNumber = () => `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
let manager;
let setting;
let contact;
async function customer(balanceCents = 5000) {
  const number = evcNumber();
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Verify Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u RETURNING customer_id`,
    [`252${number}`, PASSWORD, balanceCents]);
  return { c: await login(`252${number}`), number, id: u.customer_id, phone: `252${number}` };
}
const withdraw = (cu, amount = '5') => rpc(cu.c, 'customer_create_withdrawal', {
  p_method: 'evc_plus', p_amount: amount, p_phone_number: `252${cu.number}`, p_idempotency_key: randomUUID() });
const balance = async (cu) => (await rpc(cu.c, 'customer_wallet')).availableBalance;

before(async () => {
  manager = await login('252610000002');
  setting = (await db.query(`SELECT value FROM app_settings WHERE key = 'withdrawal_verification'`)).rows[0]?.value;
  contact = (await db.query(`SELECT value FROM app_settings WHERE key = 'contact_whatsapp'`)).rows[0]?.value;
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'withdrawal_verification'`);
  await db.query(`UPDATE app_settings SET value = '+252612345678' WHERE key = 'contact_whatsapp'`);
});
after(async () => {
  await db.query(`UPDATE app_settings SET value = $1 WHERE key = 'withdrawal_verification'`, [setting ?? 'off']);
  await db.query(`UPDATE app_settings SET value = $1 WHERE key = 'contact_whatsapp'`, [contact ?? '']);
  await db.end();
});

test('first withdrawal of an unverified account: refused with the message and the admin\'s number; nothing taken', async () => {
  const cu = await customer();
  const access = await rpc(cu.c, 'customer_withdrawal_access');
  assert.equal(access.allowed, false);
  assert.equal(access.status, 'pending');
  assert.equal(access.whatsapp, '+252612345678');
  assert.equal(access.phone, cu.phone);
  assert.match(access.accountId, /^BX[0-9A-F]{8}$/);
  assert.match(access.message, /^Si aad lacag ula baxdo markii ugu horreysay, fadlan la xiriir maamulka/);
  const message = await rejects(withdraw(cu), 'WITHDRAWAL_VERIFICATION_REQUIRED');
  assert.match(message, /WhatsApp-ka maamulka: \+252612345678/);
  assert.equal(await balance(cu), '50.00', 'the balance is unchanged');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM orders WHERE customer_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 0, 'no order was made');

  // Deposits are not blocked.
  const d = await rpc(cu.c, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '3', p_phone_number: cu.phone, p_idempotency_key: randomUUID() });
  assert.equal(d.status, 'pending');
});

test('a direct API call cannot get round it, and one account has one request', async () => {
  const cu = await customer();
  // Never opened Withdraw in the app: straight to the API.
  await rejects(withdraw(cu), 'WITHDRAWAL_VERIFICATION_REQUIRED');
  // Not even with the service role, inserting the order directly.
  await assert.rejects(db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
     VALUES ($1, $2, 'withdraw', 'evc_plus', 'pending', 100, 1, 100, -100)`, [`EXVF${seed}${n++}`, cu.id]),
    /account-kaaga loo xaqiijiyo/);
  for (let i = 0; i < 3; i++) await rpc(cu.c, 'customer_withdrawal_access');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM withdrawal_approvals WHERE customer_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 1);
  // The customer cannot approve themselves.
  await rejects(rpc(cu.c, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'approve' }), 'FORBIDDEN');
  const { error } = await cu.c.from('withdrawal_approvals').select('*');
  assert.ok(error, 'the table is not readable');
});

test('the admin sees the request with the history, approves; who and when is kept; withdrawals then work as before', async () => {
  const cu = await customer();
  await rpc(cu.c, 'customer_withdrawal_access');
  const list = await rpc(manager, 'manage_withdrawal_verifications', { p_status: 'pending' });
  const req = list.requests.find((r) => r.customerId === cu.id);
  assert.ok(req, 'listed as pending');
  assert.deepEqual([req.phone, req.status, req.balance], [cu.phone, 'pending', '50.00']);
  assert.match(req.accountId, /^BX/);
  assert.ok(req.requestedAt);
  assert.equal(req.deposits.count, 0);

  const before = Date.now();
  const r = await rpc(manager, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'approve' });
  assert.equal(r.status, 'approved');
  assert.ok(Math.abs(new Date(r.decidedAt).getTime() - before) < 60_000);
  const { rows: [a] } = await db.query(`SELECT decided_by FROM withdrawal_approvals WHERE customer_id = $1`, [cu.id]);
  const { rows: [m] } = await db.query(`SELECT id FROM users WHERE phone = '252610000002'`);
  assert.equal(a.decided_by, m.id, 'the admin who approved');
  const approved = (await rpc(manager, 'manage_withdrawal_verifications', { p_status: 'approved' })).requests.find((x) => x.customerId === cu.id);
  assert.ok(approved.decidedBy);

  assert.equal((await rpc(cu.c, 'customer_withdrawal_access')).allowed, true);
  const w = await withdraw(cu, '5');
  assert.equal(w.status, 'pending', 'the existing withdrawal rules from here');
  assert.equal(await balance(cu), '45.00');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'withdrawal_verification.approve' AND entity_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 1);
});

test('rejected with a reason (shown to the customer); restricted again later; approved again', async () => {
  const cu = await customer();
  await rpc(cu.c, 'customer_withdrawal_access');
  await rejects(rpc(manager, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'reject' }), 'VALIDATION_ERROR');
  await rpc(manager, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'reject', p_reason: 'Name does not match' });
  let access = await rpc(cu.c, 'customer_withdrawal_access');
  assert.deepEqual([access.allowed, access.status, access.reason], [false, 'rejected', 'Name does not match']);
  await rejects(withdraw(cu), 'WITHDRAWAL_VERIFICATION_REQUIRED');

  await rpc(manager, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'approve' });
  await withdraw(cu, '1');
  await rpc(manager, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'restrict', p_reason: 'Under review' });
  access = await rpc(cu.c, 'customer_withdrawal_access');
  assert.deepEqual([access.allowed, access.status, access.reason], [false, 'restricted', 'Under review']);
  await rejects(withdraw(cu), 'WITHDRAWAL_VERIFICATION_REQUIRED');
  await rejects(rpc(manager, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'maybe' }), 'VALIDATION_ERROR');
});

test('withdrawals sent at the same time: all refused, no order, nothing taken', async () => {
  const cu = await customer();
  const results = await Promise.allSettled(Array.from({ length: 6 }, () => withdraw(cu, '5')));
  assert.ok(results.every((r) => r.status === 'rejected' && r.reason.code === 'WITHDRAWAL_VERIFICATION_REQUIRED'));
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM orders WHERE customer_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 0);
  assert.equal(await balance(cu), '50.00');
});

test('a customer who already completed a withdrawal goes on as before (no request); restricted, they stop', async () => {
  const cu = await customer();
  await db.query(`UPDATE app_settings SET value = 'off' WHERE key = 'withdrawal_verification'`);
  const w = await withdraw(cu, '5');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'withdrawal_verification'`);
  await db.query(`UPDATE orders SET status = 'completed', completed_at = now() WHERE id = $1`, [w.id]);
  const access = await rpc(cu.c, 'customer_withdrawal_access');
  assert.deepEqual([access.allowed, access.status], [true, 'approved']);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM withdrawal_approvals WHERE customer_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 0, 'no request needed');
  assert.equal((await withdraw(cu, '5')).status, 'pending');
  await rpc(manager, 'manage_decide_withdrawal_verification', { p_customer_id: cu.id, p_decision: 'restrict', p_reason: 'Under review' });
  await rejects(withdraw(cu, '1'), 'WITHDRAWAL_VERIFICATION_REQUIRED');
});

test('switched off: everyone withdraws as before', async () => {
  const cu = await customer();
  await db.query(`UPDATE app_settings SET value = 'off' WHERE key = 'withdrawal_verification'`);
  try {
    assert.equal((await rpc(cu.c, 'customer_withdrawal_access')).allowed, true);
    assert.equal((await withdraw(cu, '2')).status, 'pending');
  } finally {
    await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'withdrawal_verification'`);
  }
});
