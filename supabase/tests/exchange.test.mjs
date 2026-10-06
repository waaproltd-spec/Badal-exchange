// BAARI Exchange end to end: payment SMS verification (ported from Dalab
// Internet) and the automatic payout state machine, through the real
// Supabase Auth + RPC + RLS stack. Run with the other suite: npm test.
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

let agent;
let corridorEvcToEdahab;
let corridorEdahabToEvc;
let evcWallet;
let edahabWallet;
const PIN = '4321';

async function newCustomer() {
  // Created directly (register_customer allows 10 sign-ups per 15 minutes per IP).
  const phone = `2528${String(seed).padStart(6, '0')}${String(n++).padStart(3, '0')}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Exchange Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id) SELECT id FROM u`,
    [phone, PASSWORD]
  );
  return login(phone);
}

/** An EVC Plus / eDahab payment SMS as the agent app uploads it. */
function sms({ provider = 'Hormuud', amount, phone, ref = null, body, minutesAgo = 0, sender, device = null, simSlot = null }) {
  const receivedAt = new Date(Date.now() - minutesAgo * 60_000).toISOString();
  return {
    p_sender: sender ?? (provider === 'Somtel' ? 'eDahab' : '192'),
    p_body: body ?? `[-EVCPLUS-] waxaad $${amount} ka heshay ${phone}, Tar: ${receivedAt} ${randomUUID()}`,
    p_received_at: receivedAt,
    p_parsed_provider: provider,
    p_parsed_amount: String(amount),
    p_parsed_phone: phone,
    p_transaction_ref: ref,
    p_sim_slot: simSlot,
    p_device_id: device,
  };
}

async function createOrder(customer, corridor, amount, sender, receiver) {
  return rpc(customer, 'customer_create_exchange_order', {
    p_corridor_id: corridor, p_amount: String(amount), p_sender_phone: sender, p_receiver_phone: receiver,
    p_client_request_id: randomUUID(),
  });
}

before(async () => {
  agent = await login('252610000002');
  evcWallet = await rpc(agent, 'manage_save_payout_wallet', { p_id: null, p_method: 'evc_plus', p_phone_number: '617000001' });
  edahabWallet = await rpc(agent, 'manage_save_payout_wallet', { p_id: null, p_method: 'edahab', p_phone_number: '627000001' });
  await rpc(agent, 'manage_set_payout_wallet_pin', { p_id: evcWallet.id, p_pin: PIN });
  await rpc(agent, 'manage_set_payout_wallet_pin', { p_id: edahabWallet.id, p_pin: PIN });
  const settings = await rpc(agent, 'manage_exchange_settings');
  for (const c of settings.corridors) {
    const payout = c.toMethod === 'edahab' ? edahabWallet : evcWallet;
    await rpc(agent, 'manage_save_exchange_corridor', {
      p_id: c.id, p_rate: 1, p_fee_type: 'percentage', p_fee_value: 2, p_min_amount: 0.5, p_max_amount: 500,
      p_payout_wallet_id: payout.id, p_enabled: true,
    });
    if (c.fromMethod === 'evc_plus') corridorEvcToEdahab = c.id;
    else corridorEdahabToEvc = c.id;
  }
});

after(async () => {
  await db.end();
});

test('setup: options show Baari collection numbers; PIN is never readable', async () => {
  const customer = await newCustomer();
  const options = await rpc(customer, 'exchange_options');
  const evc = options.find((o) => o.fromMethod === 'evc_plus');
  assert.ok(evc.collectionPhoneNumber);
  const settings = await rpc(agent, 'manage_exchange_settings');
  assert.ok(settings.payoutWallets.every((w) => w.hasPin === true && !('pin' in w)));
  const q = await rpc(customer, 'exchange_quote', { p_corridor_id: corridorEvcToEdahab, p_amount: '10' });
  assert.equal(q.fee, '0.20');
  assert.equal(q.amountReceived, '9.80');
});

