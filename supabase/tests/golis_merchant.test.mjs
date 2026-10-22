// Sahal merchant feed, read-only stage (functions/golis-merchant,
// migrations/*_merchant_feed.sql), against a stand-in merchant portal.
//
//   Needs the local stack and the functions served with tests/.functions.env.

import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL });

// The stand-in portal: what it answers, and every request it got.
const portal = { login: 'ok', sessions: new Set(), next: 1, rows: [] };
const seen = [];
const standIn = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const b = body ? JSON.parse(body) : {};
    seen.push({ path: req.url, body: b });
    const cookie = (req.headers.cookie ?? '').match(/connect\.sid=([^;]+)/)?.[1];
    const reply = (o, headers = {}) => { res.writeHead(200, { 'Content-Type': 'application/json', ...headers }); res.end(JSON.stringify(o)); };
    if (req.url === '/api/account/currencies') {
      return reply({ resultCode: 2001, currencies: [{ CURRENCYCODE: '706', CURRENCYNAME: 'SOS' }, { CURRENCYCODE: '840', CURRENCYNAME: 'USD' }] });
    }
    if (req.url === '/api/account/login' && portal.slow) {
      // A slow Sahal: the sign-in is still running when the next run starts.
      return setTimeout(() => answerLogin(), 1500);
    }
    if (req.url === '/api/account/login') return answerLogin();
    function answerLogin() {
      if (portal.login === 'otp') return reply({ resultCode: 6083, replyMessage: 'Enter the code sent to your phone' });
      if (portal.login === 'wrong') return reply({ resultCode: 4001, replyMessage: 'Invalid username or password' });
      if (portal.login === 'sms') {
        portal.pending = `P${portal.next++}`;
        // Like an Express portal: the session cookie is set at sign-in.
        return reply({ resultCode: 1001, sessionId: portal.pending, replyMessage: 'Access code sent' },
          { 'Set-Cookie': `connect.sid=${portal.pending}-cookie; Path=/; HttpOnly` });
      }
      const s = `S${portal.next++}`;
      portal.sessions.add(s);
      return reply({ resultCode: 2001, sessionId: s, name: 'BULSHO AGENT' });
    }
    if (req.url === '/api/account/2auth') {
      if (b.sessionId !== portal.pending || b.code !== '654321') return reply({ resultCode: 4002, replyMessage: 'Invalid access code' });
      if (cookie !== `${portal.pending}-cookie`) return reply({ resultCode: 4005, replyMessage: 'Session expired' });
      const s = `S${portal.next++}`;
      portal.sessions.add(s);
      portal.cookieFor[s] = cookie;
      return reply({ resultCode: 2001, sessionId: s, transactionInfo: portal.firstRows });
    }
    if (req.url === '/api/account/transactions') {
      if (!portal.sessions.has(b.sessionId)) return reply({ resultCode: 4005, replyMessage: 'Session expired' });
      if (portal.cookieFor[b.sessionId] && portal.cookieFor[b.sessionId] !== cookie) {
        return reply({ resultCode: 7777, replyMessage: 'Your Session has expired. Please login again.' });
      }
      if (portal.refuseList) return reply({ resultCode: 4005, replyMessage: 'Your Session has expired. Please login again.' });
      return reply({ resultCode: 2001, transactionInfo: portal.rows });
    }
    res.writeHead(404).end();
  });
});

let secret;
let served = false;
const run = async (key = secret) => {
  const res = await fetch(`${URL}/functions/v1/golis-merchant`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-worker-secret': key }, body: '{}',
  });
  return { status: res.status, body: await res.text() };
};
const status = async () => (await db.query(`SELECT * FROM merchant_feed_status WHERE provider = 'golis'`)).rows[0];
const stored = async () => (await db.query(`SELECT transaction_id, raw FROM merchant_transactions WHERE provider = 'golis' ORDER BY transaction_id`)).rows;
const calls = (path) => seen.filter((s) => s.path === path).length;

