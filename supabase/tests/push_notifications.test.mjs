// Customer push notifications (migrations/*_push_notifications.sql and
// functions/push-notifications), against a stand-in Firebase.
//
//   node tests/make-functions-env.mjs
//   supabase functions serve --env-file tests/.functions.env
//   SUPABASE_SERVICE_ROLE_KEY=... npm test

import { test, before, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const client = (key = ANON_KEY) => createClient(URL, key, { auth: { persistSession: false, autoRefreshToken: false } });
const seed = Number(Date.now().toString().slice(-6));
let n = 0;

const DEPOSIT = { title: 'Deposit-kaagu wuu guulaystay', body: 'Lacagta deposit-kaaga si guul leh ayaa loo xaqiijiyey.' };
const WITHDRAW = { title: 'Withdrawal-kaagu wuu guulaystay', body: 'Lacagtaada si guul leh ayaa loo bixiyey.' };

// Stand-in Firebase: OAuth token endpoint and FCM v1 send.
const sent = [];
let tokenRequests = 0;
const standIn = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (req.url === '/token') {
      tokenRequests++;
      const p = new URLSearchParams(body);
      const ok = p.get('grant_type') === 'urn:ietf:params:oauth:grant-type:jwt-bearer' && p.get('assertion')?.split('.').length === 3;
      res.writeHead(ok ? 200 : 400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(ok ? { access_token: 'stand-in-access', expires_in: 3600 } : { error: 'bad' }));
    }
    if (req.url === '/v1/projects/baari-test/messages:send' && req.headers.authorization === 'Bearer stand-in-access') {
      const { message } = JSON.parse(body);
      sent.push(message);
      if (message.token.startsWith('gone-')) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }));
      }
      if (message.token.startsWith('down-')) return res.writeHead(503).end();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ name: `projects/baari-test/messages/${sent.length}` }));
    }
    res.writeHead(404).end();
  });
});

let served = false;
let secret;
let worker;

async function rpc(c, fn, args = {}) {
  const { data, error } = await c.rpc(fn, args);
  if (error) {
    const e = new Error(`${fn}: ${error.message}`);
    e.code = error.hint ?? error.code;
    throw e;
  }
  return data;
}

async function customer(balanceCents = 10000) {
  const phone = `2526${String(seed).padStart(6, '0')}${String(n++).padStart(2, '0')}`;
  const { rows } = await db.query(`WITH u AS (INSERT INTO users (role, phone, name, password_hash)
      VALUES ('customer', $1, 'Push Test', private.hash_password($2)) RETURNING id)
    INSERT INTO wallets (customer_id, available_cents) SELECT id, $3 FROM u RETURNING customer_id`, [phone, PASSWORD, balanceCents]);
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return { c, id: rows[0].customer_id };
}

const device = (prefix = 'tok') => `${prefix}-${randomUUID()}-${randomUUID()}`;
const runSender = async (s = secret) => {
  const res = await fetch(`${URL}/functions/v1/push-notifications`, {
    method: 'POST', headers: { 'x-worker-secret': s, 'Content-Type': 'application/json' }, body: '{}' });
  return { status: res.status, body: res.status === 200 ? await res.json() : null };
};
const queued = async (orderId) =>
  (await db.query('SELECT kind, status, attempts, devices, last_error FROM push_notifications WHERE order_id = $1', [orderId])).rows;

/** A 888STARZ withdrawal or payment-code deposit, completed by the worker. */
async function completed(cu, direction) {
  const o = direction === 'withdraw'
    ? await rpc(cu.c, 'customer_create_withdrawal', { p_method: '888starz', p_amount: '3', p_account_id: '1847412855',
      p_idempotency_key: randomUUID() })
    : await rpc(cu.c, 'customer_create_deposit', { p_method: '888starz', p_amount: null, p_account_id: '1847412855',
      p_platform_code: `C${randomUUID().slice(0, 8)}`, p_idempotency_key: randomUUID() });
  await rpc(worker, 'platform_claim_next');
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done', p_reference: 'test', p_summa: -4 });
  return o;
}

