// Agent App "Lacagaha Sugaya Xaqiijinta" (migrations/*_deposit_board.sql):
// the summary, the waiting and expired deposits with the customer and the
// time waited, rejecting a waiting deposit (no money moves), and who may.
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
let agent;
async function customer() {
  const number = evcNumber();
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Board Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 0 FROM u`, [`252${number}`, PASSWORD]);
  return { c: await login(`252${number}`), number };
}
const deposit = (c, number, amount) => rpc(c, 'customer_create_deposit', {
  p_method: 'evc_plus', p_amount: String(amount), p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
const board = () => rpc(agent, 'agent_deposit_board', {});

before(async () => { agent = await login('252610000002'); });
after(() => db.end());

test('the board: waiting deposits with the customer and the time waited, and the summary', async () => {
  const { c, number } = await customer();
  const before = await board();
  const d = await deposit(c, number, 7);
  await db.query(`UPDATE orders SET created_at = now() - interval '5 minutes' WHERE id = $1`, [d.id]);
  const b = await board();
  const row = b.deposits.find((x) => x.id === d.id);
  assert.ok(row, 'listed');
  assert.equal(row.customerName, 'Board Test');
  assert.equal(row.customerPhone, `252${number}`);
  assert.equal(row.amount, '7.00');
  assert.ok(row.waitingSeconds >= 300 && row.waitingSeconds < 400, String(row.waitingSeconds));
  assert.equal(b.summary.pendingCount, before.summary.pendingCount + 1);
  assert.equal(Number(b.summary.pendingTotal), Number(before.summary.pendingTotal) + 7);
  assert.equal(b.summary.newCount, before.summary.newCount + 1);
  assert.ok(b.summary.pendingCustomers >= 1);
});

test('an expired one shows in its period with the time it waited; others are not listed', async () => {
  const { c, number } = await customer();
  const d = await deposit(c, number, 3);
  await db.query(`UPDATE orders SET status = 'expired', created_at = now() - interval '40 minutes', updated_at = now() - interval '10 minutes'
                  WHERE id = $1`, [d.id]);
  const b = await board();
  const row = b.deposits.find((x) => x.id === d.id);
  assert.equal(row.status, 'expired');
  assert.ok(row.waitingSeconds >= 1790 && row.waitingSeconds <= 1810, String(row.waitingSeconds));
  // A period before it: not listed.
  const old = await rpc(agent, 'agent_deposit_board', { p_from: '2026-01-01T00:00:00Z', p_to: '2026-01-02T00:00:00Z' });
  assert.ok(!old.deposits.some((x) => x.id === d.id));
  await rejects(rpc(agent, 'agent_deposit_board', { p_from: '2026-01-02T00:00:00Z', p_to: '2026-01-01T00:00:00Z' }), 'VALIDATION_ERROR');
});

test('Diid: a waiting deposit is closed with its reason, nothing credited; only once, only by staff', async () => {
  const { c, number } = await customer();
  const d = await deposit(c, number, 4);
  await rejects(rpc(c, 'agent_reject_deposit', { p_order_id: d.id, p_reason: 'not paid' }), 'FORBIDDEN');
  await rejects(rpc(c, 'agent_deposit_board'), 'FORBIDDEN');
  await rejects(rpc(agent, 'agent_reject_deposit', { p_order_id: d.id, p_reason: '' }), 'VALIDATION_ERROR');
  const r = await rpc(agent, 'agent_reject_deposit', { p_order_id: d.id, p_reason: 'Lacag lama helin' });
  assert.equal(r.status, 'cancelled');
  const { rows: [o] } = await db.query(`SELECT status, failure_reason FROM orders WHERE id = $1`, [d.id]);
  assert.deepEqual([o.status, o.failure_reason], ['cancelled', 'Lacag lama helin']);
  assert.equal((await rpc(c, 'customer_wallet')).availableBalance, '0.00');
  assert.ok(!(await board()).deposits.some((x) => x.id === d.id), 'gone from the board');
  await rejects(rpc(agent, 'agent_reject_deposit', { p_order_id: d.id, p_reason: 'again' }), 'NOT_PENDING');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE entity_id = $1 AND action = 'deposit_rejected'`, [d.id]);
  assert.equal(rows[0].n, 1);
});