before(async () => {
  await new Promise((r) => standIn.listen(4995, '0.0.0.0', r));
  secret = (await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`)).rows[0]?.decrypted_secret;
  const probe = await fetch(`${URL}/functions/v1/golis-merchant`, { method: 'GET' }).catch(() => null);
  served = Boolean(secret) && probe?.status === 403;
});
beforeEach(async () => {
  await db.query(`UPDATE merchant_feed_status SET state = 'ready', result_code = NULL, message = NULL, rows_seen = 0 WHERE provider = 'golis'`);
  await db.query(`DELETE FROM private.merchant_feed_sessions WHERE provider = 'golis'`);
  await db.query(`DELETE FROM merchant_transactions WHERE provider = 'golis'`);
  Object.assign(portal, { login: 'ok', sessions: new Set(), rows: [], pending: null, slow: false, cookieFor: {}, firstRows: [], refuseList: false });
  seen.length = 0;
});
after(async () => {
  standIn.close();
  await db.query(`UPDATE merchant_feed_status SET state = 'ready' WHERE provider = 'golis'`);
  await db.end();
});

const row = (id, credit, phone) => ({
  TRANSACTIONID: id, SENDER: '252900000004', RECEIVER: phone, TRANSACTIONDATE: '22/10/26 12:00:00',
  DESCRIPTION: `${phone} paid $${credit} to merchant: BULSHO AGENT (090353102),`, CREDIT: credit, DEBIT: '-',
});

test('only the database can wake it', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  assert.equal((await run('wrong')).status, 403);
  assert.equal(seen.length, 0, 'the portal was not contacted');
});

test('signs in like the portal page, reads the transactions, stores each once, credits nothing', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  portal.rows = [row('7011781188', '1.00', '252610346060'), row('7011781189', '2.50', '252907000001')];
  const r = await run();
  assert.equal(r.status, 200, r.body);
  const login = seen.find((s) => s.path === '/api/account/login').body;
  assert.deepEqual(login, { userNature: 'MERCHANT', type: 'MERCHANT', username: '252900000099', password: 'test-password', currency: '840' });
  assert.deepEqual((await stored()).map((x) => [x.transaction_id, x.raw.CREDIT]), [['7011781188', '1.00'], ['7011781189', '2.50']]);
  const s = await status();
  assert.equal(s.state, 'ok');
  assert.equal(s.rows_seen, 2);
  assert.match(s.message, /2 rows; reply keys: resultCode,transactionInfo/);
  assert.ok(!JSON.stringify(s).includes('test-password'), 'no password in the status');

  // Next minute: the saved session is reused, nothing stored twice, a new row added.
  portal.rows.push(row('7011781190', '5.00', '252610346060'));
  await run();
  assert.equal(calls('/api/account/login'), 1, 'signed in once');
  assert.equal((await stored()).length, 3);
  assert.equal((await status()).rows_seen, 3);

  // Nothing touched any order or wallet: this stage only reads.
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE created_at > now() - interval '1 minute' AND action LIKE 'order.%' AND after_json::text LIKE '%7011781%'`);
  assert.equal(rows[0].n, 0);
});

test('an ended session signs in again', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await run();
  portal.sessions.clear(); // the portal forgot it
  await run();
  assert.equal(calls('/api/account/login'), 2);
  assert.equal((await status()).state, 'ok');
});

for (const [kind, code, message] of [['otp', '6083', /SMS code/], ['wrong', '4001', /Invalid username or password/]]) {
  test(`a sign-in that needs a person (${kind}) stops the feed until a manager retries`, async (t) => {
    if (!served) return t.skip('golis-merchant is not served');
    portal.login = kind;
    await run();
    let s = await status();
    assert.deepEqual([s.state, s.result_code], ['stopped', code]);
    assert.match(s.message, message);

    // Woken again: the portal is not asked again (no code flood, no lock-out).
    const before = seen.length;
    await run();
    assert.equal(seen.length, before);

    const manager = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
    await manager.auth.signInWithPassword({ email: '252610000002@phone.baari.invalid', password: 'ChangeMe123!' });
    const { error } = await manager.rpc('manage_merchant_feed_retry', { p_provider: 'golis' });
    assert.equal(error, null);
    portal.login = 'ok';
    await run();
    s = await status();
    assert.equal(s.state, 'ok');
  });
}

