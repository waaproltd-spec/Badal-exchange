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
import { readFileSync } from 'node:fs';

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

const withdraw = (c, amount, account = '1847412855', method = '888starz') => rpc(c, 'customer_create_withdrawal', {
  p_method: method, p_amount: String(amount), p_account_id: account, p_idempotency_key: randomUUID() });
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
  await db.query(`UPDATE public.orders SET auto_claimed_at = now() WHERE auto_claimed_at IS NULL AND method IN ('888starz', 'onexbet', 'winwin', 'betwinner', 'dbbet', 'betjam', 'betongame', 'melbet')`);
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

test('cash register short: the withdrawal waits, retries each minute, managers are told once', { skip }, async () => {
  // A manager linked to the Telegram bots.
  const tg = 900000000 + seed;
  await db.query(`DELETE FROM app_settings WHERE key = 'cashdesk_low_alert:888starz'`);
  await db.query(`INSERT INTO telegram_operators (telegram_user_id, user_id)
    SELECT $1, id FROM users WHERE phone = '252610000002' ON CONFLICT DO NOTHING`, [tg]);
  const c = await newCustomer(3000);
  const o = await withdraw(c, 25);
  await rpc(worker, 'platform_claim_next');
  const r = await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'low_funds',
    p_message: 'it has $10.29, order needs $25.00' });
  assert.equal(r.status, 'processing');
  assert.ok(r.alertTelegramUserIds.includes(tg), 'linked managers are alerted');
  assert.deepEqual(await balances(c), ['5.00', '25.00'], 'still reserved, not refunded');
  const seen = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(seen.status, 'processing');
  assert.equal(seen.failureReason, null, 'the register is not the customer\'s business');
  const note = (await db.query('SELECT failure_reason FROM orders WHERE id = $1', [o.id])).rows[0].failure_reason;
  assert.match(note, /Waiting for the 888STARZ cash register to be topped up \(it has \$10\.29/);
  assert.equal(await rpc(worker, 'platform_claim_next'), null, 'not again within the same minute');

  // A minute later: still short, no second alert.
  await db.query(`UPDATE orders SET updated_at = now() - interval '2 minutes' WHERE id = $1`, [o.id]);
  const again = await rpc(worker, 'platform_claim_next');
  assert.equal(again.orderId, o.id);
  assert.equal(again.amount, '25.00');
  const r2 = await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'low_funds', p_message: 'still short' });
  assert.equal(r2.alertTelegramUserIds, undefined, 'at most one alert per 15 minutes');

  // Topped up: the next try pays it.
  await db.query(`UPDATE orders SET updated_at = now() - interval '2 minutes' WHERE id = $1`, [o.id]);
  await rpc(worker, 'platform_claim_next');
  const done = await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done', p_reference: '888starz deposit 25' });
  assert.equal(done.status, 'completed');
  assert.deepEqual(await balances(c), ['5.00', '0.00']);
  await db.query('DELETE FROM telegram_operators WHERE telegram_user_id = $1', [tg]);
});

test('cash register short for an hour: the withdrawal fails and the money goes back', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 6);
  await rpc(worker, 'platform_claim_next');
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'low_funds', p_message: 'it has $1.00' });
  await db.query(`UPDATE orders SET low_funds_since = now() - interval '61 minutes',
    updated_at = now() - interval '2 minutes' WHERE id = $1`, [o.id]);
  await rpc(worker, 'platform_claim_next');
  const r = await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'low_funds', p_message: 'it has $1.00' });
  assert.equal(r.status, 'failed');
  const seen = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(seen.failureReason, '888STARZ could not receive payouts in time. Your balance was not charged; please try again later.');
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

test('1XBET orders go through the worker too, named as 1XBET', { skip }, async () => {
  const c = await newCustomer(1000);
  const w = await withdraw(c, 2, '98765432', 'onexbet');
  const job = await rpc(worker, 'platform_claim_next');
  assert.equal(job.orderId, w.id);
  assert.equal(job.method, 'onexbet');
  await rpc(worker, 'platform_finish', { p_order_id: w.id, p_outcome: 'unclear' });
  const review = (await rpc(agent, 'manage_payouts', { p_review_only: true })).find((x) => x.id === w.id);
  assert.match(review.failureReason, /^1XBET gave no clear answer .*1XBET account/);
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: w.id, p_reason: 'test cleanup' });

  const d = await rpc(c, 'customer_create_deposit', {
    p_method: 'onexbet', p_amount: '3', p_account_id: '98765432', p_platform_code: 'X1', p_idempotency_key: randomUUID() });
  assert.equal((await rpc(worker, 'platform_claim_next')).code, 'X1');
  await rpc(worker, 'platform_finish', { p_order_id: d.id, p_outcome: 'done', p_summa: 3 });
  assert.equal((await rpc(c, 'customer_order', { p_id: d.id })).transactionRef, '1XBET');
  assert.deepEqual(await balances(c), ['13.00', '0.00']);
});

