// BAARI deposits and withdrawals, Dalab Reseller style, end to end through
// the real Supabase Auth + RPC + RLS stack:
//   deposit  -> the carrier's payment SMS verifies it -> wallet credited
//   withdraw -> funds reserved -> the agent phone pays out by USSD ->
//               wallet debited only on a confirmed payout
// Run with the other suite: npm test.
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
async function login(phone, password = PASSWORD) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: authEmail(phone), password });
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

// Unique 9-digit numbers per run so tests never see each other's orders.
const seed = Number(Date.now().toString().slice(-6));
let n = 0;
const evcNumber = () => `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
const edahabNumber = () => `62${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;

const PHONE = 'payout-phone';
const PIN = '4321';
let agent;

async function newCustomer(balanceCents = 0) {
  // Created directly (register_customer allows 10 sign-ups per 15 minutes per IP).
  const phone = `2528${String(seed).padStart(6, '0')}${String(n++).padStart(3, '0')}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Payments Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u`,
    [phone, PASSWORD, balanceCents]
  );
  return login(phone);
}

/** A payment SMS as the agent app uploads it. */
function sms({ provider = 'Hormuud', amount, phone, ref = null, body, minutesAgo = 0, sender, device = PHONE, simSlot }) {
  const receivedAt = new Date(Date.now() - minutesAgo * 60_000).toISOString();
  return {
    p_sender: sender ?? (provider === 'Somtel' ? 'eDahab' : '192'),
    p_body: body ?? `[-EVCPLUS-] waxaad $${amount} ka heshay ${phone}, Tar: ${receivedAt} ${randomUUID()}`,
    p_received_at: receivedAt,
    p_parsed_provider: provider,
    p_parsed_amount: String(amount),
    p_parsed_phone: phone,
    p_transaction_ref: ref,
    p_sim_slot: simSlot ?? (provider === 'Somtel' ? 2 : 1),
    p_device_id: device,
  };
}

const deposit = (customer, method, amount, phone) => rpc(customer, 'customer_create_deposit', {
  p_method: method, p_amount: String(amount), p_phone_number: phone, p_idempotency_key: randomUUID() });
const withdraw = (customer, method, amount, phone) => rpc(customer, 'customer_create_withdrawal', {
  p_method: method, p_amount: String(amount), p_phone_number: phone, p_idempotency_key: randomUUID() });
const order = async (customer, id) => (await rpc(customer, 'customer_orders')).find((o) => o.id === id)
  ?? rpc(customer, 'customer_order', { p_id: id });
const wallet = (customer) => rpc(customer, 'customer_wallet');

before(async () => {
  agent = await login('252610000002');
  // Baari's EVC Plus wallet on SIM 1 and eDahab on SIM 2 of the agent phone
  // (made the oldest of each kind, so they are the payout wallets).
  for (const [method, number, slot] of [['evc_plus', '617000001', 1], ['edahab', '627000001', 2]]) {
    const w = await rpc(agent, 'manage_save_payout_wallet', { p_id: null, p_method: method, p_phone_number: number, p_device_id: PHONE, p_sim_slot: slot });
    await rpc(agent, 'manage_set_payout_wallet_pin', { p_id: w.id, p_pin: PIN });
    await db.query(`UPDATE public.payout_wallets SET created_at = now() - interval '10 years' WHERE id = $1`, [w.id]);
    await db.query(`UPDATE public.payout_wallets SET device_id = NULL WHERE method = $1 AND id <> $2`, [method, w.id]);
  }
});

after(async () => {
  await db.end();
});

// ---------------------------------------------------------------------------
// Deposits
// ---------------------------------------------------------------------------

test('EVC Plus deposit: order first, then the real SMS (0-prefixed phone, no reference) -> credited once', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const d = await deposit(customer, 'evc_plus', 5, `252${sender}`);
  assert.equal(d.status, 'pending');
  assert.equal((await wallet(customer)).availableBalance, '0.00');

  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 5, phone: `0${sender}`,
    body: `[-EVCPLUS-] waxaad $5 ka heshay 0${sender}, Tar: 06/10/26 20:19:52 haraagagu waa $2.505.` }));
  assert.equal(res.matchStatus, 'matched');
  assert.equal(res.orderId, d.id);
  const done = await order(customer, d.id);
  assert.equal(done.status, 'completed');
  assert.equal((await wallet(customer)).availableBalance, done.netAmount);

  const { rows } = await db.query(`SELECT action, after_json FROM audit_logs WHERE entity_type='order' AND entity_id=$1`, [d.id]);
  const audit = rows.find((r) => r.action === 'deposit_verified_by_sms');
  assert.ok(audit, 'audit entry');
  assert.equal(audit.after_json.provider, 'Hormuud');
  assert.ok(audit.after_json.smsReceivedAt);
});