test('waiting for its secrets, it is still woken every minute (and contacts nothing)', async () => {
  await db.query(`UPDATE merchant_feed_status SET state = 'not_configured' WHERE provider = 'golis'`);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM merchant_feed_status
    WHERE provider = 'golis' AND state IN ('ready', 'ok', 'not_configured')`);
  assert.equal(rows[0].n, 1);
  const src = (await db.query(`SELECT prosrc FROM pg_proc WHERE proname = 'merchant_feed_kick'`)).rows[0].prosrc;
  assert.match(src, /'not_configured'/);
});

async function managerClient() {
  const m = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  await m.auth.signInWithPassword({ email: '252610000002@phone.baari.invalid', password: 'ChangeMe123!' });
  return m;
}

test('SMS access code: waits for it, a manager types it, the session is used from then on', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  portal.login = 'sms';
  portal.rows = [row('7505691073', '5.00', '252610338686')];
  await run();
  let s = await status();
  assert.deepEqual([s.state, s.result_code], ['needs_code', '1001']);
  assert.match(s.message, /access code/);
  assert.equal(calls('/api/account/login'), 1);

  // Woken while waiting: Sahal is not asked again (no second SMS).
  await run();
  assert.equal(calls('/api/account/login'), 1);

  const m = await managerClient();
  const shown = (await m.rpc('manage_merchant_feed_status', { p_provider: 'golis' })).data;
  assert.equal(shown.state, 'needs_code');
  assert.ok(shown.codeAskedAt);
  assert.ok(!JSON.stringify(shown).includes(portal.pending), 'the pending session is not shown');

  const { error } = await m.rpc('manage_merchant_feed_code', { p_provider: 'golis', p_code: ' 654 321 ' });
  assert.equal(error, null);
  assert.equal((await status()).state, 'code_entered');
  await run();
  const auth = seen.find((x) => x.path === '/api/account/2auth').body;
  assert.deepEqual(auth, { userNature: 'MERCHANT', type: 'MERCHANT', code: '654321', sessionId: portal.pending });
  s = await status();
  assert.equal(s.state, 'ok');
  assert.deepEqual((await stored()).map((x) => x.transaction_id), ['7505691073']);
  const { rows } = await db.query(`SELECT code FROM private.merchant_feed_sessions WHERE provider = 'golis'`);
  assert.equal(rows[0].code, null, 'the code is used once and not kept');

  // Next minute: same session, no new login.
  await run();
  assert.equal(calls('/api/account/login'), 1);
});

test('a wrong code stops it; a late code is refused; a code only when Sahal asked for one', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  const m = await managerClient();
  const code = (c) => m.rpc('manage_merchant_feed_code', { p_provider: 'golis', p_code: c });

  assert.match((await code('123456')).error.message, /not waiting for a code/);
  portal.login = 'sms';
  await run();
  assert.match((await code('12ab')).error.message, /numbers only/);

  assert.equal((await code('111111')).error, null);
  await run();
  let s = await status();
  assert.equal(s.state, 'stopped');
  assert.match(s.message, /did not accept the code: Invalid access code/);

  // Sign in again: a new code is asked for; entered too late, it is refused.
  assert.equal((await m.rpc('manage_merchant_feed_sign_in', { p_provider: 'golis' })).error, null);
  await run();
  assert.equal((await status()).state, 'needs_code');
  await db.query(`UPDATE private.merchant_feed_sessions SET second_at = now() - interval '11 minutes' WHERE provider = 'golis'`);
  assert.match((await code('654321')).error.message, /expired/);
  const shown = (await m.rpc('manage_merchant_feed_status', { p_provider: 'golis' })).data;
  assert.deepEqual([shown.state, shown.message], ['stopped', 'The access code expired. Sign in again.']);

  const plain = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  assert.ok((await plain.rpc('manage_merchant_feed_status', { p_provider: 'golis' })).error, 'not for anyone signed out');
});

test('woken twice at once: Sahal is signed in to once (one SMS), the code is sent once', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  portal.login = 'sms';
  portal.slow = true;
  await Promise.all([run(), run(), run()]);
  assert.equal(calls('/api/account/login'), 1, 'one sign-in, so one SMS');
  assert.equal((await status()).state, 'needs_code');

  const m = await managerClient();
  assert.equal((await m.rpc('manage_merchant_feed_code', { p_provider: 'golis', p_code: '654321' })).error, null);
  await Promise.all([run(), run(), run()]);
  assert.equal(calls('/api/account/2auth'), 1, 'the code is used by one run only');
  assert.equal((await status()).state, 'ok');
});

test('after the code: the portal cookie is sent back, and the list that came with the code is kept', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  portal.login = 'sms';
  portal.firstRows = [{ tranId: '7505720310', sender: '252900000004', receiver: '252638882065', credit: '1.00', debit: '-' }];
  portal.rows = [row('7505691073', '5.00', '252610338686')];
  await run();
  const m = await managerClient();
  await m.rpc('manage_merchant_feed_code', { p_provider: 'golis', p_code: '654321' });
  await run();
  const s = await status();
  assert.equal(s.state, 'ok', s.message);
  assert.deepEqual((await stored()).map((x) => x.transaction_id), ['7505691073', '7505720310']);
  // A later minute: still the same cookie, still signed in.
  await run();
  assert.equal((await status()).state, 'ok');
  assert.equal(calls('/api/account/login'), 1);
});

test('signed in with the code but the list is refused: stops with exactly what Sahal said, no new sign-in', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  portal.login = 'sms';
  portal.refuseList = true;
  await run();
  const m = await managerClient();
  await m.rpc('manage_merchant_feed_code', { p_provider: 'golis', p_code: '654321' });
  await run();
  const s = await status();
  assert.equal(s.state, 'stopped');
  assert.match(s.message, /Signed in, but Sahal refused the transaction list \(4005: Your Session has expired/);
  assert.equal(calls('/api/account/login'), 1, 'no second SMS');
});

// ---- Stage 2: crediting deposits from merchant payments ----

const seed2 = Number(Date.now().toString().slice(-6));
let n2 = 0;
const evcLocal = () => `61${String(seed2 * 10 + n2++).padStart(7, '0').slice(-7)}`;
async function customer(local) {
  const phone = `252${local}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Merchant Credit Test', private.hash_password('ChangeMe123!')) RETURNING id)
     INSERT INTO public.wallets (customer_id) SELECT id FROM u`, [phone]);
  const c = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: 'ChangeMe123!' });
  if (error) throw error;
  return c;
}
async function depositOf(c, local, amount) {
  const { data, error } = await c.rpc('customer_create_deposit', {
    p_method: 'evc_plus', p_amount: String(amount), p_phone_number: `252${local}`, p_idempotency_key: crypto.randomUUID() });
  if (error) throw error;
  return data;
}
const order = async (id) => (await db.query('SELECT status, transaction_ref FROM orders WHERE id = $1', [id])).rows[0];
const walletOf = async (c) => (await c.rpc('customer_wallet')).data.availableBalance;
// The portal's time is Somalia time: "DD/MM/YY HH:MM:SS".
function sahalTime(msAgo = 0) {
  const d = new Date(Date.now() - msAgo + 3 * 3600_000);
  const p = (x) => String(x).padStart(2, '0');
  return `${p(d.getUTCDate())}/${p(d.getUTCMonth() + 1)}/${String(d.getUTCFullYear()).slice(2)} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`;
}
let tranSeq = Number(Date.now().toString().slice(-7)) * 10;
const payment = (payer, amount, msAgo = 0) => ({
  tranID: tranSeq++, sender: '252900000004', receiver: payer, tranDate: sahalTime(msAgo),
  description: `${payer} paid $${amount} to merchant: BULSHO AGENT (090353102),`, credit: Number(amount).toFixed(2), debit: '-',
});

test('a merchant payment from the customer\'s number, same amount, credits that deposit once', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'merchant_feed_credit:golis'`);
  const local = evcLocal();
  const c = await customer(local);
  const d = await depositOf(c, local, 1);
  portal.rows = [
    payment(`252${local}`, 1),
    { tranID: tranSeq++, sender: '252905999914', receiver: '0610346060', tranDate: sahalTime(), description: 'Yasin', credit: '-', debit: '1.00' },
  ];
  await run();
  const o = await order(d.id);
  assert.equal(o.status, 'completed');
  assert.match(o.transaction_ref, /^Sahal merchant \d+$/);
  assert.equal(await walletOf(c), '1.00');
  const kinds = (await db.query(`SELECT direction, match_status FROM merchant_transactions WHERE provider = 'golis' ORDER BY direction`)).rows
    .map((r) => `${r.direction} ${r.match_status}`);
  assert.deepEqual(kinds, ['in matched', 'out unmatched'], 'the outgoing transfer pays no withdrawal of this customer');

  // Seen again next minute: nothing credited twice.
  await run();
  assert.equal(await walletOf(c), '1.00');

  // A second payment with no waiting deposit: not credited, kept for an agent.
  portal.rows.push(payment(`252${local}`, 1));
  await run();
  assert.equal(await walletOf(c), '1.00');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM merchant_transactions WHERE provider = 'golis' AND direction = 'in' AND match_status = 'unmatched'`);
  assert.equal(rows[0].n, 1);
});

test('another number or another amount credits nothing', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'merchant_feed_credit:golis'`);
  const local = evcLocal();
  const c = await customer(local);
  const d = await depositOf(c, local, 5);
  portal.rows = [payment(`252${evcLocal()}`, 5), payment(`252${local}`, 4)];
  await run();
  assert.equal((await order(d.id)).status, 'pending');
  assert.equal(await walletOf(c), '0.00');
});