test('WinWin orders go through the worker too, named as WinWin', { skip }, async () => {
  const c = await newCustomer(1000);
  const w = await withdraw(c, 2, '44556677', 'winwin');
  const job = await rpc(worker, 'platform_claim_next');
  assert.equal(job.orderId, w.id);
  assert.equal(job.method, 'winwin');
  assert.equal(job.accountId, '44556677');
  await rpc(worker, 'platform_finish', { p_order_id: w.id, p_outcome: 'done' });
  assert.equal((await rpc(c, 'customer_order', { p_id: w.id })).status, 'completed');

  // Payment code only: the WinWin ID used before, and what WinWin paid is credited.
  const d = await rpc(c, 'customer_create_deposit', {
    p_method: 'winwin', p_amount: null, p_platform_code: 'WW42', p_idempotency_key: randomUUID() });
  const dj = await rpc(worker, 'platform_claim_next');
  assert.deepEqual([dj.orderId, dj.code, dj.accountId], [d.id, 'WW42', '44556677']);
  await rpc(worker, 'platform_finish', { p_order_id: d.id, p_outcome: 'done', p_summa: -4 });
  const done = await rpc(c, 'customer_order', { p_id: d.id });
  assert.equal(done.transactionRef, 'WinWin');
  assert.equal(done.amount, '4.00');
  assert.deepEqual(await balances(c), ['12.00', '0.00']);
});

test('WinWin orders from before its own start time stay manual', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 1, '44556677', 'winwin');
  await db.query(`UPDATE public.orders SET created_at = (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since:winwin') - interval '1 minute' WHERE id = $1`, [o.id]);
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: o.id, p_reason: 'test cleanup' });
});

test('Betwinner orders go through the worker too, named as Betwinner', { skip }, async () => {
  const c = await newCustomer(1000);
  const w = await withdraw(c, 2, '33221100', 'betwinner');
  const job = await rpc(worker, 'platform_claim_next');
  assert.equal(job.orderId, w.id);
  assert.equal(job.method, 'betwinner');
  assert.equal(job.accountId, '33221100');
  await rpc(worker, 'platform_finish', { p_order_id: w.id, p_outcome: 'done' });
  assert.equal((await rpc(c, 'customer_order', { p_id: w.id })).status, 'completed');

  // Payment code only: the Betwinner ID used before, and what Betwinner paid is credited.
  const d = await rpc(c, 'customer_create_deposit', {
    p_method: 'betwinner', p_amount: null, p_platform_code: 'BW42', p_idempotency_key: randomUUID() });
  const dj = await rpc(worker, 'platform_claim_next');
  assert.deepEqual([dj.orderId, dj.code, dj.accountId], [d.id, 'BW42', '33221100']);
  await rpc(worker, 'platform_finish', { p_order_id: d.id, p_outcome: 'done', p_summa: -4 });
  const done = await rpc(c, 'customer_order', { p_id: d.id });
  assert.equal(done.transactionRef, 'Betwinner');
  assert.equal(done.amount, '4.00');
  assert.deepEqual(await balances(c), ['12.00', '0.00']);
});

test('Betwinner orders from before its own start time stay manual', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 1, '33221100', 'betwinner');
  await db.query(`UPDATE public.orders SET created_at = (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since:betwinner') - interval '1 minute' WHERE id = $1`, [o.id]);
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: o.id, p_reason: 'test cleanup' });
});

