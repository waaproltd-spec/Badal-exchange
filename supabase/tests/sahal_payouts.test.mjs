// Golis, ZAAD and EVC Plus withdrawals sent automatically from Sahal
// (migrations/*_sahal_payouts.sql): what the golis-merchant function is
// handed and what its reports do. Off / Test / Live, the $0.10 test, the
// daily limit, one attempt per withdrawal, refusals, unclear answers, and
// the feed's read-back never completing a second identical withdrawal.
// Run with the other suites: npm test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
// The sahal_payout_* functions are service-only:
// SUPABASE_SERVICE_ROLE_KEY=$(supabase status -o env | sed -n 's/^SECRET_KEY="\(.*\)"$/\1/p')
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const opts = { auth: { persistSession: false, autoRefreshToken: false } };
const service = SERVICE_KEY ? createClient(URL, SERVICE_KEY, opts) : null;
const check = (name, fn) => test(name, { skip: !SERVICE_KEY && 'set SUPABASE_SERVICE_ROLE_KEY' }, fn);

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
const golisNumber = () => `90${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
const evcNumber = () => `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
const zaadNumber = () => `63${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;

let manager;
async function customer(number, balanceCents = 10_000) {
  const phone = `252${number}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Sahal Payout Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u`, [phone, PASSWORD, balanceCents]);
  return login(phone);
}
async function withdrawal(method, number, amount) {
  const c = await customer(number);
  const w = await rpc(c, 'customer_create_withdrawal', {
    p_method: method, p_amount: String(amount), p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
  assert.equal(w.status, 'pending');
  return { c, w };
}
const next = () => rpc(service, 'sahal_payout_next');
const say = (id, status, extra = {}) => rpc(service, 'sahal_payout_report', { p_attempt_id: id, p_status: status, ...extra });
function sahalTime(msAgo = 0) {
  const d = new Date(Date.now() - msAgo + 3 * 3600_000);
  const p = (x) => String(x).padStart(2, '0');
  return `${p(d.getUTCDate())}/${p(d.getUTCMonth() + 1)}/${String(d.getUTCFullYear()).slice(2)} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`;
}
const order = async (id) => (await db.query('SELECT status, transaction_ref FROM orders WHERE id = $1', [id])).rows[0];
const setMode = (p_mode, extra = {}) => rpc(manager, 'manage_set_sahal_payouts', { p_mode, ...extra });
/** Hands out every waiting withdrawal of other runs first, so each test sees only its own. */
async function clearQueue() {
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE direction = 'withdraw' AND method IN ('golis', 'telesom', 'evc_plus') AND status = 'pending'`);
  await db.query(`UPDATE sahal_payout_attempts SET status = 'failed' WHERE status = 'pending'`);
}

before(async () => {
  manager = await login('252610000002');
  await db.query(`UPDATE withdrawal_limits SET min_cents = 10 WHERE method IN ('golis', 'telesom')`);
  await db.query(`UPDATE sahal_payout_settings SET mode = 'off', test_started_at = NULL, daily_limit_cents = 50000, test_amount_cents = 10`);
  await db.query(`DELETE FROM sahal_payout_attempts`);
  await clearQueue();
});
after(async () => {
  await db.query(`UPDATE withdrawal_limits SET min_cents = 100 WHERE method IN ('golis', 'telesom')`);
  await db.query(`UPDATE sahal_payout_settings SET mode = 'off'`);
  await db.end();
});

check('off by default: nothing is handed out; only the service can ask', async () => {
  const { w } = await withdrawal('golis', golisNumber(), 2);
  assert.equal(await next(), null);
  assert.equal((await order(w.id)).status, 'pending');
  await rejects(rpc(manager, 'sahal_payout_next'), '42501');
  assert.equal((await rpc(manager, 'manage_sahal_payouts')).mode, 'off');
});

check('test mode sends only the $0.10 one; live needs that test sent first', async () => {
  await clearQueue();
  await rejects(setMode('live'), 'TEST_REQUIRED');
  const evc = await withdrawal('evc_plus', evcNumber(), 2);
  const phoneBlock = async () => (await db.query('SELECT private.payout_block(o) AS b FROM orders o WHERE id = $1', [evc.w.id])).rows[0].b;
  assert.notEqual((await phoneBlock())?.code, 'SENT_FROM_SAHAL', 'Sahal off: the phone may pay EVC');
  await setMode('test');
  assert.equal((await phoneBlock())?.code, 'SENT_FROM_SAHAL', 'Sahal on: never from the phone too');
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [evc.w.id]);
  const big = await withdrawal('golis', golisNumber(), 2);
  const number = golisNumber();
  const small = await withdrawal('golis', number, 0.1);
  const a = await next();
  assert.equal(a.orderCode, small.w.orderCode);
  assert.equal(a.receiverMobile, number, 'Golis numbers as typed in Sahal, no 0');
  assert.equal(a.amount, '0.1');
  assert.equal(a.description, small.w.orderCode);
  assert.equal(await next(), null, 'one transfer at a time');
  await rejects(setMode('live'), 'TEST_REQUIRED');

  await say(a.attemptId, 'success', { p_receiver_name: 'TEST', p_transfer_id: '7501066868', p_result_code: '2001' });
  const done = await order(small.w.id);
  assert.equal(done.status, 'completed');
  assert.equal(done.transaction_ref, 'Sahal 7501066868');
  assert.equal(await next(), null, 'the $2 one waits in test mode');
  assert.equal((await order(big.w.id)).status, 'pending');

  const s = await setMode('live');
  assert.equal(s.mode, 'live');
  assert.equal(s.testPassed, true);
  const b = await next();
  assert.equal(b.orderCode, big.w.orderCode);
  assert.equal(b.amount, '2');
  await say(b.attemptId, 'success', { p_transfer_id: '7501066869' });
  assert.equal((await order(big.w.id)).status, 'completed');
});