test('eDahab deposit with its Aqanoosiga reference', async () => {
  const customer = await newCustomer();
  const sender = edahabNumber();
  const d = await deposit(customer, 'edahab', 7, sender);
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: 'Somtel', amount: 7, phone: sender, ref: `PP${randomUUID().slice(0, 12)}` }));
  assert.equal(res.matchStatus, 'matched');
  assert.equal((await order(customer, d.id)).status, 'completed');
});

test('SMS before the deposit order: kept, then matched the moment the order is created', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 4, phone: sender }));
  assert.equal(res.matchStatus, 'unmatched');
  const d = await deposit(customer, 'evc_plus', 4, `0${sender}`);
  assert.equal(d.status, 'completed');
});

test('SMS before the deposit order: the minute resweep also picks it up', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 6, phone: sender }));
  // An order created by an app path that does not look for waiting SMS.
  const d = await deposit(customer, 'evc_plus', 6, evcNumber());
  assert.equal(d.status, 'pending');
  await db.query(`UPDATE orders SET phone_number = $2 WHERE id = $1`, [d.id, sender]);
  await db.query('SELECT private.resweep_unmatched_sms()');
  assert.equal((await order(customer, d.id)).status, 'completed');
});

test('wrong amount, near amount and wrong phone never credit', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const d = await deposit(customer, 'evc_plus', 10, sender);
  for (const s of [sms({ amount: 11, phone: sender }), sms({ amount: 10.01, phone: sender }), sms({ amount: 10, phone: evcNumber() }),
                   sms({ provider: 'Somtel', amount: 10, phone: sender })]) {
    const res = await rpc(agent, 'agent_ingest_payment_sms', s);
    assert.notEqual(res.matchStatus, 'matched');
  }
  assert.equal((await order(customer, d.id)).status, 'pending');
  assert.equal((await wallet(customer)).availableBalance, '0.00');
});

