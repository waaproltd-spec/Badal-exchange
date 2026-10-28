// Unconfirmed Deposits (migrations/*_unconfirmed_deposits.sql): a deposit
// form the customer has not confirmed, apart from a confirmed request
// waiting for verification; the phone, amount and times as stored; the
// 48-hour overdue mark; never a wallet change; expired ones still listed.
// Run with the other suites: npm test.
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
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `expected ${code}, got ${e.code}: ${e.message}`);
    return true;
  });
}

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
const evcNumber = () => `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
let admin;
async function customer() {
  const number = evcNumber();
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Unconfirmed Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 0 FROM u`, [`252${number}`, PASSWORD]);
  return { c: await login(`252${number}`), number, phone: `252${number}` };
}
const list = async (args = {}) => rpc(admin, 'manage_unconfirmed_deposits', args);
const rowsOf = async (phone, args) => (await list(args)).deposits.filter((d) => d.customerPhone === phone);
const wallet = async (c) => (await rpc(c, 'customer_wallet')).availableBalance;
const ledger = async (phone) => (await db.query(
  `SELECT count(*)::int AS n FROM ledger_entries l JOIN users u ON u.id = l.customer_id WHERE u.phone = $1`, [phone])).rows[0].n;

before(async () => { admin = await login('252610000002'); });
after(() => db.end());

test('A: the form filled in but not confirmed -- its own status, the registered phone, amount and time', async () => {
  const { c, phone } = await customer();
  const t0 = Date.now();
  await rpc(c, 'customer_track_deposit_draft', { p_method: 'evc_plus', p_amount: '5' });
  await rpc(c, 'customer_track_deposit_draft', { p_method: 'evc_plus', p_amount: '12.50' }); // typed on: the same record
  const rows = await rowsOf(phone);
  assert.equal(rows.length, 1, 'one record per form');
  const [r] = rows;
  assert.equal(r.status, 'not_confirmed');
  assert.equal(r.statusText, 'Customer has not confirmed the deposit yet.');
  assert.equal(r.customerPhone, phone, 'the registered number, from the server');
  assert.equal(r.amount, '12.50');
  assert.equal(r.method, 'evc_plus');
  assert.equal(r.orderId, null);
  assert.ok(Math.abs(new Date(r.startedAt).getTime() - t0) < 60_000, r.startedAt);
  assert.ok(r.waitingSeconds >= 0 && r.waitingSeconds < 60);
  assert.equal(r.overdue, false);
  assert.equal(await wallet(c), '0.00', 'nothing credited');
  assert.equal(await ledger(phone), 0, 'no ledger entry');
});

test('B: "Confirm Deposit" pressed -- Pending Admin Verification, the same start time, still nothing credited', async () => {
  const { c, number, phone } = await customer();
  const draft = await rpc(c, 'customer_track_deposit_draft', { p_method: 'evc_plus', p_amount: '8' });
  await db.query(`UPDATE deposit_drafts SET started_at = now() - interval '3 minutes' WHERE id = $1`, [draft.id]);
  const order = await rpc(c, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '8', p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
  const rows = await rowsOf(phone);
  assert.equal(rows.length, 1, 'the form became the request: not listed twice');
  const [r] = rows;
  assert.equal(r.status, 'pending_verification');
  assert.equal(r.statusText, 'Pending Admin Verification.');
  assert.equal(r.orderId, order.id);
  assert.equal(r.orderCode, order.orderCode);
  assert.equal(r.amount, '8.00');
  assert.ok(r.waitingSeconds >= 180, 'waiting since the form was started');
  assert.ok(new Date(r.submittedAt) > new Date(r.startedAt));
  assert.equal(await wallet(c), '0.00', 'pressing Confirm credits nothing');
  assert.equal(await ledger(phone), 0);
});

test('48 hours: overdue, still listed; a new form after that is a new record', async () => {
  const { c, phone } = await customer();
  const d = await rpc(c, 'customer_track_deposit_draft', { p_method: 'edahab', p_amount: '3' });
  await db.query(`UPDATE deposit_drafts SET started_at = now() - interval '47 hours', updated_at = now() - interval '47 hours' WHERE id = $1`, [d.id]);
  assert.equal((await rowsOf(phone))[0].overdue, false, 'not before 48 hours');
  await db.query(`UPDATE deposit_drafts SET started_at = now() - interval '49 hours' WHERE id = $1`, [d.id]);
  let rows = await rowsOf(phone);
  assert.equal(rows.length, 1);
  assert.deepEqual([rows[0].status, rows[0].overdue], ['not_confirmed', true]);
  assert.ok(rows[0].waitingSeconds >= 49 * 3600);
  assert.ok((await list()).summary.overdue >= 1, 'counted as overdue');

  // The customer starts again later: a new record; the overdue one stays.
  await rpc(c, 'customer_track_deposit_draft', { p_method: 'edahab', p_amount: '4' });
  rows = await rowsOf(phone);
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((r) => [r.amount, r.overdue]).sort(), [['3.00', true], ['4.00', false]]);
});

test('an expired request stays for review, marked unpaid; a pending one over 48 hours is overdue', async () => {
  const { c, number, phone } = await customer();
  const a = await rpc(c, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '2', p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
  await db.query(`UPDATE orders SET status = 'expired', failure_reason = 'Not paid in time' WHERE id = $1`, [a.id]);
  const b = await rpc(c, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '6', p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
  await db.query(`UPDATE orders SET created_at = now() - interval '50 hours' WHERE id = $1`, [b.id]);
  const rows = await rowsOf(phone);
  const ra = rows.find((r) => r.orderId === a.id);
  const rb = rows.find((r) => r.orderId === b.id);
  assert.deepEqual([ra.status, ra.overdue], ['expired', false]);
  assert.match(ra.statusText, /Nothing was credited/);
  assert.deepEqual([rb.status, rb.overdue], ['pending_verification', true]);
  // An earlier period still shows the overdue one.
  const old = await rowsOf(phone, { p_from: new Date(Date.now() - 3 * 86400_000).toISOString(), p_to: new Date(Date.now() - 86400_000).toISOString() });
  assert.deepEqual(old.map((r) => r.orderId), [b.id]);
  assert.equal(await wallet(c), '0.00');
});

test('a verified (completed) deposit is a confirmed payment: not in this list', async () => {
  const { c, number, phone } = await customer();
  const o = await rpc(c, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '1', p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
  await db.query(`SELECT private.complete_deposit_order($1, 'TEST-REF', NULL, NULL)`, [o.id]).catch(async () => {
    await db.query(`UPDATE orders SET status = 'completed' WHERE id = $1`, [o.id]);
  });
  assert.equal((await rowsOf(phone)).length, 0);
});

test('only managers see it; the amount is checked; customers cannot read anyone\'s forms', async () => {
  const { c } = await customer();
  await rejects(rpc(c, 'manage_unconfirmed_deposits'), 'FORBIDDEN');
  await rejects(rpc(c, 'customer_track_deposit_draft', { p_method: 'evc_plus', p_amount: 'abc' }), 'VALIDATION_ERROR');
  await rejects(rpc(c, 'customer_track_deposit_draft', { p_method: 'evc_plus', p_amount: '999999' }), 'VALIDATION_ERROR');
  const { error } = await c.from('deposit_drafts').select('*');
  assert.ok(error, 'the table is not readable by customers');
  const plain = createClient(URL, ANON_KEY, opts);
  assert.ok((await plain.rpc('customer_track_deposit_draft', { p_method: 'evc_plus', p_amount: '1' })).error);
});