test('EVC Plus: order first, then payment SMS -> verified (phone written differently)', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const order = await createOrder(customer, corridorEvcToEdahab, 1, `252${sender}`, edahabNumber());
  assert.equal(order.status, 'pending');
  assert.equal(order.amountReceived, '0.98');
  assert.match(order.collectionUssd, /^\*712\*617000001\*1#$/);

  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 1, phone: `0${sender}` }));
  assert.equal(res.matchStatus, 'matched');
  assert.equal(res.exchangeOrderId, order.id);
  const after = await rpc(customer, 'customer_exchange_order', { p_id: order.id });
  assert.equal(after.status, 'in_progress');
  assert.ok(after.paymentVerifiedAt);
});

test('eDahab: payment SMS with its Aqanoosiga reference -> verified', async () => {
  const customer = await newCustomer();
  const sender = edahabNumber();
  const order = await createOrder(customer, corridorEdahabToEvc, 2.5, sender, evcNumber());
  assert.match(order.collectionUssd, /^\*110\*627000001\*2\*50#$/);
  const ref = `PP${seed}.0005.${randomUUID().slice(0, 6)}`;
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: 'Somtel', amount: 2.5, phone: sender, ref }));
  assert.equal(res.matchStatus, 'matched');
  const after = await rpc(customer, 'customer_exchange_order', { p_id: order.id });
  assert.equal(after.status, 'in_progress');
  assert.equal(after.paymentReference, ref);
});

test('SMS before order: stored unmatched, matched the moment the order is created', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 3, phone: sender, minutesAgo: 5 }));
  assert.equal(res.matchStatus, 'unmatched');
  const order = await createOrder(customer, corridorEvcToEdahab, 3, sender, edahabNumber());
  assert.equal(order.status, 'in_progress', 'the waiting SMS paid the new order');
  const { rows } = await db.query('SELECT match_status, matched_exchange_order_id FROM sms_logs WHERE id=$1', [res.id]);
  assert.deepEqual(rows[0], { match_status: 'matched', matched_exchange_order_id: order.id });
});

test('SMS before order: the resweep also picks it up', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 4, phone: sender }));
  assert.equal(res.matchStatus, 'unmatched');
  // Order inserted behind the API's back, as if created while the SMS waited.
  const order = await createOrder(customer, corridorEvcToEdahab, 4, evcNumber(), edahabNumber());
  await db.query(`UPDATE exchange_orders SET sender_phone=$1 WHERE id=$2`, [sender, order.id]);
  await db.query('SELECT private.resweep_unmatched_sms()');
  const after = await rpc(customer, 'customer_exchange_order', { p_id: order.id });
  assert.equal(after.status, 'in_progress');
});

test('wrong amount, near amount and wrong phone never match', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const order = await createOrder(customer, corridorEvcToEdahab, 5, sender, edahabNumber());
  for (const s of [
    sms({ amount: 5.01, phone: sender }),
    sms({ amount: 4, phone: sender }),
    sms({ amount: 5, phone: evcNumber() }),
    sms({ provider: 'Somtel', amount: 5, phone: sender }), // right phone and amount, wrong network
  ]) {
    const res = await rpc(agent, 'agent_ingest_payment_sms', s);
    assert.equal(res.matchStatus, 'unmatched', JSON.stringify(res));
  }
  assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: order.id })).status, 'pending');
});

