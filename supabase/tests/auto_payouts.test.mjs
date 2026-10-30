// Fully automatic withdrawals from the Agent App's EVC Plus payout phone:
// the Off / Test / Live switch, the $0.10 test before going live, the daily
// limit and the minimum balance, plus duplicate prevention, failed
// transfers, timeouts, reconciliation from the carrier's SMS and the
// customer wallet's accounting. End to end through Auth + RPC + RLS.
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

const authEmail = (phone) => `${phone.replace(/\D/g, '')}@phone.baari.invalid`;
const client = () => createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
async function login(phone) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: authEmail(phone), password: PASSWORD });
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

const PHONE = 'auto-payout-phone';
const PIN = '9182';
const CODE = '5566';
const WALLET = '617700001';
let agent;
let walletId;

async function newCustomer(balanceCents, number) {
  const phone = `252${number}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Auto Payout Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u`,
    [phone, PASSWORD, balanceCents]);
  return login(phone);
}
const wallet = (c) => rpc(c, 'customer_wallet');
const order = (c, id) => rpc(c, 'customer_order', { p_id: id });
async function withdrawal(amount, balanceCents = 10_000) {
  const to = evcNumber();
  const customer = await newCustomer(balanceCents, to);
  const w = await rpc(customer, 'customer_create_withdrawal', {
    p_method: 'evc_plus', p_amount: String(amount), p_phone_number: to, p_idempotency_key: randomUUID() });
  assert.equal(w.status, 'pending');
  return { customer, w, to };
}
const settings = async () => (await rpc(agent, 'manage_auto_payouts')).find((s) => s.method === 'evc_plus');
const setMode = (mode, extra = {}) => rpc(agent, 'manage_set_auto_payout', { p_method: 'evc_plus', p_mode: mode, ...extra });
const inQueue = async (id) => (await rpc(agent, 'agent_payout_queue')).some((o) => o.id === id);
const start = (id) => rpc(agent, 'agent_payout_start_dial', { p_order_id: id, p_device_id: PHONE });
const step1 = (id, status = 'step1_success', text = 'Geli PIN') =>
  rpc(agent, 'agent_payout_report_step1', { p_attempt_id: id, p_status: status, p_response: text });
const step2 = (id, status, text) => rpc(agent, 'agent_payout_report_step2', { p_attempt_id: id, p_status: status, p_response: text });
const payoutSms = (to, amount, { device = PHONE, ref = null, balance = null } = {}) =>
  rpc(agent, 'agent_payout_confirmation', {
    p_receiver_phone: to, p_amount: String(amount), p_provider: 'Hormuud', p_reference: ref, p_device_id: device,
    p_received_at: new Date().toISOString(),
    p_raw_text: `[-EVCPLUS-] $${amount} ayaad uwareejisay TEST (${to}), Tar: now${balance != null ? `, Haraagaagu waa $${balance}` : ''}`,
  });
const ledger = async (orderId) => (await db.query(
  `SELECT entry_type, amount_cents::int AS cents FROM ledger_entries WHERE order_id = $1 ORDER BY created_at, entry_type`, [orderId])).rows;
const cents = (s) => Math.round(Number(s) * 100);

/** Live, wide limits and a large known balance: the base for most tests. */
async function live({ daily = 10_000_000, min = 0, balance = 1_000_000 } = {}) {
  await db.query(`UPDATE payout_auto_settings SET mode = 'live', live_wallet_id = $1, live_device_id = $2,
                    daily_limit_cents = $3, min_balance_cents = $4 WHERE method = 'evc_plus'`, [walletId, PHONE, daily, min]);
  if (balance != null) {
    await db.query(`INSERT INTO payout_wallet_balances (wallet_id, balance_cents, seen_at, source) VALUES ($1, $2, now(), 'manager')`,
      [walletId, balance]);
  }
}

