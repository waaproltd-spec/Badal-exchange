// Company Balances accounting (migrations/*_company_balance_accounting.sql):
// Balance and Limit of a cash register after each completed sale and payout,
// on top of the last live read.
//
//   SUPABASE_SERVICE_ROLE_KEY=... npm test   (needs the local stack)

import { test, before, beforeEach, after } from 'node:test';
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

async function signIn(phone) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}

async function customer(balanceCents = 10000) {
  const phone = `2526${String(seed).padStart(6, '0')}${String(n++).padStart(2, '0')}`;
  await db.query(`WITH u AS (INSERT INTO users (role, phone, name, password_hash)
      VALUES ('customer', $1, 'Accounting Test', private.hash_password($2)) RETURNING id)
    INSERT INTO wallets (customer_id, available_cents) SELECT id, $3 FROM u`, [phone, PASSWORD, balanceCents]);
  return signIn(phone);
}

let worker;
let manager;

/** A live read of the 888STARZ register: the new starting point. */
async function liveRead(balance, limit) {
  await rpc(worker, 'company_balance_record', { p_method: '888starz', p_balance: balance, p_limit: limit, p_error: null });
}

const starz = async () => (await rpc(manager, 'agent_company_balances')).companies.find((c) => c.method === '888starz');
const values = async () => {
  const c = await starz();
  return [c.balance, c.limit];
};

const sell = (c, amount) => rpc(c, 'customer_create_withdrawal', {
  p_method: '888starz', p_amount: String(amount), p_account_id: '1847412855', p_idempotency_key: randomUUID() });
const codeDeposit = (c, code) => rpc(c, 'customer_create_deposit', {
  p_method: '888starz', p_amount: null, p_account_id: '1847412855', p_platform_code: code, p_idempotency_key: randomUUID() });
const finish = (id, outcome, extra = {}) => rpc(worker, 'platform_finish', { p_order_id: id, p_outcome: outcome, ...extra });
const movements = async () => (await db.query(`SELECT count(*)::int AS n FROM cashdesk_movements WHERE method = '888starz'`)).rows[0].n;

before(async () => {
  if (skip) return;
  worker = client(SERVICE_KEY);
  manager = await signIn('252610000002');
  // Nothing from other test files may be waiting for the worker.
  await db.query(`UPDATE orders SET auto_claimed_at = now() WHERE auto_claimed_at IS NULL AND method IN ('888starz', 'onexbet', 'winwin', 'betwinner')`);
});
// Each test starts with no 888STARZ / 1XBET order open or waiting (test
// database only), so the worker claims exactly the orders it makes.
beforeEach(async () => {
  if (skip) return;
  await db.query(`UPDATE orders SET status = 'failed', low_funds_since = NULL, auto_claimed_at = COALESCE(auto_claimed_at, now())
    WHERE method IN ('888starz', 'onexbet', 'winwin', 'betwinner') AND status IN ('pending', 'processing')`);
});

after(async () => {
  await db.end();
});

test('a sale of $5: Balance +5, Limit -5', { skip }, async () => {
  await liveRead(100, 50);
  assert.deepEqual(await values(), ['100.00', '50.00']);
  const o = await sell(await customer(), 5);
  await rpc(worker, 'platform_claim_next');
  await finish(o.id, 'done', { p_reference: '888starz deposit 5' });
  assert.deepEqual(await values(), ['105.00', '45.00']);
  const c = await starz();
  assert.deepEqual([c.liveBalance, c.liveLimit, c.salesSinceCheck, c.changesSinceCheck], ['100.00', '50.00', '5.00', 1]);
});

test('a payout of $5: Balance -5, Limit +5 (CashdeskBot reports it as -5)', { skip }, async () => {
  await liveRead(100, 50);
  const o = await codeDeposit(await customer(0), `P${seed}`);
  await rpc(worker, 'platform_claim_next');
  await finish(o.id, 'done', { p_reference: '888starz code', p_summa: -5 });
  assert.deepEqual(await values(), ['95.00', '55.00']);
});

test('pending, refused, waiting for a top-up and unclear change nothing', { skip }, async () => {
  await liveRead(100, 50);
  const cu = await customer();
  const pending = await sell(cu, 1); // not claimed yet
  assert.deepEqual(await values(), ['100.00', '50.00']);
  await rpc(worker, 'platform_claim_next'); // claimed, being processed
  assert.deepEqual(await values(), ['100.00', '50.00']);
  await finish(pending.id, 'refused', { p_message: 'Player blocked' });
  const short = await sell(cu, 2);
  await rpc(worker, 'platform_claim_next');
  await finish(short.id, 'low_funds', { p_message: 'maximum of 1' });
  const unclear = await sell(cu, 3);
  await db.query(`UPDATE orders SET auto_claimed_at = now() WHERE id = $1`, [short.id]); // keep it out of the queue
  await rpc(worker, 'platform_claim_next');
  await finish(unclear.id, 'unclear', { p_message: 'timeout' });
  const failedDeposit = await codeDeposit(cu, `F${seed}`);
  await rpc(worker, 'platform_claim_next');
  await finish(failedDeposit.id, 'refused', { p_message: 'Code not found' });
  assert.deepEqual(await values(), ['100.00', '50.00']);
});