test('duplicate SMS: same reference, or same SMS redelivered, is processed once', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const order = await createOrder(customer, corridorEvcToEdahab, 6, sender, edahabNumber());
  const first = sms({ amount: 6, phone: sender, ref: `REF${randomUUID()}` });
  assert.equal((await rpc(agent, 'agent_ingest_payment_sms', first)).matchStatus, 'matched');
  const again = await rpc(agent, 'agent_ingest_payment_sms', first);
  assert.equal(again.status, 'already_processed');
  assert.equal(again.exchangeOrderId, order.id);
  const sameRef = await rpc(agent, 'agent_ingest_payment_sms', { ...first, p_body: first.p_body + ' (resent)' });
  assert.equal(sameRef.status, 'already_processed');
  // No reference: same sender + body in the same minute.
  const noRefOrder = await createOrder(await newCustomer(), corridorEvcToEdahab, 6.5, evcNumber(), edahabNumber());
  const noRef = sms({ amount: 6.5, phone: noRefOrder.senderPhone });
  assert.equal((await rpc(agent, 'agent_ingest_payment_sms', noRef)).matchStatus, 'matched');
  assert.equal((await rpc(agent, 'agent_ingest_payment_sms', noRef)).status, 'already_processed');
  const { rows } = await db.query('SELECT count(*)::int AS n FROM sms_logs WHERE matched_exchange_order_id = ANY($1)', [[order.id, noRefOrder.id]]);
  assert.equal(rows[0].n, 2);
});

test('duplicate order processing: one payment pays one order once; retried create returns the same order', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const requestId = randomUUID();
  const args = { p_corridor_id: corridorEvcToEdahab, p_amount: '7', p_sender_phone: sender, p_receiver_phone: edahabNumber(), p_client_request_id: requestId };
  const a = await rpc(customer, 'customer_create_exchange_order', args);
  const b = await rpc(customer, 'customer_create_exchange_order', args);
  assert.equal(a.id, b.id);
  const c = await rpc(customer, 'customer_create_exchange_order', { ...args, p_client_request_id: randomUUID() });
  assert.equal(c.id, a.id, 'same unpaid exchange reuses the pending order');

  assert.equal((await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 7, phone: sender }))).matchStatus, 'matched');
  // A second, different payment SMS for the same amount: the order is no
  // longer waiting, so it is NOT attached to it.
  const second = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 7, phone: sender }));
  assert.equal(second.matchStatus, 'unmatched');
  await rejects(rpc(agent, 'manage_exchange_verify', { p_id: a.id }), 'INVALID_ORDER_STATE');
});

test('ambiguous: two orders fit one payment -> nothing moves until a manager decides', async () => {
  const customer = await newCustomer();
  const sender = evcNumber();
  const exchange = await createOrder(customer, corridorEvcToEdahab, 8, sender, edahabNumber());
  // The same customer also has a wallet deposit pending for the same payment.
  await rpc(customer, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '8', p_idempotency_key: randomUUID(), p_phone_number: sender });
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ amount: 8, phone: sender }));
  assert.equal(res.matchStatus, 'ambiguous');
  assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: exchange.id })).status, 'pending');
  assert.equal((await rpc(customer, 'customer_wallet')).availableBalance, '0.00');
  const waiting = await rpc(agent, 'manage_payment_sms', { p_status: 'ambiguous' });
  assert.ok(waiting.some((s) => s.id === res.id));
  const resolved = await rpc(agent, 'manage_resolve_payment_sms', { p_sms_id: res.id, p_exchange_order_id: exchange.id });
  assert.equal(resolved.status, 'in_progress');
});

test('device/SIM guard: once the collection wallet has a device, SMS from another device do not count', async () => {
  await rpc(agent, 'manage_save_payout_wallet', { p_id: edahabWallet.id, p_method: 'edahab', p_phone_number: '627000001', p_device_id: 'collect-phone', p_sim_slot: 2 });
  try {
    const customer = await newCustomer();
    const sender = edahabNumber();
    const order = await createOrder(customer, corridorEdahabToEvc, 9, sender, evcNumber());
    const wrong = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: 'Somtel', amount: 9, phone: sender, device: 'other-phone', simSlot: 2 }));
    assert.equal(wrong.matchStatus, 'unmatched');
    assert.match(wrong.reason, /device/);
    const right = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: 'Somtel', amount: 9, phone: sender, device: 'collect-phone', simSlot: 2 }));
    assert.equal(right.matchStatus, 'matched');
    assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: order.id })).status, 'in_progress');
  } finally {
    await rpc(agent, 'manage_save_payout_wallet', { p_id: edahabWallet.id, p_method: 'edahab', p_phone_number: '627000001' });
  }
});