test('crediting switched off: payments are only stored; switched on, the waiting deposit is credited', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await db.query(`UPDATE app_settings SET value = 'off' WHERE key = 'merchant_feed_credit:golis'`);
  const local = evcLocal();
  const c = await customer(local);
  const d = await depositOf(c, local, 2);
  portal.rows = [payment(`252${local}`, 2)];
  await run();
  assert.equal((await order(d.id)).status, 'pending');

  const m = await managerClient();
  const { data, error } = await m.rpc('manage_merchant_feed_credit', { p_provider: 'golis', p_on: true });
  assert.equal(error, null);
  assert.equal(data.creditOn, true);
  await run();
  assert.equal((await order(d.id)).status, 'completed');
  assert.equal(await walletOf(c), '2.00');
});

test('paid after the deposit expired unpaid: reopened and credited', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'merchant_feed_credit:golis'`);
  const local = evcLocal();
  const c = await customer(local);
  const d = await depositOf(c, local, 3);
  await db.query(`UPDATE orders SET created_at = now() - interval '40 minutes' WHERE id = $1`, [d.id]);
  await db.query('SELECT private.expire_unpaid_deposits()');
  assert.equal((await order(d.id)).status, 'expired');
  portal.rows = [payment(`252${local}`, 3)];
  await run();
  assert.equal((await order(d.id)).status, 'completed');
  assert.equal(await walletOf(c), '3.00');
});

// ---- Withdrawals sent by hand from Sahal complete themselves ----

async function withdrawalOf(c, local, amount) {
  const { data, error } = await c.rpc('customer_create_withdrawal', {
    p_method: 'evc_plus', p_amount: String(amount), p_phone_number: `252${local}`, p_idempotency_key: crypto.randomUUID() });
  if (error) throw error;
  return data;
}
const sent = (receiver, amount, msAgo = 0) => ({
  tranID: tranSeq++, sender: '252905999914', receiver, tranDate: sahalTime(msAgo), description: 'Done', credit: '-',
  debit: Number(amount).toFixed(2),
});
async function richCustomer(local) {
  const c = await customer(local);
  await db.query(`UPDATE wallets SET available_cents = 1000 WHERE customer_id = (SELECT id FROM users WHERE phone = $1)`, [`252${local}`]);
  return c;
}

test('a Sahal transfer to the customer\'s number for the amount completes that withdrawal, once', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'merchant_feed_payouts:golis'`);
  const local = evcLocal();
  const c = await richCustomer(local);
  const w = await withdrawalOf(c, local, 2);
  assert.equal(await walletOf(c), '8.00', 'reserved');
  portal.rows = [sent(local, 2)]; // Sahal shows the 9-digit number, as typed in the portal
  await run();
  const o = await order(w.id);
  assert.equal(o.status, 'completed');
  assert.match(o.transaction_ref, /^Sahal \d+$/);
  assert.equal(await walletOf(c), '8.00');

  // A second identical transfer completes nothing more.
  portal.rows.push(sent(`0${local}`, 2));
  await run();
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM merchant_transactions WHERE provider = 'golis' AND direction = 'out' AND match_status = 'unmatched'`);
  assert.equal(rows[0].n, 1);
});

test('another amount, a transfer older than the withdrawal, or the switch off: nothing is completed', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'merchant_feed_payouts:golis'`);
  const local = evcLocal();
  const c = await richCustomer(local);
  const w = await withdrawalOf(c, local, 3);
  portal.rows = [sent(local, 2), sent(local, 3, 60 * 60_000)]; // wrong amount; sent an hour before the withdrawal
  await run();
  assert.equal((await order(w.id)).status, 'pending');

  const m = await managerClient();
  const { data, error } = await m.rpc('manage_merchant_feed_payouts', { p_provider: 'golis', p_on: false });
  assert.equal(error, null);
  assert.equal(data.payoutsOn, false);
  portal.rows.push(sent(local, 3));
  await run();
  assert.equal((await order(w.id)).status, 'pending', 'switched off');
  await m.rpc('manage_merchant_feed_payouts', { p_provider: 'golis', p_on: true });
  await run();
  assert.equal((await order(w.id)).status, 'completed');
  assert.equal((await m.rpc('manage_merchant_feed_status', { p_provider: 'golis' })).data.payoutsCompletedToday, 1);
});