check('EVC Plus numbers go with their 0, as typed in Sahal', async () => {
  await clearQueue();
  const number = evcNumber();
  const { w } = await withdrawal('evc_plus', number, 1);
  const a = await next();
  assert.equal(a.orderCode, w.orderCode);
  assert.equal(a.receiverMobile, `0${number}`);
  await say(a.attemptId, 'failed', { p_result_code: '4001', p_reply: 'test' });
});

check('ZAAD numbers go with their 0; a refusal leaves the withdrawal for an agent, never retried', async () => {
  await clearQueue();
  const number = zaadNumber();
  const { w } = await withdrawal('telesom', number, 3);
  const a = await next();
  assert.equal(a.receiverMobile, `0${number}`);
  await say(a.attemptId, 'failed', { p_result_code: '4001', p_reply: 'Invalid PIN' });
  assert.equal((await order(w.id)).status, 'pending');
  assert.equal(await next(), null, 'not handed out again');
});

check('an unclear answer holds it processing; never resent; the feed read-back completes it', async () => {
  await clearQueue();
  const number = golisNumber();
  const { w } = await withdrawal('golis', number, 4);
  const a = await next();
  await say(a.attemptId, 'ambiguous', { p_reply: 'timeout' });
  assert.equal((await order(w.id)).status, 'processing');
  assert.equal(await next(), null);
  // "Sent" without Sahal's id is unclear too, and a late report changes nothing.
  assert.deepEqual(await say(a.attemptId, 'success', { p_transfer_id: '1' }), { status: 'ambiguous', unchanged: true });
  assert.equal((await rpc(manager, 'manage_sahal_payouts')).unclear >= 1, true);
});

check('a run that died after claiming: held as unclear after 5 minutes, then the next one goes', async () => {
  await clearQueue();
  const first = await withdrawal('golis', golisNumber(), 1);
  const a = await next();
  await db.query(`UPDATE sahal_payout_attempts SET created_at = now() - interval '6 minutes' WHERE id = $1`, [a.attemptId]);
  const second = await withdrawal('golis', golisNumber(), 1);
  const b = await next();
  assert.equal(b.orderCode, second.w.orderCode);
  assert.equal((await order(first.w.id)).status, 'processing');
  await say(b.attemptId, 'success', { p_transfer_id: `T${seed}b` });
});

check('daily limit: nothing more goes once today\'s transfers would pass it', async () => {
  await clearQueue();
  const today = (await rpc(manager, 'manage_sahal_payouts')).paidToday;
  await setMode(null, { p_daily_limit: Number(today) + 5 });
  const { w } = await withdrawal('golis', golisNumber(), 6);
  assert.equal(await next(), null);
  await setMode(null, { p_daily_limit: 500 });
  const a = await next();
  assert.equal(a.orderCode, w.orderCode);
  await say(a.attemptId, 'success', { p_transfer_id: `T${seed}c` });
});

check('the feed reading back our transfer completes only its own withdrawal, not an identical one', async () => {
  await clearQueue();
  const number = golisNumber();
  const one = await withdrawal('golis', number, 2);
  const a = await next();
  const id = `T${seed}d`;
  await say(a.attemptId, 'success', { p_transfer_id: id });
  assert.equal((await order(one.w.id)).status, 'completed');
  // The customer asks again for the same amount; then the feed reads our transfer back.
  const c = await login(`252${number}`);
  const two = await rpc(c, 'customer_create_withdrawal', {
    p_method: 'golis', p_amount: '2', p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
  await rpc(service, 'merchant_feed_report', {
    p_provider: 'golis', p_state: 'ok', p_result_code: '2001', p_message: 'test', p_session_id: null,
    p_rows: [{ _id: id, tranID: id, sender: '252905999914', receiver: number, tranDate: sahalTime(),
               description: one.w.orderCode, credit: '-', debit: '2.00' }],
  });
  assert.equal((await order(two.id)).status, 'pending', 'the second $2 withdrawal is not paid by the first transfer');
  const { rows } = await db.query('SELECT matched_order_id FROM merchant_transactions WHERE provider = $1 AND transaction_id = $2', ['golis', id]);
  assert.equal(rows[0]?.matched_order_id, one.w.id, 'the read-back is tied to the withdrawal it paid');
});

check('only managers see or change it', async () => {
  const number = golisNumber();
  const c = await customer(number);
  await rejects(rpc(c, 'manage_sahal_payouts'), 'FORBIDDEN');
  await rejects(rpc(c, 'manage_set_sahal_payouts', { p_mode: 'live' }), 'FORBIDDEN');
  await rejects(setMode('fast'), 'VALIDATION_ERROR');
  for (const table of ['sahal_payout_settings', 'sahal_payout_attempts']) {
    const { data, error } = await c.from(table).select('*');
    assert.ok(error || data.length === 0, `${table} must not be readable`);
  }
});