test('duplicate SMS (same reference, or redelivered) credits once', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const d1 = await deposit(customer, 'evc_plus', 3, sender);
  const ref = `R${randomUUID().slice(0, 10)}`;
  const first = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 3, phone: sender, ref }));
  assert.equal(first.orderId, d1.id);
  const d2 = await deposit(customer, 'evc_plus', 3, sender);
  const again = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 3, phone: sender, ref }));
  assert.equal(again.status, 'already_processed');
  const s = sms({ amount: 3, phone: sender });
  const a = await rpc(agent, 'agent_ingest_payment_sms', s);
  const b = await rpc(agent, 'agent_ingest_payment_sms', s);
  assert.equal(a.orderId, d2.id);
  assert.equal(b.status, 'already_processed');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM ledger_entries l JOIN wallets w ON w.id = l.wallet_id
    JOIN orders o ON o.id = l.order_id WHERE o.id = ANY($1) AND l.entry_type = 'credit'`, [[d1.id, d2.id]]);
  assert.equal(rows[0].n, 2);
});

test('ambiguous: two deposits fit one payment -> nothing credited until a manager assigns it', async () => {
  const c1 = await newCustomer();
  const c2 = await newCustomer();
  const sender = evcNumber();
  const a = await deposit(c1, 'evc_plus', 8, sender);
  const b = await deposit(c2, 'evc_plus', 8, sender);
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 8, phone: sender }));
  assert.equal(res.matchStatus, 'ambiguous');
  assert.equal((await order(c1, a.id)).status, 'pending');
  assert.equal((await order(c2, b.id)).status, 'pending');
  const waiting = await rpc(agent, 'manage_payment_sms', { p_status: 'ambiguous' });
  assert.ok(waiting.some((s) => s.id === res.id));

  const other = await deposit(c1, 'evc_plus', 80, sender);
  await rejects(rpc(agent, 'manage_resolve_payment_sms', { p_sms_id: res.id, p_order_code: other.orderCode }), 'PAYMENT_MISMATCH');
  const resolved = await rpc(agent, 'manage_resolve_payment_sms', { p_sms_id: res.id, p_order_code: b.orderCode });
  assert.equal(resolved.status, 'completed');
  await rejects(rpc(agent, 'manage_resolve_payment_sms', { p_sms_id: res.id, p_order_code: a.orderCode }), 'INVALID_STATE');
  assert.equal((await order(c1, a.id)).status, 'pending');
});

test('device/SIM guard: SMS from another phone or SIM never credit', async () => {
  const customer = await newCustomer();
  const sender = edahabNumber();
  const d = await deposit(customer, 'edahab', 9, sender);
  const wrongPhone = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: 'Somtel', amount: 9, phone: sender, device: 'other-phone' }));
  assert.equal(wrongPhone.matchStatus, 'unmatched');
  assert.match(wrongPhone.reason, /device/);
  const wrongSim = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: 'Somtel', amount: 9, phone: sender, simSlot: 1 }));
  assert.equal(wrongSim.matchStatus, 'unmatched');
  const right = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: 'Somtel', amount: 9, phone: sender }));
  assert.equal(right.matchStatus, 'matched');
  assert.equal((await order(customer, d.id)).status, 'completed');
});

// ---------------------------------------------------------------------------
// Withdrawals
// ---------------------------------------------------------------------------

async function startedPayout(amount, method = 'edahab') {
  const customer = await newCustomer(10_000);
  const to = method === 'edahab' ? edahabNumber() : evcNumber();
  const w = await withdraw(customer, method, amount, to);
  assert.equal(w.status, 'pending');
  const reserved = (await wallet(customer)).pendingBalance;
  return { customer, w, to, reserved, left: (100 - Number(reserved)).toFixed(2) };
}

test('withdrawal: funds reserved, paid out from the agent phone, debited once', async () => {
  const { customer, w, to } = await startedPayout(11);
  let bal = await wallet(customer);
  const afterReserve = bal.availableBalance; // 100 - (amount + fee)
  assert.ok(Number(afterReserve) <= 89);
  assert.equal((Number(afterReserve) + Number(bal.pendingBalance)).toFixed(2), '100.00');

  const queue = await rpc(agent, 'agent_payout_queue');
  const q = queue.find((o) => o.id === w.id);
  assert.ok(q, 'in the payout queue');
  assert.equal(q.payoutDeviceId, PHONE);
  assert.equal(q.payoutSimSlot, 2);

  await rejects(rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: 'other-phone' }), 'WRONG_DEVICE');
  const dial = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  assert.equal(dial.isNew, true);
  assert.equal(dial.pin, PIN);
  const net = Number(w.netAmount);
  const cents = Math.round((net - Math.trunc(net)) * 100);
  assert.equal(dial.step1UssdString, `*110*${to}*${Math.trunc(net)}${cents ? `*${String(cents).padStart(2, '0')}` : ''}#`);
  assert.equal((await order(customer, w.id)).status, 'processing');
  // A second start returns the same unfinished attempt, never the PIN again.
  const again = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  assert.equal(again.id, dial.id);
  assert.equal(again.pin, undefined);

  await rpc(agent, 'agent_payout_report_step1', { p_attempt_id: dial.id, p_status: 'step1_success', p_response: 'Geli PIN' });
  await rpc(agent, 'agent_payout_report_step2', { p_attempt_id: dial.id, p_status: 'success', p_response: `$${net} ayaad uwareejisay X PIN ${PIN}` });
  const done = await order(customer, w.id);
  assert.equal(done.status, 'completed');
  bal = await wallet(customer);
  assert.equal(bal.availableBalance, afterReserve);
  assert.equal(bal.pendingBalance, '0.00');
  // Reporting success again, or another start, never pays twice.
  await rpc(agent, 'agent_payout_report_step2', { p_attempt_id: dial.id, p_status: 'success' });
  await rejects(rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE }), 'ALREADY_PAID');
  const detail = await rpc(agent, 'manage_payout', { p_order_id: w.id });
  assert.ok(!JSON.stringify(detail).includes(PIN), 'PIN scrubbed from stored carrier text');
  assert.ok(detail.history.some((h) => h.action === 'withdrawal_payout_completed'));
});