before(async () => {
  await new Promise((r) => standIn.listen(4996, '0.0.0.0', r));
  const res = await fetch(`${URL}/functions/v1/push-notifications`, { method: 'GET' }).catch(() => null);
  served = Boolean(res) && res.status === 403 && Boolean(SERVICE_KEY);
  if (!served) return;
  secret = (await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`)).rows[0].decrypted_secret;
  worker = client(SERVICE_KEY);
});
beforeEach(async () => {
  if (!served) return;
  // Nothing from other tests waiting for the worker or the sender.
  await db.query(`UPDATE orders SET status = 'failed', low_funds_since = NULL, auto_claimed_at = COALESCE(auto_claimed_at, now())
    WHERE method IN ('888starz', 'onexbet') AND status IN ('pending', 'processing')`);
  await db.query(`UPDATE push_notifications SET status = 'expired' WHERE status IN ('pending', 'sending')`);
  sent.length = 0;
});
after(async () => {
  standIn.close();
  await db.end();
});

const skipUnlessServed = (t) => (served ? false : (t.skip('push-notifications is not served'), true));

test('device tokens: customers register and remove their own; others can not', async () => {
  const a = await customer();
  const b = await customer();
  const token = device();
  await rpc(a.c, 'customer_register_push_token', { p_token: token });
  await rpc(a.c, 'customer_register_push_token', { p_token: token }); // again: still one
  let rows = (await db.query('SELECT customer_id FROM push_tokens WHERE token = $1', [token])).rows;
  assert.deepEqual(rows.map((r) => r.customer_id), [a.id]);
  // The same phone signs in to another account: the token moves.
  await rpc(b.c, 'customer_register_push_token', { p_token: token });
  rows = (await db.query('SELECT customer_id FROM push_tokens WHERE token = $1', [token])).rows;
  assert.deepEqual(rows.map((r) => r.customer_id), [b.id]);
  assert.equal((await rpc(a.c, 'customer_unregister_push_token', { p_token: token })).unregistered, false, 'not theirs any more');
  assert.equal((await rpc(b.c, 'customer_unregister_push_token', { p_token: token })).unregistered, true);
  await assert.rejects(rpc(a.c, 'customer_register_push_token', { p_token: 'short' }), /Invalid push token/);
  const { error } = await a.c.from('push_tokens').select('*');
  const { data } = await a.c.from('push_notifications').select('*');
  assert.ok(error || (data ?? []).length === 0, 'the tables are not readable from the app');
  const agent = client();
  await agent.auth.signInWithPassword({ email: '252610000002@phone.baari.invalid', password: PASSWORD });
  assert.ok((await agent.rpc('customer_register_push_token', { p_token: device() })).error, 'customers only');
});

test('deposit completed: one notification in Somali, data only type and order id', async (t) => {
  if (skipUnlessServed(t)) return;
  const cu = await customer(0);
  const phoneA = device();
  const phoneB = device();
  await rpc(cu.c, 'customer_register_push_token', { p_token: phoneA });
  await rpc(cu.c, 'customer_register_push_token', { p_token: phoneB });
  const o = await completed(cu, 'deposit');
  assert.deepEqual((await queued(o.id)).map((r) => [r.kind, r.status]), [['deposit_completed', 'pending']]);
  const r = await runSender();
  assert.equal(r.status, 200);
  assert.equal(sent.length, 2, 'each device once');
  assert.deepEqual(sent.map((m) => m.token).sort(), [phoneA, phoneB].sort());
  for (const m of sent) {
    assert.deepEqual(m.notification, DEPOSIT);
    assert.deepEqual(m.data, { type: 'deposit_completed', orderId: o.id });
  }
  const text = JSON.stringify(sent);
  for (const secretBit of ['1847412855', '4.00', o.orderCode, '252']) assert.ok(!text.includes(secretBit), `no ${secretBit}`);
  assert.deepEqual((await queued(o.id)).map((x) => [x.status, x.devices]), [['sent', 2]]);
});

test('withdrawal completed: one notification in Somali', async (t) => {
  if (skipUnlessServed(t)) return;
  const cu = await customer();
  await rpc(cu.c, 'customer_register_push_token', { p_token: device() });
  const o = await completed(cu, 'withdraw');
  await runSender();
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].notification, WITHDRAW);
  assert.deepEqual(sent[0].data, { type: 'withdraw_completed', orderId: o.id });
  assert.equal((await queued(o.id))[0].status, 'sent');
});

test('pending, processing, failed and cancelled orders are never notified', async (t) => {
  if (skipUnlessServed(t)) return;
  const cu = await customer();
  await rpc(cu.c, 'customer_register_push_token', { p_token: device() });
  const pending = await rpc(cu.c, 'customer_create_withdrawal', { p_method: '888starz', p_amount: '1',
    p_account_id: '1847412855', p_idempotency_key: randomUUID() });
  await rpc(worker, 'platform_claim_next'); // processing
  assert.deepEqual(await queued(pending.id), []);
  await rpc(worker, 'platform_finish', { p_order_id: pending.id, p_outcome: 'refused', p_message: 'no' }); // failed
  const deposit = await rpc(cu.c, 'customer_create_deposit', { p_method: '888starz', p_amount: null,
    p_account_id: '1847412855', p_platform_code: `P${seed}`, p_idempotency_key: randomUUID() });
  await rpc(worker, 'platform_claim_next');
  await rpc(worker, 'platform_finish', { p_order_id: deposit.id, p_outcome: 'unclear', p_message: 'timeout' }); // still open
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE id = $1`, [deposit.id]);
  assert.deepEqual(await queued(pending.id), []);
  assert.deepEqual(await queued(deposit.id), []);
  await runSender();
  assert.equal(sent.length, 0);
});