for (const [method, label, code] of [['dbbet', 'DBbet', 'DB42'], ['betjam', 'BetJam', 'BJ42'], ['betongame', 'BetOnGame', 'BG42'], ['melbet', 'MELBET', 'MB42']]) {
  test(`${label} orders go through the worker too, named as ${label}`, { skip }, async () => {
    const c = await newCustomer(1000);
    const w = await withdraw(c, 2, '55443322', method);
    const job = await rpc(worker, 'platform_claim_next');
    assert.equal(job.orderId, w.id);
    assert.equal(job.method, method);
    assert.equal(job.accountId, '55443322');
    await rpc(worker, 'platform_finish', { p_order_id: w.id, p_outcome: 'done' });
    assert.equal((await rpc(c, 'customer_order', { p_id: w.id })).status, 'completed');

    // Payment code only: the account ID used before, and what the company paid is credited.
    const d = await rpc(c, 'customer_create_deposit', {
      p_method: method, p_amount: null, p_platform_code: code, p_idempotency_key: randomUUID() });
    const dj = await rpc(worker, 'platform_claim_next');
    assert.deepEqual([dj.orderId, dj.code, dj.accountId], [d.id, code, '55443322']);
    await rpc(worker, 'platform_finish', { p_order_id: d.id, p_outcome: 'done', p_summa: -4 });
    const done = await rpc(c, 'customer_order', { p_id: d.id });
    assert.equal(done.transactionRef, label);
    assert.equal(done.amount, '4.00');
    assert.deepEqual(await balances(c), ['12.00', '0.00']);
  });

  test(`${label} orders from before its own start time stay manual`, { skip }, async () => {
    const c = await newCustomer(1000);
    const o = await withdraw(c, 2, '55443322', method);
    await db.query(`UPDATE public.orders SET created_at = (SELECT value::timestamptz FROM public.app_settings WHERE key = $2) - interval '1 minute' WHERE id = $1`,
      [o.id, `platform_auto_since:${method}`]);
    assert.equal(await rpc(worker, 'platform_claim_next'), null);
    await rpc(agent, 'agent_withdrawal_fail', { p_order_id: o.id, p_reason: 'test cleanup' });
  });
}

test('1XBET orders from before its own start time stay manual', { skip }, async () => {
  const c = await newCustomer(1000);
  const o = await withdraw(c, 1, '98765432', 'onexbet');
  await db.query(`UPDATE public.orders SET created_at = (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since:onexbet') - interval '1 minute' WHERE id = $1`, [o.id]);
  assert.equal(await rpc(worker, 'platform_claim_next'), null);
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: o.id, p_reason: 'test cleanup' });
});

test('code-only deposit: no amount from the customer; credited with what the platform paid', async () => {
  const c = await newCustomer(0);
  const args = { p_method: 'onexbet', p_amount: null, p_account_id: '98765432', p_platform_code: 'CODE77', p_idempotency_key: randomUUID() };
  const o = await rpc(c, 'customer_create_deposit', args);
  assert.equal(o.status, 'pending');
  assert.equal(o.amountPending, true);
  assert.equal(o.amount, '0.00');
  const replay = await rpc(c, 'customer_create_deposit', args);
  assert.equal(replay.id, o.id);
  assert.equal(replay.amountPending, true, 'a retry returns the order as it is, not the placeholder');
  const agentView = (await rpc(agent, 'agent_pending_deposits')).find((x) => x.id === o.id);
  assert.equal(agentView.amountPending, true);

  const job = await rpc(worker, 'platform_claim_next');
  assert.equal(job.orderId, o.id);
  assert.equal(job.code, 'CODE77');
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done', p_summa: 7.25 });
  const done = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(done.status, 'completed');
  assert.equal(done.amountPending, false);
  assert.equal(done.netAmount, '7.25');
  assert.deepEqual(await balances(c), ['7.25', '0.00']);
});

test('1XBET reports a payout as negative (-5): the customer is credited $5', async () => {
  const c = await newCustomer(0);
  const o = await rpc(c, 'customer_create_deposit', { p_method: 'onexbet', p_amount: null, p_account_id: '98765432',
    p_platform_code: 'VW83', p_idempotency_key: randomUUID() });
  await rpc(worker, 'platform_claim_next');
  const r = await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done', p_reference: '1xBet code VW83', p_summa: -5 });
  assert.equal(r.status, 'completed');
  const done = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(done.netAmount, '5.00');
  assert.deepEqual(await balances(c), ['5.00', '0.00']);
});