async function verifiedOrder(amount, corridor = corridorEvcToEdahab) {
  const customer = await newCustomer();
  const evcFirst = corridor === corridorEvcToEdahab;
  const sender = evcFirst ? evcNumber() : edahabNumber();
  const order = await createOrder(customer, corridor, amount, sender, evcFirst ? edahabNumber() : evcNumber());
  const res = await rpc(agent, 'agent_ingest_payment_sms', sms({ provider: evcFirst ? 'Hormuud' : 'Somtel', amount, phone: sender }));
  assert.equal(res.matchStatus, 'matched');
  return { customer, order };
}

test('payout never starts before the payment is verified', async () => {
  const customer = await newCustomer();
  const order = await createOrder(customer, corridorEvcToEdahab, 10, evcNumber(), edahabNumber());
  await rejects(rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id }), 'INVALID_ORDER_STATE');
});

test('successful payout: PIN issued once, completed once', async () => {
  const { customer, order } = await verifiedOrder(11);
  const queue = await rpc(agent, 'agent_exchange_payout_queue');
  const queued = queue.find((o) => o.id === order.id);
  assert.equal(queued.hasDialAttempt, false);

  const dial = await rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id });
  assert.equal(dial.isNew, true);
  assert.equal(dial.pin, PIN);
  assert.equal(dial.step1UssdString, `*110*${order.receiverPhone}*10*78#`); // 11 - 2% = 10.78
  const again = await rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id });
  assert.equal(again.id, dial.id);
  assert.equal(again.pin, undefined, 'the PIN is never handed out twice for one attempt');

  await rpc(agent, 'agent_exchange_report_step1', { p_attempt_id: dial.id, p_status: 'step1_success', p_response: 'Enter PIN' });
  await rpc(agent, 'agent_exchange_report_step2', { p_attempt_id: dial.id, p_status: 'success', p_response: `Sent. PIN ${PIN}` });
  const done = await rpc(customer, 'customer_exchange_order', { p_id: order.id });
  assert.equal(done.status, 'completed');
  // Reporting success again changes nothing; a new dial is refused.
  await rpc(agent, 'agent_exchange_report_step2', { p_attempt_id: dial.id, p_status: 'success' });
  await rejects(rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id }), 'INVALID_ORDER_STATE');
  const detail = await rpc(agent, 'manage_exchange_order', { p_id: order.id });
  assert.ok(!JSON.stringify(detail).includes(PIN), 'PIN scrubbed from stored carrier text');
  assert.ok(detail.history.some((h) => h.action === 'exchange_payment_verified'));
  assert.ok(detail.history.some((h) => h.action === 'exchange_completed'));
  assert.ok(detail.paymentSms);
});

test('failed payout: order is failed (not completed) and leaves the auto-dial queue', async () => {
  const { customer, order } = await verifiedOrder(12);
  const dial = await rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id });
  await rpc(agent, 'agent_exchange_report_step1', { p_attempt_id: dial.id, p_status: 'step1_success' });
  await rpc(agent, 'agent_exchange_report_step2', { p_attempt_id: dial.id, p_status: 'failed', p_response: 'Insufficient balance' });
  const failed = await rpc(customer, 'customer_exchange_order', { p_id: order.id });
  assert.equal(failed.status, 'failed');
  assert.match(failed.failureReason, /Insufficient/);
  const queue = await rpc(agent, 'agent_exchange_payout_queue');
  assert.ok(!queue.some((o) => o.id === order.id));
});