test('payout fails before the PIN step: withdrawal failed, funds returned', async () => {
  const { customer, w } = await startedPayout(12);
  const dial = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  await rpc(agent, 'agent_payout_report_step1', { p_attempt_id: dial.id, p_status: 'failed', p_response: 'Network busy' });
  const failed = await order(customer, w.id);
  assert.equal(failed.status, 'failed');
  assert.equal((await wallet(customer)).availableBalance, '100.00');
  assert.ok(!(await rpc(agent, 'agent_payout_queue')).some((o) => o.id === w.id));
});

test('payout fails after the PIN: never completed, funds held; retry needs confirmation and never pays twice', async () => {
  const { customer, w, reserved, left } = await startedPayout(13);
  const first = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  await rpc(agent, 'agent_payout_report_step1', { p_attempt_id: first.id, p_status: 'step1_success' });
  await rpc(agent, 'agent_payout_report_step2', { p_attempt_id: first.id, p_status: 'failed', p_response: 'Haraagaagu kuma filna' });
  const held = await order(customer, w.id);
  assert.equal(held.status, 'processing');
  assert.match(held.failureReason, /kuma filna/);
  assert.equal((await wallet(customer)).pendingBalance, reserved);
  // Not redialed on its own; can't be failed (released) or retried blind.
  assert.ok(!(await rpc(agent, 'agent_payout_queue')).some((o) => o.id === w.id));
  await rejects(rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE }), 'NEEDS_REVIEW');
  await rejects(rpc(agent, 'agent_withdrawal_fail', { p_order_id: w.id, p_reason: 'carrier said no' }), 'CONFIRM_NOT_PAID');
  await rejects(rpc(agent, 'manage_payout_retry', { p_order_id: w.id }), 'CONFIRM_NOT_PAID');
  assert.ok((await rpc(agent, 'manage_payouts', { p_review_only: true })).some((o) => o.id === w.id));

  await rpc(agent, 'manage_payout_retry', { p_order_id: w.id, p_confirmed_not_paid: true });
  const queued = (await rpc(agent, 'agent_payout_queue')).find((o) => o.id === w.id);
  assert.equal(queued.payoutRequested, true);
  const second = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  assert.notEqual(second.id, first.id);
  assert.equal(second.pin, PIN);
  await rpc(agent, 'agent_payout_report_step1', { p_attempt_id: second.id, p_status: 'step1_success' });
  await rpc(agent, 'agent_payout_report_step2', { p_attempt_id: second.id, p_status: 'success', p_response: 'ayaad u warejisay' });
  assert.equal((await order(customer, w.id)).status, 'completed');
  assert.equal((await wallet(customer)).availableBalance, left);
  await rejects(rpc(agent, 'manage_payout_retry', { p_order_id: w.id, p_confirmed_not_paid: true }), 'INVALID_ORDER_STATE');
  await rejects(rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE }), 'ALREADY_PAID');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM payout_dial_attempts WHERE order_id=$1 AND status='success'`, [w.id]);
  assert.equal(rows[0].n, 1);
  const { rows: debits } = await db.query(`SELECT count(*)::int AS n FROM ledger_entries WHERE order_id=$1 AND entry_type='debit'`, [w.id]);
  assert.equal(debits[0].n, 1);
});

test('unclear payout: the carrier\'s "you transferred" SMS on the payout phone completes it (an older one does not)', async () => {
  const { customer, w, to, left } = await startedPayout(14);
  const dial = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  await rpc(agent, 'agent_payout_report_step1', { p_attempt_id: dial.id, p_status: 'step1_success' });
  await rpc(agent, 'agent_payout_report_step2', { p_attempt_id: dial.id, p_status: 'ambiguous', p_response: '(no confirmation screen)' });
  assert.equal((await order(customer, w.id)).status, 'processing');

  const stale = await rpc(agent, 'agent_payout_confirmation', { p_receiver_phone: to, p_amount: w.netAmount, p_raw_text: 'old',
    p_provider: 'Somtel', p_received_at: new Date(Date.now() - 3600_000).toISOString() });
  assert.equal(stale.result, 'no_matching_order');
  const conf = await rpc(agent, 'agent_payout_confirmation', { p_receiver_phone: `0${to}`, p_amount: w.netAmount,
    p_raw_text: `${w.netAmount} Dollar ayad u warejisay X. No: ${to}`, p_provider: 'Somtel', p_received_at: new Date().toISOString() });
  assert.equal(conf.result, 'completed');
  assert.equal((await order(customer, w.id)).status, 'completed');
  assert.equal((await wallet(customer)).availableBalance, left);
  await rejects(rpc(agent, 'manage_payout_retry', { p_order_id: w.id, p_confirmed_not_paid: true }), 'INVALID_ORDER_STATE');
});

test('payout SMS alone never completes a withdrawal that was not dialed', async () => {
  const { customer, w, to } = await startedPayout(15);
  await rpc(agent, 'agent_withdrawal_start', { p_order_id: w.id }); // manual "processing", no dial
  const conf = await rpc(agent, 'agent_payout_confirmation', { p_receiver_phone: to, p_amount: w.netAmount, p_raw_text: 'stray', p_provider: 'Somtel' });
  assert.equal(conf.result, 'ignored_no_dial_attempt');
  assert.equal((await order(customer, w.id)).status, 'processing');
});

test('interrupted payout (phone never reports): review after 10 minutes; a late success still counts', async () => {
  const { customer, w } = await startedPayout(16, 'evc_plus');
  const dial = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  assert.match(dial.step1UssdString, /^\*712\*/);
  await rpc(agent, 'agent_payout_report_step1', { p_attempt_id: dial.id, p_status: 'step1_success' });
  await db.query(`UPDATE payout_dial_attempts SET created_at = now() - interval '11 minutes' WHERE id = $1`, [dial.id]);
  await db.query('SELECT private.resweep_unmatched_sms()');
  const held = await order(customer, w.id);
  assert.equal(held.status, 'processing');
  await rejects(rpc(agent, 'manage_payout_retry', { p_order_id: w.id }), 'CONFIRM_NOT_PAID');
  await rpc(agent, 'agent_payout_report_step2', { p_attempt_id: dial.id, p_status: 'success', p_response: '$1 ayaad uwareejisay X' });
  assert.equal((await order(customer, w.id)).status, 'completed');
});

test('manual fail after an unclear payout needs "not paid", then returns the funds', async () => {
  const { customer, w } = await startedPayout(17);
  const dial = await rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE });
  await rejects(rpc(agent, 'agent_withdrawal_fail', { p_order_id: w.id, p_reason: 'stop it' }), 'PAYOUT_RUNNING');
  await rpc(agent, 'agent_payout_report_step1', { p_attempt_id: dial.id, p_status: 'step1_success' });
  await rpc(agent, 'agent_payout_report_step2', { p_attempt_id: dial.id, p_status: 'ambiguous', p_response: '?' });
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: w.id, p_reason: 'Checked: not sent', p_confirmed_not_paid: true });
  assert.equal((await order(customer, w.id)).status, 'failed');
  assert.equal((await wallet(customer)).availableBalance, '100.00');
});

test('methods without a payout wallet (Golis, ...) stay manual', async () => {
  const customer = await newCustomer(10_000);
  const w = await withdraw(customer, 'golis', 5, '901234567');
  assert.ok(!(await rpc(agent, 'agent_payout_queue')).some((o) => o.id === w.id));
  await rejects(rpc(agent, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE }), 'NOT_CONFIGURED');
});

test('permissions: customers cannot run payouts, read SMS or see wallets/PINs', async () => {
  const customer = await newCustomer(10_000);
  const w = await withdraw(customer, 'edahab', 5, edahabNumber());
  await rejects(rpc(customer, 'agent_payout_start_dial', { p_order_id: w.id, p_device_id: PHONE }), 'FORBIDDEN');
  await rejects(rpc(customer, 'agent_ingest_payment_sms', sms({ amount: 1, phone: evcNumber() })), 'FORBIDDEN');
  await rejects(rpc(customer, 'manage_payment_sms'), 'FORBIDDEN');
  await rejects(rpc(customer, 'manage_payout_wallets'), 'FORBIDDEN');
  for (const table of ['sms_logs', 'payout_wallets', 'payout_dial_attempts']) {
    const { data, error } = await customer.from(table).select('*');
    assert.ok(error || data.length === 0, `${table} must not be readable`);
  }
  const wallets = await rpc(agent, 'manage_payout_wallets');
  assert.ok(wallets.every((x) => !('pin' in x)));
  // Clean up: nothing left in the payout queue for the app tests.
  await rpc(agent, 'agent_withdrawal_fail', { p_order_id: w.id, p_reason: 'test cleanup' });
});
