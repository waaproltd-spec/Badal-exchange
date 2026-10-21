// Automatic 888STARZ orders (migrations/*_platform_auto.sql): the database
// side of the platform-orders worker, called here with the service role key
// exactly as the worker calls it.
//
//   SUPABASE_SERVICE_ROLE_KEY=$(supabase status -o env | sed -n 's/^SECRET_KEY="\(.*\)"$/\1/p') npm test

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const skip = !SERVICE_KEY && 'set SUPABASE_SERVICE_ROLE_KEY';

const db = new pg.Pool({ connectionString: DATABASE_URL });
const client = (key = ANON_KEY) => createClient(URL, key, { auth: { persistSession: false, autoRefreshToken: false } });
const seed = Number(Date.now().toString().slice(-6));
let n = 0;

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

async function newCustomer(balanceCents) {
  const phone = `2527${String(seed).padStart(6, '0')}${String(n++).padStart(3, '0')}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Platform Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u`,
    [phone, PASSWORD, balanceCents]
  );
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}

const withdraw = (c, amount, account = '1847412855') => rpc(c, 'customer_create_withdrawal', {
  p_method: '888starz', p_amount: String(amount), p_account_id: account, p_idempotency_key: randomUUID() });
const deposit = (c, amount, code, account = '1847412855') => rpc(c, 'customer_create_deposit', {
  p_method: '888starz', p_amount: String(amount), p_account_id: account, p_platform_code: code, p_idempotency_key: randomUUID() });
const balances = async (c) => {
  const w = await rpc(c, 'customer_wallet');
  return [w.availableBalance, w.pendingBalance];
};

let worker;
let agent;

before(async () => {
  if (skip) return;
  worker = client(SERVICE_KEY);
  agent = client();
  const { error } = await agent.auth.signInWithPassword({ email: '252610000002@phone.baari.invalid', password: PASSWORD });
  if (error) throw error;
  // Nothing from other test files may be waiting for the worker.
  await db.query(`UPDATE public.orders SET auto_claimed_at = now() WHERE auto_claimed_at IS NULL AND method = '888starz'`);
});

after(async () => {
  await db.end();
});

test('withdraw to 888starz: claimed once, done finalizes the debit', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 4);
  assert.deepEqual(await balances(c), ['6.00', '4.00']);

  const job = await rpc(worker, 'platform_claim_next');
  assert.deepEqual(job, { orderId: o.id, orderCode: o.orderCode, direction: 'withdraw', method: '888starz',
    accountId: '1847412855', amount: '4.00', code: null });
  assert.equal((await rpc(c, 'customer_order', { p_id: o.id })).status, 'processing');
  assert.equal(await rpc(worker, 'platform_claim_next'), null, 'an order is handed out once');

  const done = await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done', p_reference: '888starz deposit 4' });
  assert.equal(done.status, 'completed');
  assert.deepEqual(await balances(c), ['6.00', '0.00']);
  const after = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(after.transactionRef, '888starz deposit 4');
  // Finishing twice changes nothing.
  assert.equal((await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'refused' })).late, true);
  assert.deepEqual(await balances(c), ['6.00', '0.00']);
});

test('withdraw refused by 888starz returns the funds', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 3);
  await rpc(worker, 'platform_claim_next');
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'refused', p_message: 'Limit exceeded' });
  const after = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(after.status, 'failed');
  assert.equal(after.failureReason, 'Limit exceeded');
  assert.deepEqual(await balances(c), ['10.00', '0.00']);
});

test('withdraw not sent goes back to the agents and is never retried automatically', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 2);
  await rpc(worker, 'platform_claim_next');
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'not_sent', p_message: 'CashdeskBot rejected the request: invalid sign' });
  const pending = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(pending.status, 'pending');
  assert.equal(pending.failureReason, null, 'agents\' notes are not shown to the customer');
  assert.deepEqual(await balances(c), ['8.00', '2.00']);
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  assert.ok((await rpc(agent, 'agent_pending_withdrawals')).some((x) => x.id === o.id));
  // An agent handles it by hand as before.
  await rpc(agent, 'agent_withdrawal_start', { p_order_id: o.id });
  await rpc(agent, 'agent_withdrawal_complete', { p_order_id: o.id, p_transaction_ref: 'manual', p_idempotency_key: randomUUID() });
  assert.deepEqual(await balances(c), ['8.00', '0.00']);
});