before(async () => {
  agent = await login('252610000002');
  const w = await rpc(agent, 'manage_save_payout_wallet', {
    p_id: null, p_method: 'evc_plus', p_phone_number: WALLET, p_device_id: PHONE, p_sim_slot: 1 });
  await rpc(agent, 'manage_set_payout_wallet_pin', { p_id: w.id, p_pin: PIN });
  await rpc(agent, 'manage_set_payout_wallet_ussd_code', { p_id: w.id, p_code: CODE });
  walletId = w.id;
  await db.query(`UPDATE payout_wallets SET created_at = now() - interval '20 years' WHERE id = $1`, [w.id]);
  await db.query(`UPDATE payout_wallets SET device_id = NULL WHERE method = 'evc_plus' AND id <> $1`, [w.id]);
  // Older test withdrawals must not stand in the queue or count today.
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE direction = 'withdraw' AND method = 'evc_plus' AND status = 'pending'`);
  await db.query(`UPDATE withdrawal_limits SET min_cents = 10 WHERE method = 'evc_plus'`);
  await db.query(`UPDATE payout_auto_settings SET mode = 'off', test_started_at = NULL, live_wallet_id = NULL,
                    live_device_id = NULL, live_test_order_id = NULL, live_at = NULL WHERE method = 'evc_plus'`);
});

after(async () => {
  await db.query(`UPDATE withdrawal_limits SET min_cents = 100 WHERE method = 'evc_plus'`);
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE direction = 'withdraw' AND method = 'evc_plus' AND status = 'pending'`);
  await db.end();
});

// ---------------------------------------------------------------------------
// The production switch
// ---------------------------------------------------------------------------

test('off by default: nothing is dialed, the withdrawal waits with its funds reserved', async () => {
  const s = await settings();
  assert.equal(s.mode, 'off');
  assert.equal(s.testPassed, false);
  const { customer, w } = await withdrawal(5);
  assert.equal(await inQueue(w.id), false);
  await rejects(start(w.id), 'AUTO_PAYOUT_OFF');
  assert.equal((await order(customer, w.id)).status, 'pending');
  assert.equal((await wallet(customer)).pendingBalance, '5.00');
  assert.match((await settings()).heldReason, /switched off/);
});

test('live needs a passed $0.10 test: refused from off and from test before the test', async () => {
  await rejects(setMode('live'), 'TEST_REQUIRED');
  await setMode('test');
  await rejects(setMode('live'), 'TEST_REQUIRED');
  assert.equal((await settings()).mode, 'test');
});

test('test mode pays only $0.10; live opens once that payout completed AND its carrier SMS arrived', async () => {
  await setMode('test', { p_daily_limit: 100000, p_min_balance: 0 });
  const big = await withdrawal(5);
  assert.equal(await inQueue(big.w.id), false);
  await rejects(start(big.w.id), 'TEST_MODE');

  const t = await withdrawal(0.1);
  assert.equal(t.w.netAmount, '0.10');
  assert.equal(await inQueue(t.w.id), true, 'balance unknown is fine for the test payout');
  const dial = await start(t.w.id);
  assert.equal(dial.isNew, true);
  assert.equal(dial.pin, PIN);
  assert.equal(dial.code, CODE);
  assert.equal(dial.step1UssdString, `*736*${t.to}*01*{CODE}#`);
  await step1(dial.id);
  await step2(dial.id, 'success', `$0.1 ayaad uwareejisay TEST (${t.to}) PIN ${PIN}`);
  assert.equal((await order(t.customer, t.w.id)).status, 'completed');
  // The carrier screen alone is not enough to go live.
  await rejects(setMode('live'), 'TEST_REQUIRED');

  const conf = await payoutSms(t.to, '0.1', { balance: '42.50' });
  assert.equal(conf.result, 'no_matching_order', 'already completed: the SMS completes nothing more');
  const s = await settings();
  assert.equal(s.testPassed, true);
  assert.equal(s.testOrderCode, t.w.orderCode);
  assert.equal(s.balance, '42.50', 'balance read from the payout SMS');

  const on = await setMode('live');
  assert.equal(on.mode, 'live');
  assert.ok(on.liveAt);
  assert.equal(await inQueue(big.w.id), true, 'the $5 withdrawal is paid now');
  const { rows } = await db.query(`SELECT after_json FROM audit_logs WHERE action = 'auto_payout.update' ORDER BY created_at DESC LIMIT 1`);
  assert.equal(rows[0].after_json.mode, 'live');
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [big.w.id]);
});