test('deposits already paid out as negative are credited from the worker\'s recorded answer, once', async (t) => {
  const { rows: [{ net }] } = await db.query(`SELECT to_regclass('net._http_response') IS NOT NULL AS net`);
  if (!net) return t.skip('pg_net is not installed');
  const c = await newCustomer(0);
  const o = await rpc(c, 'customer_create_deposit', { p_method: 'onexbet', p_amount: null, p_account_id: '98765432',
    p_platform_code: 'VW84', p_idempotency_key: randomUUID() });
  await rpc(worker, 'platform_claim_next');
  // What happened live: paid out, then refused as "Invalid amount", then
  // put in front of an agent as "did not answer".
  await db.query(`UPDATE orders SET auto_claimed_at = now() - interval '11 minutes' WHERE id = $1`, [o.id]);
  await rpc(worker, 'platform_claim_next');
  const answer = { processed: [{ order: o.orderCode, outcome: 'done', reference: '1xBet code VW84', summa: -5,
    error: 'platform_finish: Invalid amount' }] };
  const other = { processed: [{ order: 'EXNOTMINE', outcome: 'done', summa: -9, error: 'platform_finish: Invalid amount' }] };
  const { rows: [{ id }] } = await db.query(`SELECT COALESCE(max(id), 0) + 1 AS id FROM net._http_response`);
  await db.query(`INSERT INTO net._http_response (id, status_code, content, created) VALUES ($1, 200, $2, now()), ($3, 200, $4, now())`,
    [id, JSON.stringify(answer), Number(id) + 1, JSON.stringify(other)]);
  const repair = readFileSync(new globalThis.URL('../migrations/20261021002100_negative_payout_summa.sql', import.meta.url), 'utf8');
  const block = repair.slice(repair.indexOf('DO $do$'));
  await db.query(block);
  await db.query(block); // running it again changes nothing
  const done = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(done.status, 'completed');
  assert.equal(done.netAmount, '5.00');
  assert.deepEqual(await balances(c), ['5.00', '0.00']);
  await db.query('DELETE FROM net._http_response WHERE id IN ($1, $2)', [id, Number(id) + 1]);
});

test('code-only deposit paid out without an amount is left for an agent, nothing credited', async () => {
  const c = await newCustomer(0);
  const o = await rpc(c, 'customer_create_deposit', {
    p_method: '888starz', p_amount: null, p_account_id: '1847412855', p_platform_code: 'NOSUM', p_idempotency_key: randomUUID() });
  await rpc(worker, 'platform_claim_next');
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done', p_summa: null });
  const after = await rpc(c, 'customer_order', { p_id: o.id });
  assert.equal(after.status, 'pending');
  assert.equal(after.amountPending, true);
  assert.deepEqual(await balances(c), ['0.00', '0.00']);
  const { rows } = await db.query('SELECT failure_reason FROM public.orders WHERE id = $1', [o.id]);
  assert.match(rows[0].failure_reason, /did not say how much/);
});

test('payment code only: the account ID is the one the customer used before with that platform', { skip }, async () => {
  const c = await newCustomer(1000);
  const codeOnly = (method, code) => rpc(c, 'customer_create_deposit', {
    p_method: method, p_amount: null, p_platform_code: code, p_idempotency_key: randomUUID() });
  assert.deepEqual(await rpc(c, 'customer_platform_account', { p_method: 'onexbet' }), { accountId: null });
  await rejects(codeOnly('onexbet', 'FIRST1'), 'ACCOUNT_ID_REQUIRED');

  await withdraw(c, 2, '55554444', 'onexbet');
  assert.deepEqual(await rpc(c, 'customer_platform_account', { p_method: 'onexbet' }), { accountId: '55554444' });
  const o = await codeOnly('onexbet', 'NEXT22');
  assert.equal(o.accountId, '55554444');
  assert.equal(o.amountPending, true);

  // Per platform and per customer.
  await rejects(codeOnly('888starz', 'OTHER3'), 'ACCOUNT_ID_REQUIRED');
  const other = await newCustomer(0);
  assert.deepEqual(await rpc(other, 'customer_platform_account', { p_method: 'onexbet' }), { accountId: null });

  // The worker gets the saved ID for the code-only deposit.
  for (let job; (job = await rpc(worker, 'platform_claim_next'));) {
    if (job.orderId === o.id) assert.equal(job.accountId, '55554444');
    await rpc(worker, 'platform_finish', { p_order_id: job.orderId, p_outcome: 'refused', p_message: 'test' });
  }
});

test('a code-less deposit still needs an amount', async () => {
  const c = await newCustomer(0);
  await rejects(rpc(c, 'customer_create_deposit', {
    p_method: 'onexbet', p_amount: null, p_account_id: '98765432', p_idempotency_key: randomUUID() }), 'VALIDATION_ERROR');
});

test('a cashdesk deposit without a payment code stays manual', { skip }, async () => {
  const c = await newCustomer(1000);
  await rpc(c, 'customer_create_deposit', {
    p_method: '888starz', p_amount: '5', p_account_id: '1847412855', p_idempotency_key: randomUUID() });
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