test('retry after a failed payout: new attempt, no double payout', async () => {
  const { customer, order } = await verifiedOrder(13);
  const first = await rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id });
  await rpc(agent, 'agent_exchange_report_step1', { p_attempt_id: first.id, p_status: 'failed', p_response: 'Network busy' });
  assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: order.id })).status, 'failed');

  await rpc(agent, 'manage_exchange_retry_payout', { p_id: order.id });
  await rpc(agent, 'manage_exchange_request_payout', { p_id: order.id });
  const queued = (await rpc(agent, 'agent_exchange_payout_queue')).find((o) => o.id === order.id);
  assert.equal(queued.hasDialAttempt, true);
  assert.equal(queued.payoutRequested, true);
  const second = await rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id });
  assert.notEqual(second.id, first.id);
  assert.equal(second.pin, PIN);
  await rpc(agent, 'agent_exchange_report_step1', { p_attempt_id: second.id, p_status: 'step1_success' });
  await rpc(agent, 'agent_exchange_report_step2', { p_attempt_id: second.id, p_status: 'success' });
  assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: order.id })).status, 'completed');
  await rejects(rpc(agent, 'manage_exchange_retry_payout', { p_id: order.id }), 'INVALID_ORDER_STATE');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM exchange_dial_attempts WHERE exchange_order_id=$1 AND status='success'`, [order.id]);
  assert.equal(rows[0].n, 1);
});

test('unclear payout: retry needs confirmation; the carrier payout SMS completes it instead', async () => {
  const { customer, order } = await verifiedOrder(14);
  const dial = await rpc(agent, 'agent_exchange_start_dial', { p_order_id: order.id });
  await rpc(agent, 'agent_exchange_report_step1', { p_attempt_id: dial.id, p_status: 'step1_success' });
  await rpc(agent, 'agent_exchange_report_step2', { p_attempt_id: dial.id, p_status: 'ambiguous', p_response: '(no confirmation screen)' });
  assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: order.id })).status, 'failed');
  await rejects(rpc(agent, 'manage_exchange_retry_payout', { p_id: order.id }), 'CONFIRM_NOT_PAID');

  // The carrier's own "ayaad u warejisay" SMS shows the money did go out.
  const conf = await rpc(agent, 'agent_exchange_payout_confirmation', {
    p_receiver_phone: `0${order.receiverPhone}`, p_amount: order.amountReceived, p_raw_text: 'X Dollar ayad u warejisay ...', p_provider: 'Somtel' });
  assert.equal(conf.result, 'completed');
  assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: order.id })).status, 'completed');
  await rejects(rpc(agent, 'manage_exchange_retry_payout', { p_id: order.id, p_confirmed_not_paid: true }), 'INVALID_ORDER_STATE');
});

test('payout SMS alone never completes an order that was not dialed', async () => {
  const { customer, order } = await verifiedOrder(15);
  const conf = await rpc(agent, 'agent_exchange_payout_confirmation', {
    p_receiver_phone: order.receiverPhone, p_amount: order.amountReceived, p_raw_text: 'stray' });
  assert.equal(conf.result, 'ignored_no_dial_attempt');
  assert.equal((await rpc(customer, 'customer_exchange_order', { p_id: order.id })).status, 'in_progress');
});

test('permissions: customers cannot see other orders, run payouts or read SMS', async () => {
  const { order } = await verifiedOrder(16);
  const other = await newCustomer();
  await rejects(rpc(other, 'customer_exchange_order', { p_id: order.id }), 'NOT_FOUND');
  await rejects(rpc(other, 'agent_exchange_start_dial', { p_order_id: order.id }), 'FORBIDDEN');
  await rejects(rpc(other, 'agent_ingest_payment_sms', sms({ amount: 1, phone: evcNumber() })), 'FORBIDDEN');
  await rejects(rpc(other, 'manage_payment_sms'), 'FORBIDDEN');
  const { data } = await other.from('exchange_orders').select('id');
  assert.equal(data.length, 0);
  const { error } = await other.from('sms_logs').select('id');
  assert.ok(error);
});