test('changing the payout phone after going live needs a new test', async () => {
  await live();
  const { w } = await withdrawal(3);
  assert.equal(await inQueue(w.id), true);
  await db.query(`UPDATE payout_auto_settings SET live_device_id = 'old-phone' WHERE method = 'evc_plus'`);
  assert.equal(await inQueue(w.id), false);
  await rejects(start(w.id), 'RETEST_NEEDED');
  assert.equal((await settings()).liveNeedsRetest, true);
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [w.id]);
});

// ---------------------------------------------------------------------------
// Daily limit and minimum balance
// ---------------------------------------------------------------------------

test('daily limit: a payout that would pass it waits; raising the limit releases it', async () => {
  const today = cents((await settings()).paidToday);
  await live({ daily: today + 1500 });
  const a = await withdrawal(10);
  const b = await withdrawal(10);
  const d = await start(a.w.id);
  await step1(d.id);
  await step2(d.id, 'success', 'ok');
  assert.equal(await inQueue(b.w.id), false);
  await rejects(start(b.w.id), 'DAILY_LIMIT');
  assert.equal((await order(b.customer, b.w.id)).status, 'pending');
  assert.equal(cents((await settings()).paidToday), today + 1000);
  await rpc(agent, 'manage_set_auto_payout', { p_method: 'evc_plus', p_daily_limit: (today + 2000) / 100 });
  assert.equal(await inQueue(b.w.id), true);
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [b.w.id]);
});

test('a failed payout does not count toward the daily limit', async () => {
  const today = cents((await settings()).paidToday);
  await live({ daily: today + 1000 });
  const a = await withdrawal(10);
  const d = await start(a.w.id);
  await step1(d.id, 'failed', 'Network busy');
  assert.equal((await order(a.customer, a.w.id)).status, 'failed');
  const b = await withdrawal(10);
  assert.equal(await inQueue(b.w.id), true);
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [b.w.id]);
});

test('minimum balance: from the manager\'s reading less what was dialed since; the wallet SMS updates it', async () => {
  await live({ min: 500, balance: 3000 });
  const a = await withdrawal(20);
  const d = await start(a.w.id); // 30 - 20 = 10 left
  await step1(d.id);
  await step2(d.id, 'success', 'ok');
  assert.equal((await settings()).balance, '10.00');
  const b = await withdrawal(6); // 10 - 6 = 4 < 5
  await rejects(start(b.w.id), 'LOW_BALANCE');
  assert.equal(await inQueue(b.w.id), false);

  // A balance SMS from another phone does not count; from the payout SIM it does.
  const deposit = (device, slot) => rpc(agent, 'agent_ingest_payment_sms', {
    p_sender: '192', p_body: `[-EVCPLUS-] $50 ka heshay 61${randomUUID().slice(0, 7)}, Haraagaagu waa $60.00 ${randomUUID()}`,
    p_received_at: new Date().toISOString(), p_device_id: device, p_sim_slot: slot });
  await deposit('another-phone', 1);
  await deposit(PHONE, 2);
  assert.equal((await settings()).balance, '10.00');
  await deposit(PHONE, 1);
  assert.equal((await settings()).balance, '60.00');
  assert.equal(await inQueue(b.w.id), true);
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [b.w.id]);
});

test('live with no balance reading waits (balance unknown); a manager can enter it', async () => {
  await live({ balance: null });
  await db.query(`DELETE FROM payout_wallet_balances WHERE wallet_id = $1`, [walletId]);
  const { w } = await withdrawal(2);
  await rejects(start(w.id), 'BALANCE_UNKNOWN');
  const s = await rpc(agent, 'manage_set_payout_balance', { p_method: 'evc_plus', p_balance: 80 });
  assert.equal(s.balance, '80.00');
  assert.equal(s.balanceSource, 'manager');
  assert.equal(await inQueue(w.id), true);
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [w.id]);
});

// ---------------------------------------------------------------------------
// Duplicate prevention
// ---------------------------------------------------------------------------