test('finishing an order twice changes the values once', { skip }, async () => {
  await liveRead(100, 50);
  const o = await sell(await customer(), 5);
  await rpc(worker, 'platform_claim_next');
  const before = await movements();
  await finish(o.id, 'done');
  const again = await finish(o.id, 'done');
  assert.equal(again.late, true);
  assert.equal(await movements(), before + 1);
  assert.deepEqual(await values(), ['105.00', '45.00']);
  // The ledger itself refuses a second movement for the order, and edits.
  const r = await db.query(`SELECT private.cashdesk_movement('888starz', 'sale', 500, $1, NULL, now()) AS recorded`, [o.id]);
  assert.equal(r.rows[0].recorded, false);
  await assert.rejects(db.query(`UPDATE cashdesk_movements SET amount_cents = 1 WHERE order_id = $1`, [o.id]), /can not be changed/);
  await assert.rejects(db.query(`DELETE FROM cashdesk_movements WHERE order_id = $1`, [o.id]), /can not be changed/);
});

test('concurrent requests: every sale and payout counted exactly once', { skip }, async () => {
  await liveRead(1000, 500);
  const cu = await customer(100000);
  const sales = [];
  for (let i = 0; i < 8; i++) sales.push(await sell(await customer(), 2)); // 8 x $2
  const deposits = [];
  for (let i = 0; i < 3; i++) deposits.push(await codeDeposit(cu, `C${seed}${i}`));
  for (let i = 0; i < 11; i++) await rpc(worker, 'platform_claim_next');
  // Each order finished five times at once.
  await Promise.all([
    ...sales.flatMap((o) => Array.from({ length: 5 }, () => finish(o.id, 'done'))),
    ...deposits.flatMap((o) => Array.from({ length: 5 }, () => finish(o.id, 'done', { p_summa: -3 }))),
  ]);
  // +16 sold, -9 paid out.
  assert.deepEqual(await values(), ['1007.00', '493.00']);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM cashdesk_movements WHERE order_id = ANY($1)`,
    [[...sales, ...deposits].map((o) => o.id)]);
  assert.equal(rows[0].n, 11);
});

test('a new live read replaces the running values', { skip }, async () => {
  await liveRead(100, 50);
  const o = await sell(await customer(), 5);
  await rpc(worker, 'platform_claim_next');
  await finish(o.id, 'done');
  assert.deepEqual(await values(), ['105.00', '45.00']);
  await liveRead(105, 45); // the register now reports the sale itself
  assert.deepEqual(await values(), ['105.00', '45.00'], 'not counted twice');
});

test('a Limit the register did not report stays unknown', { skip }, async () => {
  await liveRead(100, null);
  const o = await sell(await customer(), 5);
  await rpc(worker, 'platform_claim_next');
  await finish(o.id, 'done');
  assert.deepEqual(await values(), ['105.00', null]);
  const all = await rpc(manager, 'agent_company_balances');
  assert.ok(all.limitUnknownCount >= 1);
});

test('manual deposits and payouts (Telegram, Agent App) count once per request', { skip }, async () => {
  await liveRead(100, 50);
  const key = randomUUID();
  await rpc(manager, 'cashdeskbot_begin', { p_action: 'deposit', p_idempotency_key: key, p_payload: { userId: '1', summa: 4 } });
  const finishManual = () => rpc(manager, 'cashdeskbot_finish', { p_action: 'deposit', p_user_id: '1',
    p_audit: { brand: '888starz', summa: 4 }, p_idempotency_key: key, p_response: { success: true, summa: 4 } });
  await finishManual();
  await finishManual();
  const payoutKey = randomUUID();
  await rpc(manager, 'cashdeskbot_begin', { p_action: 'payout', p_idempotency_key: payoutKey, p_payload: { userId: '1', code: 'X' } });
  await rpc(manager, 'cashdeskbot_finish', { p_action: 'payout', p_user_id: '1',
    p_audit: { brand: '888starz' }, p_idempotency_key: payoutKey, p_response: { success: true, summa: -1.5 } });
  // A refused manual deposit moves nothing.
  const refusedKey = randomUUID();
  await rpc(manager, 'cashdeskbot_begin', { p_action: 'deposit', p_idempotency_key: refusedKey, p_payload: { userId: '1', summa: 9 } });
  await rpc(manager, 'cashdeskbot_finish', { p_action: 'deposit', p_user_id: '1',
    p_audit: { brand: '888starz', summa: 9 }, p_idempotency_key: refusedKey, p_response: { success: false, message: 'Limit' } });
  assert.deepEqual(await values(), ['102.50', '47.50']);
});

test('the history shows each movement with the Balance and Limit it led to', { skip }, async () => {
  await liveRead(100, 50);
  const cu = await customer();
  const a = await sell(cu, 5);
  await rpc(worker, 'platform_claim_next');
  await finish(a.id, 'done');
  const b = await codeDeposit(cu, `H${seed}`);
  await rpc(worker, 'platform_claim_next');
  await finish(b.id, 'done', { p_summa: -2 });
  const d = await rpc(manager, 'agent_company_detail', { p_method: '888starz' });
  const [last, first] = d.movements;
  assert.deepEqual([first.kind, first.amount, first.orderCode, first.balanceAfter, first.limitAfter],
    ['sale', '5.00', a.orderCode, '105.00', '45.00']);
  assert.deepEqual([last.kind, last.amount, last.orderCode, last.balanceAfter, last.limitAfter],
    ['payout', '2.00', b.orderCode, '103.00', '47.00']);
  assert.deepEqual([d.balance, d.limit], ['103.00', '47.00']);
  assert.equal(d.checks[0].limit, '50.00');
});

test('low is judged on the Limit: what the register can still sell', { skip }, async () => {
  await liveRead(5000, 20); // a large Balance, but little left to sell
  const c = await starz();
  assert.equal(c.status, 'low');
  await liveRead(10, 500);
  assert.equal((await starz()).status, 'available');
});
