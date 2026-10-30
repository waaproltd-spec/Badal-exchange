// Deposits wait unseen until verified (migrations/*_deposit_waiting.sql): a
// deposit waiting for its payment is not in the customer's orders and credits
// nothing; verified, it shows once, credited once, with its reference; a failed
// or unclear deposit is told to the admin's Telegram and never shown as an
// order. Run with the other suites: npm test.
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

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
let agent;
async function customer() {
  const number = `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Waiting Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 0 FROM u RETURNING customer_id`, [`252${number}`, PASSWORD]);
  return { c: await login(`252${number}`), number, id: u.customer_id };
}
const deposit = (cu, amount) => rpc(cu.c, 'customer_create_deposit', {
  p_method: 'evc_plus', p_amount: String(amount), p_phone_number: `252${cu.number}`, p_idempotency_key: randomUUID() });
const wallet = async (cu) => (await rpc(cu.c, 'customer_wallet')).availableBalance;
const listed = async (cu) => rpc(cu.c, 'customer_orders');
const sms = ({ amount, phone, ref }) => {
  const receivedAt = new Date().toISOString();
  return {
    p_sender: '192', p_body: `[-EVCPLUS-] waxaad $${amount} ka heshay ${phone}, Tar: ${receivedAt} ${randomUUID()}`, p_received_at: receivedAt,
    p_parsed_provider: 'Hormuud', p_parsed_amount: String(amount), p_parsed_phone: phone, p_transaction_ref: ref, p_sim_slot: 1, p_device_id: 'waiting-phone',
  };
};
const incidents = async (cu) => (await db.query(
  `SELECT direction, kind, order_code, error_text, source FROM payment_incidents WHERE customer_id = $1 ORDER BY created_at`, [cu.id])).rows;

before(async () => { agent = await login('252610000002'); });
after(async () => { await db.end(); });

test('a deposit waiting for its payment is not an order in the customer\'s list and credits nothing', async () => {
  const cu = await customer();
  const d = await deposit(cu, 6);
  assert.equal(d.status, 'pending');
  assert.equal((await listed(cu)).length, 0, 'not listed while waiting');
  assert.equal(await wallet(cu), '0.00');
  // The waiting screen can still follow it by its id.
  assert.equal((await rpc(cu.c, 'customer_order', { p_id: d.id })).status, 'pending');
});

test('verified: it shows once, credited once, with its reference; completing it again credits nothing', async () => {
  const cu = await customer();
  const d = await deposit(cu, 7);
  const ref = `WT${randomUUID().slice(0, 10)}`;
  // The payment is verified (as the SMS match, the Sahal feed and the cash-desk bot do): the order completes.
  await db.query(`SELECT private.complete_deposit_order($1, $2, NULL, NULL)`, [d.id, ref]);
  const rows = await listed(cu);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, 'completed');
  assert.equal(rows[0].transactionRef, ref);
  assert.equal(await wallet(cu), '7.00');
  // The very same payment again (a second SMS, a repeated feed row): refused, nothing more is credited.
  await assert.rejects(db.query(`SELECT private.complete_deposit_order($1, $2, NULL, NULL)`, [d.id, ref]));
  assert.equal(await wallet(cu), '7.00');
  const { rows: [c] } = await db.query(
    `SELECT count(*)::int AS n FROM ledger_entries l JOIN wallets w ON w.id = l.wallet_id WHERE w.customer_id = $1`, [cu.id]);
  assert.equal(c.n, 1, 'one credit in the ledger');
});

test('a rejected deposit is never shown as an order, credits nothing, and the admin is told', async () => {
  const cu = await customer();
  const d = await deposit(cu, 9);
  await rpc(agent, 'agent_reject_deposit', { p_order_id: d.id, p_reason: 'Payment not received' });
  assert.equal((await listed(cu)).length, 0);
  assert.equal(await wallet(cu), '0.00');
  const found = await incidents(cu);
  assert.equal(found.length, 1);
  assert.equal(found[0].direction, 'deposit');
  assert.equal(found[0].kind, 'failed');
  assert.equal(found[0].order_code, d.orderCode);
  assert.match(found[0].error_text, /Payment not received/);
});

test('a deposit the payment service could not verify (a note, still unpaid) is told to the admin and credits nothing', async () => {
  const cu = await customer();
  const d = await deposit(cu, 4);
  await db.query(`UPDATE orders SET failure_reason = 'The payment service gave no clear answer' WHERE id = $1`, [d.id]);
  const found = await incidents(cu);
  assert.equal(found.length, 1);
  assert.equal(found[0].kind, 'unverified');
  assert.equal(await wallet(cu), '0.00');
  assert.equal((await listed(cu)).length, 0);
});

test('withdrawals are listed as before', async () => {
  const cu = await customer();
  await db.query(`UPDATE wallets SET available_cents = 5000 WHERE customer_id = $1`, [cu.id]);
  await rpc(cu.c, 'customer_create_withdrawal', { p_method: 'evc_plus', p_amount: '5', p_phone_number: `252${cu.number}`, p_idempotency_key: randomUUID() });
  const rows = await listed(cu);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].direction, 'withdraw');
});