test('duplicate prevention: three passes at once start one attempt and issue the PIN once', async () => {
  await live();
  const { customer, w, to } = await withdrawal(7);
  const results = await Promise.allSettled([start(w.id), start(w.id), start(w.id)]);
  const ok = results.filter((r) => r.status === 'fulfilled').map((r) => r.value);
  assert.ok(ok.length >= 1);
  assert.equal(ok.filter((r) => r.isNew).length, 1, 'one new attempt');
  assert.equal(ok.filter((r) => r.pin).length, 1, 'the PIN once');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM payout_dial_attempts WHERE order_id = $1`, [w.id]);
  assert.equal(rows[0].n, 1);

  const id = ok.find((r) => r.isNew).id;
  await step1(id);
  await step2(id, 'success', 'ok');
  // Replayed reports and a later carrier SMS change nothing.
  await step2(id, 'success', 'ok');
  assert.equal((await payoutSms(to, '7')).result, 'no_matching_order');
  await rejects(start(w.id), 'ALREADY_PAID');
  assert.deepEqual((await ledger(w.id)).filter((l) => l.entry_type === 'debit').length, 1, 'debited once');
  const bal = await wallet(customer);
  assert.equal(bal.availableBalance, '93.00');
  assert.equal(bal.pendingBalance, '0.00');
});

test('a withdrawal already dialed is never dialed again on its own', async () => {
  await live();
  const { w } = await withdrawal(4);
  const d = await start(w.id);
  await step1(d.id);
  await step2(d.id, 'ambiguous', 'No final confirmation');
  assert.equal(await inQueue(w.id), false);
  await rejects(start(w.id), 'NEEDS_REVIEW');
  await db.query(`UPDATE orders SET payout_review = false WHERE id = $1`, [w.id]);
  await rejects(start(w.id), 'ALREADY_DIALED');
});

// ---------------------------------------------------------------------------
// Failed transfers and timeouts
// ---------------------------------------------------------------------------

test('failed before the PIN: nothing sent, withdrawal failed, funds returned exactly', async () => {
  await live();
  const { customer, w } = await withdrawal(9);
  assert.equal((await wallet(customer)).availableBalance, '91.00');
  const d = await start(w.id);
  await step1(d.id, 'failed', 'Lambarka khaldan');
  const o = await order(customer, w.id);
  assert.equal(o.status, 'failed');
  const bal = await wallet(customer);
  assert.equal(bal.availableBalance, '100.00');
  assert.equal(bal.pendingBalance, '0.00');
  assert.deepEqual((await ledger(w.id)).map((l) => l.entry_type).sort(), ['release', 'reserve']);
});

test('failed after the PIN: held for review, no refund, no resend; manager must confirm not paid', async () => {
  await live();
  const { customer, w } = await withdrawal(8);
  const d = await start(w.id);
  await step1(d.id);
  await step2(d.id, 'failed', `Haraagaagu kuma filna (PIN ${PIN})`);
  const o = await order(customer, w.id);
  assert.equal(o.status, 'processing');
  assert.equal((await wallet(customer)).pendingBalance, '8.00', 'funds stay reserved');
  assert.equal(await inQueue(w.id), false);
  await rejects(rpc(agent, 'manage_payout_retry', { p_order_id: w.id }), 'CONFIRM_NOT_PAID');
  await rejects(rpc(agent, 'agent_withdrawal_fail', { p_order_id: w.id, p_reason: 'refund' }), 'CONFIRM_NOT_PAID');
  const detail = await rpc(agent, 'manage_payout', { p_order_id: w.id });
  assert.ok(detail.dialAttempts.every((a) => !String(a.step2Response).includes(PIN)), 'PIN scrubbed');
  assert.equal(detail.payoutReview, true);
});

test('timeout: a payout the phone never reports goes to review after 10 minutes, never refunded on its own', async () => {
  await live();
  const { customer, w, to } = await withdrawal(6);
  const d = await start(w.id);
  await step1(d.id);
  await db.query(`UPDATE payout_dial_attempts SET created_at = now() - interval '11 minutes' WHERE id = $1`, [d.id]);
  await db.query('SELECT private.expire_interrupted_payouts()');
  const detail = await rpc(agent, 'manage_payout', { p_order_id: w.id });
  assert.equal(detail.payoutReview, true);
  assert.equal(detail.status, 'processing');
  assert.equal((await wallet(customer)).pendingBalance, '6.00');
  assert.equal(await inQueue(w.id), false);

  // Reconciliation: the carrier's own SMS settles it, with its reference.
  const ref = `EVC${randomUUID().slice(0, 8)}`;
  const conf = await payoutSms(to, '6', { ref });
  assert.equal(conf.result, 'completed');
  const o = await order(customer, w.id);
  assert.equal(o.status, 'completed');
  assert.equal(o.transactionRef, ref);
  assert.equal((await rpc(agent, 'manage_payout', { p_order_id: w.id })).payoutReview, false);
  assert.equal((await ledger(w.id)).filter((l) => l.entry_type === 'debit').length, 1);
  assert.equal((await wallet(customer)).availableBalance, '94.00');
});

test('reconciliation: an SMS for a payout never dialed, or of another amount, completes nothing', async () => {
  await live();
  const { customer, w, to } = await withdrawal(5);
  assert.equal((await payoutSms(to, '5')).result, 'no_matching_order');
  const d = await start(w.id);
  await step1(d.id);
  await step2(d.id, 'ambiguous', '?');
  assert.equal((await payoutSms(to, '4.99')).result, 'no_matching_order');
  assert.equal((await order(customer, w.id)).status, 'processing');
  assert.equal((await ledger(w.id)).filter((l) => l.entry_type === 'debit').length, 0);
});

// ---------------------------------------------------------------------------
// Accounting and access
// ---------------------------------------------------------------------------

test('wallet accounting: reserve on request, one debit on payout, totals always add up', async () => {
  await live();
  const { customer, w } = await withdrawal(12, 5_000);
  let bal = await wallet(customer);
  assert.equal(cents(bal.availableBalance) + cents(bal.pendingBalance), 5000);
  const d = await start(w.id);
  await step1(d.id);
  await step2(d.id, 'success', 'ok');
  bal = await wallet(customer);
  assert.equal(bal.availableBalance, '38.00');
  assert.equal(bal.pendingBalance, '0.00');
  const entries = await ledger(w.id);
  assert.deepEqual(entries.map((l) => l.entry_type).sort(), ['debit', 'reserve']);
  assert.ok(entries.every((l) => l.cents === 1200));
});

test('only managers see or change the safeguards; the PIN never appears', async () => {
  const to = evcNumber();
  const customer = await newCustomer(0, to);
  await rejects(rpc(customer, 'manage_auto_payouts'), 'FORBIDDEN');
  await rejects(rpc(customer, 'manage_set_auto_payout', { p_method: 'evc_plus', p_mode: 'live' }), 'FORBIDDEN');
  await rejects(rpc(customer, 'manage_set_payout_balance', { p_method: 'evc_plus', p_balance: 1 }), 'FORBIDDEN');
  for (const table of ['payout_auto_settings', 'payout_wallet_balances']) {
    const { data, error } = await customer.from(table).select('*');
    assert.ok(error || data.length === 0, `${table} must not be readable`);
  }
  const all = JSON.stringify(await rpc(agent, 'manage_auto_payouts'));
  assert.ok(!all.includes(PIN));
  await rejects(rpc(agent, 'manage_set_auto_payout', { p_method: 'evc_plus', p_daily_limit: -1 }), 'VALIDATION_ERROR');
  await rejects(rpc(agent, 'manage_set_auto_payout', { p_method: 'evc_plus', p_mode: 'fast' }), 'VALIDATION_ERROR');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE after_json::text LIKE '%' || $1 || '%'
                                   AND created_at > now() - interval '1 hour' AND action LIKE '%payout%'`, [`PIN ${PIN}`]);
  assert.equal(rows[0].n, 0, 'PIN never in audit logs');
});

test('EVC needs its *736 code: without it nothing is dialed and the withdrawal stays pending', async () => {
  await live();
  const { customer, w } = await withdrawal(3);
  const { rows: [{ code_id }] } = await db.query('SELECT ussd_code_secret_id AS code_id FROM payout_wallets WHERE id = $1', [walletId]);
  await db.query('UPDATE payout_wallets SET ussd_code_secret_id = NULL WHERE id = $1', [walletId]);
  try {
    await rejects(start(w.id), 'NOT_CONFIGURED');
    assert.equal((await order(customer, w.id)).status, 'pending');
    assert.equal((await rpc(agent, 'manage_payout_wallets')).find((x) => x.id === walletId).hasCode, false);
  } finally {
    await db.query('UPDATE payout_wallets SET ussd_code_secret_id = $2 WHERE id = $1', [walletId, code_id]);
  }
  assert.equal((await rpc(agent, 'manage_payout_wallets')).find((x) => x.id === walletId).hasCode, true);
});