test('unclear withdraw is held for review, never failed or paid again on its own', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 1);
  await rpc(worker, 'platform_claim_next');
  const r = await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'unclear', p_message: 'timeout' });
  assert.deepEqual(r, { status: 'processing', payoutReview: true });
  assert.deepEqual(await balances(c), ['9.00', '1.00']);
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  const review = await rpc(agent, 'manage_payouts', { p_review_only: true });
  const item = review.find((x) => x.id === o.id);
  assert.ok(item?.payoutReview);
  assert.match(item.failureReason, /timeout/);
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: o.id, p_reason: 'checked 888starz: not paid' });
  assert.deepEqual(await balances(c), ['10.00', '0.00']);
});

test('a worker that never reports puts the order in front of an agent after 10 minutes', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 1);
  await rpc(worker, 'platform_claim_next');
  await db.query(`UPDATE public.orders SET auto_claimed_at = now() - interval '11 minutes' WHERE id = $1`, [o.id]);
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  const review = await rpc(agent, 'manage_payouts', { p_review_only: true });
  assert.ok(review.some((x) => x.id === o.id && x.payoutReview));
  assert.deepEqual(await balances(c), ['9.00', '1.00']);
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: o.id, p_reason: 'test cleanup' });
});

test('deposit with a withdrawal code: credits what 888starz paid', { skip }, async () => {
  const c = await newCustomer(0);
  const o = await deposit(c, 5, ' ABC123 ');
  const job = await rpc(worker, 'platform_claim_next');
  assert.equal(job.orderId, o.id);
  assert.equal(job.direction, 'deposit');
  assert.equal(job.code, 'ABC123');
  // 888starz paid 4.50, not the 5 the customer typed.
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done', p_reference: '888starz code ABC123', p_summa: 4.5 });
  const after = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(after.status, 'completed');
  assert.equal(after.netAmount, '4.50');
  assert.deepEqual(await balances(c), ['4.50', '0.00']);
});

test('deposit: refused fails, unclear and not sent stay pending for an agent', { skip }, async () => {
  const c = await newCustomer(0);
  const bad = await deposit(c, 5, 'WRONG');
  await rpc(worker, 'platform_claim_next');
  await rpc(worker, 'platform_finish', { p_order_id: bad.id, p_outcome: 'refused', p_message: 'Code not found' });
  assert.equal((await rpc(c, 'customer_order', { p_id: bad.id })).status, 'failed');

  for (const outcome of ['unclear', 'not_sent']) {
    const o = await deposit(c, 5, `C${outcome}`);
    await rpc(worker, 'platform_claim_next');
    await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: outcome, p_message: 'x' });
    assert.equal((await rpc(c, 'customer_order', { p_id: o.id })).status, 'pending');
    assert.ok((await rpc(agent, 'agent_pending_deposits')).some((x) => x.id === o.id));
  }
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  assert.deepEqual(await balances(c), ['0.00', '0.00']);
});

test('orders from before automation was switched on stay manual', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 1);
  await db.query(`UPDATE public.orders SET created_at = (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since') - interval '1 minute' WHERE id = $1`, [o.id]);
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: o.id, p_reason: 'test cleanup' });
});

test('deposits without a code and other platforms stay manual', { skip }, async () => {
  const c = await newCustomer(1000);
  await rpc(c, 'customer_create_deposit', {
    p_method: '888starz', p_amount: '5', p_account_id: '1847412855', p_idempotency_key: randomUUID() });
  await rpc(c, 'customer_create_withdrawal', {
    p_method: 'melbet', p_amount: '5', p_account_id: '1234567', p_idempotency_key: randomUUID() });
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
});

test('only the worker can claim or finish orders', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 1);
  for (const caller of [c, agent]) {
    await rejects(rpc(caller, 'platform_claim_next'), '42501');
    await rejects(rpc(caller, 'platform_finish', { p_order_id: o.id, p_outcome: 'done' }), '42501');
    await rejects(rpc(caller, 'platform_worker_check', { p_secret: 'x' }), '42501');
  }
  assert.equal(await rpc(worker, 'platform_worker_check', { p_secret: 'wrong' }), false);
  const { rows } = await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`);
  assert.equal(await rpc(worker, 'platform_worker_check', { p_secret: rows[0].decrypted_secret }), true);
  await db.query(`UPDATE public.orders SET auto_claimed_at = now() WHERE id = $1`, [o.id]);
});