test('one notification per completed order, however often it is touched or the sender runs', async (t) => {
  if (skipUnlessServed(t)) return;
  const cu = await customer();
  await rpc(cu.c, 'customer_register_push_token', { p_token: device() });
  const o = await completed(cu, 'withdraw');
  await db.query(`UPDATE orders SET status = 'completed', updated_at = now() WHERE id = $1`, [o.id]);
  await rpc(worker, 'platform_finish', { p_order_id: o.id, p_outcome: 'done' }); // late duplicate report
  assert.equal((await queued(o.id)).length, 1);
  await Promise.all([runSender(), runSender(), runSender()]);
  await runSender();
  assert.equal(sent.length, 1);
  await assert.rejects(db.query(`INSERT INTO push_notifications (customer_id, order_id, kind)
    SELECT customer_id, id, 'withdraw_completed' FROM orders WHERE id = $1`, [o.id]), /duplicate key/);
});

test('no device: nothing sent; an uninstalled app\'s token is removed; FCM down: tried again', async (t) => {
  if (skipUnlessServed(t)) return;
  const none = await customer();
  const a = await completed(none, 'withdraw');
  await runSender();
  assert.equal((await queued(a.id))[0].status, 'no_device');

  const cu = await customer();
  const gone = device('gone');
  const good = device();
  await rpc(cu.c, 'customer_register_push_token', { p_token: gone });
  await rpc(cu.c, 'customer_register_push_token', { p_token: good });
  const b = await completed(cu, 'deposit');
  await runSender();
  assert.equal((await queued(b.id))[0].status, 'sent');
  assert.equal((await db.query('SELECT count(*)::int AS n FROM push_tokens WHERE token = $1', [gone])).rows[0].n, 0);

  const down = await customer();
  await rpc(down.c, 'customer_register_push_token', { p_token: device('down') });
  const c = await completed(down, 'withdraw');
  await runSender();
  assert.deepEqual((await queued(c.id)).map((x) => [x.status, x.attempts]), [['pending', 1]]);
  await runSender();
  assert.deepEqual((await queued(c.id)).map((x) => [x.status, x.attempts]), [['pending', 2]]);
});

test('older than a day: dropped, not sent late; the sender needs the worker secret', async (t) => {
  if (skipUnlessServed(t)) return;
  const cu = await customer();
  await rpc(cu.c, 'customer_register_push_token', { p_token: device() });
  const o = await completed(cu, 'withdraw');
  await db.query(`UPDATE push_notifications SET created_at = now() - interval '25 hours' WHERE order_id = $1`, [o.id]);
  assert.equal((await runSender('wrong-secret')).status, 403);
  await runSender();
  assert.equal(sent.length, 0);
  assert.equal((await queued(o.id))[0].status, 'expired');
});
