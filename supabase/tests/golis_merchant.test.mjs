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
      portal.canSend.add(s);
      return reply({ resultCode: 2001, sessionId: s, name: 'BULSHO AGENT' });
    }
    if (req.url === '/api/account/2auth') {
      if (b.sessionId !== portal.pending || b.code !== '654321') return reply({ resultCode: 4002, replyMessage: 'Invalid access code' });
      if (cookie !== `${portal.pending}-cookie`) return reply({ resultCode: 4005, replyMessage: 'Session expired' });
      const s = `S${portal.next++}`;
      portal.sessions.add(s);
      portal.canSend.add(s);
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
    // Sending money (Sahal payouts): only when a test switches it on.
    if ((portal.payouts || portal.balance) && req.url === '/api/account/balance') {
      if (!portal.sessions.has(b.sessionId)) return reply({ resultCode: 4005, replyMessage: 'Session expired' });
      return reply({ resultCode: 2001, currentBalance: portal.balance ?? '1,000.00' });
    }
    if (portal.payouts && (req.url === '/api/account/find' || req.url === '/api/money/b2p')) {
      // Sahal's ER0654: the list still reads, transfers are refused.
      // Seen on production with both texts; only the code tells.
      if (!portal.canSend.has(b.sessionId)) {
        return reply({ resultCode: 'ER0654', replyMessage: portal.er0654 ?? 'Session data is not found, please sign in again!' });
      }
      if (req.url === '/api/account/find') {
        if (portal.findDown) return req.socket.destroy();
        return reply({ resultCode: 2001, ReceiverInfo: { NAME: 'TEST RECEIVER', ISINTERNETWORKRECEIVER: true } });
      }
      portal.transfers.push({ mobile: b.receiverMobile, amount: b.amount, description: b.description });
      if (portal.unclear) return reply({ resultCode: 2001, replyMessage: 'Processing' });
      return reply({ resultCode: 2001, replyMessage: 'Done', transferInfo: { 'Transfer-Id': `TR${portal.next++}` } });
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
  await db.query(`DELETE FROM private.merchant_feed_events WHERE provider = 'golis'`);
  await db.query('DELETE FROM sahal_balances');
  await db.query(`DELETE FROM vault.secrets WHERE name LIKE 'sahal_account_%'`);
  await db.query(`DELETE FROM private.sahal_accounts`);
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'sahal_renew_idle'`);
  Object.assign(portal, { login: 'ok', sessions: new Set(), rows: [], pending: null, slow: false, cookieFor: {}, firstRows: [], refuseList: false,
    payouts: false, canSend: new Set(), transfers: [], findDown: false, unclear: false, er0654: null, balance: null });
  seen.length = 0;
});
after(async () => {
  standIn.close();
  await db.query(`UPDATE merchant_feed_status SET state = 'ready' WHERE provider = 'golis'`);
  await db.query('DELETE FROM sahal_balances');
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

test('read every 10 seconds, so reads can overlap: several runs at once credit a deposit once', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'merchant_feed_credit:golis'`);
  const local = evcLocal();
  const c = await customer(local);
  const d = await depositOf(c, local, 3);
  portal.rows = [payment(`252${local}`, 3)];
  await Promise.all([run(), run(), run(), run()]);
  await run();
  assert.equal((await order(d.id)).status, 'completed');
  assert.equal(await walletOf(c), '3.00', 'credited once, not once per run');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM ledger_entries WHERE order_id = $1 AND entry_type = 'credit'`, [d.id]);
  assert.equal(rows[0].n, 1);
  const feed = await db.query(`SELECT count(*)::int AS n FROM merchant_transactions WHERE provider = 'golis' AND matched_order_id = $1`, [d.id]);
  assert.equal(feed.rows[0].n, 1, 'one transfer pays one deposit');
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

// ---- Sahal payouts: a lost session, retries, never twice ----
// (migrations/*_withdrawal_speed.sql)

/** Sahal sends EVC Plus here; every other waiting withdrawal is out of the way. */
async function sahalOn() {
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE direction = 'withdraw' AND status = 'pending'
                    AND method IN ('golis', 'telesom', 'evc_plus')`);
  await db.query(`UPDATE sahal_payout_settings SET mode = 'test', test_started_at = now(), test_amount_cents = 100000,
                    daily_limit_cents = 10000000 WHERE id`);
  portal.payouts = true;
}
const sahalOff = () => db.query(`UPDATE sahal_payout_settings SET mode = 'off' WHERE id`);
const delayOf = async (c, id) => (await c.rpc('customer_order', { p_id: id })).data.delay;

test('Sahal ends the session for transfers: signed in again at once, the withdrawal goes out in the same run, once', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run(); // signed in, reading
    assert.equal(calls('/api/account/login'), 1);
    portal.canSend.clear(); // Sahal: "Session data is not found" for transfers; the list still reads
    portal.er0654 = 'Fadlan isku day markale'; // the words Sahal used on 2026-10-28 17:30
    const local = evcLocal();
    const c = await richCustomer(local);
    const w = await withdrawalOf(c, local, 2);
    await run();
    assert.equal(calls('/api/account/login'), 2, 'signed in again by itself');
    const o = await order(w.id);
    assert.equal(o.status, 'completed');
    assert.match(o.transaction_ref, /^Sahal TR\d+$/);
    assert.deepEqual(portal.transfers.map((x) => [x.mobile, x.amount, x.description]), [[`0${local}`, '2', w.orderCode]]);
    assert.equal(await walletOf(c), '8.00', 'taken once, not refunded');
    const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE entity_id = $1 AND action = 'withdrawal_sahal_retry'`, [w.id]);
    assert.equal(rows[0].n, 1);
    // Later runs send nothing more.
    await run();
    await run();
    assert.equal(portal.transfers.length, 1);
  } finally {
    await sahalOff();
  }
});

test('Sahal wants its SMS code: deposits keep reading, the customer is told why, it goes out once the code is typed', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run();
    portal.canSend.clear();
    portal.login = 'sms';
    const local = evcLocal();
    const c = await richCustomer(local);
    const w = await withdrawalOf(c, local, 3);
    await run();
    assert.equal((await status()).state, 'needs_code');
    assert.equal((await order(w.id)).status, 'pending');
    assert.equal(portal.transfers.length, 0, 'nothing sent');

    // Waiting for the code: the old session still reads Sahal's list, no new SMS.
    portal.rows = [row('7600000001', '4.00', '252610000999')];
    await run();
    assert.ok((await stored()).some((x) => x.transaction_id === '7600000001'), 'read while waiting');
    assert.equal((await status()).state, 'needs_code');
    assert.equal(calls('/api/account/login'), 2);

    // After 30 seconds the customer sees why.
    await db.query(`UPDATE orders SET created_at = now() - interval '40 seconds' WHERE id = $1`, [w.id]);
    assert.equal(await delayOf(c, w.id), 'provider_unavailable');

    const m = await managerClient();
    assert.equal((await m.rpc('manage_merchant_feed_code', { p_provider: 'golis', p_code: '654321' })).error, null);
    await run();
    assert.equal((await status()).state, 'ok');
    assert.equal((await order(w.id)).status, 'completed', 'sent right after the code');
    assert.equal(portal.transfers.length, 1);
    assert.equal(await delayOf(c, w.id), null);
  } finally {
    await sahalOff();
  }
});

test('Sahal not reached: nothing sent, tried again after a minute, sent once', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run();
    portal.findDown = true;
    const local = evcLocal();
    const c = await richCustomer(local);
    const w = await withdrawalOf(c, local, 1);
    await run();
    const { rows: [a] } = await db.query(`SELECT status, result_code FROM sahal_payout_attempts WHERE order_id = $1`, [w.id]);
    assert.deepEqual([a.status, a.result_code], ['failed', 'NETWORK']);
    assert.equal((await order(w.id)).status, 'pending', 'not refunded: it will be sent');
    assert.equal(await walletOf(c), '9.00');

    portal.findDown = false;
    await run();
    assert.equal((await order(w.id)).status, 'pending', 'not before a minute');
    await db.query(`UPDATE sahal_payout_attempts SET completed_at = now() - interval '61 seconds' WHERE order_id = $1`, [w.id]);
    await run();
    assert.equal((await order(w.id)).status, 'completed');
    assert.equal(portal.transfers.length, 1);
  } finally {
    await sahalOff();
  }
});

test('an unclear answer to a transfer: held, never sent again, never refunded', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run();
    portal.unclear = true;
    const local = evcLocal();
    const c = await richCustomer(local);
    const w = await withdrawalOf(c, local, 2);
    await run();
    await run();
    await db.query(`UPDATE sahal_payout_attempts SET completed_at = now() - interval '10 minutes' WHERE order_id = $1`, [w.id]);
    await run();
    assert.equal(portal.transfers.length, 1, 'sent once only');
    assert.equal((await order(w.id)).status, 'processing');
    assert.equal(await walletOf(c), '8.00');
    await db.query(`UPDATE orders SET created_at = now() - interval '40 seconds' WHERE id = $1`, [w.id]);
    assert.equal(await delayOf(c, w.id), 'confirming');
  } finally {
    await sahalOff();
  }
});

test('nothing to send: the session is checked anyway, and a lost one is renewed before a customer waits', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run();
    assert.equal(calls('/api/account/login'), 1);
    portal.canSend.clear();
    await run();
    assert.equal(calls('/api/account/login'), 2);
    const probe = seen.filter((x) => x.path === '/api/account/find').map((x) => x.body.mobileNo);
    assert.ok(probe.every((x) => x === '900000099'), 'only the merchant\'s own number is looked up');
    assert.equal(portal.transfers.length, 0);
  } finally {
    await sahalOff();
  }
});

// ---- The session's own log, and renewing only when needed ----
// (migrations/*_sahal_session_log.sql)

const events = async () => (await db.query(`SELECT event, detail FROM private.merchant_feed_events WHERE provider = 'golis' ORDER BY id`)).rows;

test('session log: start, loss (by what), renewal and sign-in results, never a code or password', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run();
    await run(); // reading again with the same session is not a new session
    let e = await events();
    assert.equal(e.filter((x) => x.event === 'session_started').length, 1);
    assert.deepEqual(e.filter((x) => x.event === 'sign_in').map((x) => x.detail.result), ['2001']);

    portal.canSend.clear(); // Sahal ends the session for transfers
    await run();
    e = await events();
    const lost = e.find((x) => x.event === 'session_lost');
    assert.equal(lost.detail.by, 'probe');
    assert.equal(lost.detail.code, 'ER0654');
    assert.ok(lost.detail.sessionAgeSeconds >= 0, 'its age is recorded');
    assert.equal(e.filter((x) => x.event === 'session_started').length, 2, 'the renewal is a second session');
    assert.ok(e.some((x) => x.event === 'sign_in' && x.detail.for === 'transfers'));
    const text = JSON.stringify(e);
    assert.ok(!text.includes('654321') && !text.includes('test-password'), 'no code, no password in the log');
  } finally {
    await sahalOff();
  }
});

test('session log: the code sent and the session that waits for it', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await waitForCode();
  const a = await managerClient();
  assert.equal((await smsCode(a, SAHAL_SMS)).error, null);
  await run();
  const e = await events();
  assert.deepEqual(e.filter((x) => x.event === 'sign_in').map((x) => x.detail.result), ['1001']);
  assert.deepEqual(e.filter((x) => x.event === 'code_sent').map((x) => x.detail.result), ['2001']);
  assert.ok(!JSON.stringify(e).includes('654321'));
});

test("'sahal_renew_idle' off: an idle session that Sahal ended is not renewed until a withdrawal needs it (once, nothing twice)", async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run();
    assert.equal(calls('/api/account/login'), 1);
    await setSetting('sahal_renew_idle', 'off');
    const lookUps = calls('/api/account/find'); // the first run, with the check on, looked once
    portal.canSend.clear();
    await run();
    await run();
    assert.equal(calls('/api/account/login'), 1, 'idle: no new sign-in, no new SMS code');
    assert.equal(calls('/api/account/find'), lookUps, 'and no idle look-up');
    // A withdrawal arrives: now it signs in again and sends it, once.
    const local = evcLocal();
    const c = await richCustomer(local);
    const w = await withdrawalOf(c, local, 2);
    await run();
    assert.equal(calls('/api/account/login'), 2);
    const o = await order(w.id);
    assert.equal(o.status, 'completed');
    assert.equal(portal.transfers.length, 1);
    assert.equal(await walletOf(c), '8.00', 'taken once');
    await run();
    assert.equal(portal.transfers.length, 1);
    const lost = (await events()).find((x) => x.event === 'session_lost');
    assert.ok(['lookup', 'transfer'].includes(lost.detail.by));
  } finally {
    await setSetting('sahal_renew_idle', 'on');
    await sahalOff();
  }
});

test('only a manager sets the idle renewal; it is audited', async () => {
  const a = await managerClient();
  const set = await a.rpc('manage_sahal_session_options', { p_renew_idle: false });
  assert.equal(set.error, null);
  assert.deepEqual(set.data, { renewIdle: false });
  assert.deepEqual((await a.rpc('manage_sahal_session_options', {})).data, { renewIdle: false }, 'reading changes nothing');
  assert.deepEqual((await a.rpc('manage_sahal_session_options', { p_renew_idle: true })).data, { renewIdle: true });
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'sahal_session.options' AND created_at > now() - interval '1 minute'`);
  assert.ok(rows[0].n >= 2);
  const c = await customer(evcLocal());
  assert.notEqual((await c.rpc('manage_sahal_session_options', { p_renew_idle: false })).error, null);
});

// ---- The Sahal account, managed from the Admin Dashboard ----
// (migrations/*_sahal_accounts.sql, functions/sahal-account-verify)

const verifyNow = async () => {
  const res = await fetch(`${URL}/functions/v1/sahal-account-verify`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-worker-secret': secret }, body: '{}',
  });
  return { status: res.status, body: await res.text() };
};
const accountStatus = async (m) => (await m.rpc('manage_sahal_account_status')).data;
const feedSession = async () => (await db.query(`SELECT session_id, cookies FROM private.merchant_feed_sessions WHERE provider = 'golis'`)).rows[0];
const NEW_LOGIN = { p_username: '252900000055', p_password: 'new-pass-Zq81', p_pin: '5555', p_currency: null };

test('a new account: saved, tested in its own session, then activated; the working one is not touched until then', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await run(); // the working account (function secrets) is signed in and reading
  assert.equal((await status()).state, 'ok');
  const before = await feedSession();
  const m = await managerClient();

  let r = await m.rpc('manage_sahal_account_save', NEW_LOGIN);
  assert.equal(r.error, null);
  assert.equal(r.data.source, 'environment', 'still the working account');
  assert.equal(r.data.pending.username, '252900000055');
  assert.equal(r.data.pending.status, 'draft');
  assert.ok(!JSON.stringify(r.data).includes('new-pass-Zq81') && !JSON.stringify(r.data).includes('5555'), 'no password, no PIN comes back');

  // Cannot be activated before it is verified.
  r = await m.rpc('manage_sahal_account_activate', { p_deposit_codes_updated: true });
  assert.notEqual(r.error, null, 'not verified yet');

  assert.equal((await m.rpc('manage_sahal_account_test')).error, null);
  const v = await verifyNow();
  assert.equal(v.status, 200, v.body);
  const login = seen.filter((x) => x.path === '/api/account/login').pop().body;
  assert.equal(login.username, '252900000055');
  assert.equal(login.password, 'new-pass-Zq81');
  let st = await accountStatus(m);
  assert.equal(st.pending.status, 'verified');
  assert.ok(st.pending.verifiedAt);
  // The working feed was not involved: same session, still reading, no second sign-in for it.
  assert.deepEqual(await feedSession(), before);
  assert.equal((await status()).state, 'ok');
  await run();
  assert.equal((await status()).state, 'ok');
  assert.equal(calls('/api/account/login'), 2, 'one for the working account, one for the test');

  // A different merchant account is a different deposit code: it must be confirmed.
  r = await m.rpc('manage_sahal_account_activate', { p_deposit_codes_updated: false });
  assert.notEqual(r.error, null);
  assert.equal((await accountStatus(m)).source, 'environment', 'nothing changed');
  r = await m.rpc('manage_sahal_account_activate', { p_deposit_codes_updated: true });
  assert.equal(r.error, null);
  assert.equal(r.data.source, 'database');
  assert.equal(r.data.active.username, '252900000055');
  assert.equal(r.data.pending, null);
  assert.notDeepEqual(await feedSession(), before, 'the verified session is now the feed\'s');

  // It reads with that session: no new sign-in, no SMS.
  await run();
  assert.equal((await status()).state, 'ok');
  assert.equal(calls('/api/account/login'), 2);
  // When Sahal ends it, the feed signs in as the NEW account.
  portal.sessions.clear();
  await run();
  const again = seen.filter((x) => x.path === '/api/account/login').pop().body;
  assert.equal(again.username, '252900000055');
  assert.equal(again.password, 'new-pass-Zq81');
  assert.equal((await status()).state, 'ok');

  // Audited, and no secret anywhere it should not be.
  const { rows } = await db.query(`SELECT action FROM audit_logs WHERE action LIKE 'sahal_account.%' AND created_at > now() - interval '5 minutes'`);
  for (const a of ['save', 'test', 'verified', 'activate']) assert.ok(rows.some((x) => x.action === `sahal_account.${a}`), a);
  const everything = JSON.stringify((await db.query(`SELECT before_json, after_json, entity_id FROM audit_logs WHERE created_at > now() - interval '5 minutes'`)).rows)
    + JSON.stringify(await events());
  assert.ok(!everything.includes('new-pass-Zq81') && !everything.includes('5555') && !everything.includes('654321'));
  // It is in Vault, not in a table column.
  const cols = JSON.stringify((await db.query(`SELECT * FROM private.sahal_accounts`)).rows);
  assert.ok(!cols.includes('new-pass-Zq81') && !cols.includes('5555'));
});

test('a new account that wants an SMS code: the code is typed here, once; a test is not repeated within a minute', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await run();
  const m = await managerClient();
  await m.rpc('manage_sahal_account_save', NEW_LOGIN);
  portal.login = 'sms';
  assert.equal((await m.rpc('manage_sahal_account_test')).error, null);
  assert.notEqual((await m.rpc('manage_sahal_account_test')).error, null, 'each test sends an SMS: not twice a minute');
  await verifyNow();
  let st = await accountStatus(m);
  assert.equal(st.pending.status, 'needs_code');
  assert.equal((await status()).state, 'ok', 'the working feed was not asked for a code');
  // A wrong code is refused by Sahal; nothing is verified.
  assert.equal((await m.rpc('manage_sahal_account_code', { p_code: '12' })).error?.message, 'Enter the code from the SMS (numbers only)');
  assert.equal((await m.rpc('manage_sahal_account_code', { p_code: '000000' })).error, null);
  await verifyNow();
  st = await accountStatus(m);
  assert.equal(st.pending.status, 'failed');
  assert.match(st.pending.message, /did not accept the code/);
  assert.notEqual((await m.rpc('manage_sahal_account_code', { p_code: '654321' })).error, null, 'Sahal is no longer waiting for it');
});

test('a new account with the right code is verified; the code is used once', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  const m = await managerClient();
  await m.rpc('manage_sahal_account_save', NEW_LOGIN);
  portal.login = 'sms';
  await m.rpc('manage_sahal_account_test');
  await verifyNow();
  assert.equal((await m.rpc('manage_sahal_account_code', { p_code: '654321' })).error, null);
  await verifyNow();
  await verifyNow(); // woken twice: nothing is sent twice
  assert.equal((await accountStatus(m)).pending.status, 'verified');
  assert.equal(calls('/api/account/2auth'), 1, 'the code was sent once');
});

test('a wrong password: the test fails with Sahal\'s words, nothing can be activated, the working account carries on', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await run();
  const m = await managerClient();
  await m.rpc('manage_sahal_account_save', NEW_LOGIN);
  portal.login = 'wrong';
  await m.rpc('manage_sahal_account_test');
  await verifyNow();
  const st = await accountStatus(m);
  assert.equal(st.pending.status, 'failed');
  assert.match(st.pending.message, /Invalid username or password/);
  assert.ok(!JSON.stringify(st).includes('new-pass-Zq81'));
  const r = await m.rpc('manage_sahal_account_activate', { p_deposit_codes_updated: true });
  assert.notEqual(r.error, null);
  assert.equal(st.source, 'environment');
  portal.login = 'ok';
  await run();
  assert.equal((await status()).state, 'ok', 'the working account was never interrupted');
});

test('discarding the new login removes its secrets; only managers can use any of this', async (t) => {
  const m = await managerClient();
  await m.rpc('manage_sahal_account_save', NEW_LOGIN);
  const count = async () => (await db.query(`SELECT count(*)::int AS n FROM vault.secrets WHERE name LIKE 'sahal_account_%'`)).rows[0].n;
  assert.equal(await count(), 2, 'password and PIN');
  const c = await customer(evcLocal());
  for (const [fn, args] of [['manage_sahal_account_status', {}], ['manage_sahal_account_save', NEW_LOGIN],
    ['manage_sahal_account_test', {}], ['manage_sahal_account_code', { p_code: '123456' }],
    ['manage_sahal_account_activate', { p_deposit_codes_updated: true }], ['manage_sahal_account_discard', {}]]) {
    assert.notEqual((await c.rpc(fn, args)).error, null, `a customer cannot call ${fn}`);
  }
  for (const [fn, args] of [['sahal_credentials', {}], ['sahal_pending_work', {}], ['sahal_pending_report', { p_status: 'failed' }]]) {
    assert.notEqual((await m.rpc(fn, args)).error, null, `${fn} is for the server only`);
  }
  const d = await m.rpc('manage_sahal_account_discard');
  assert.equal(d.error, null);
  assert.equal(d.data.pending, null);
  assert.equal(await count(), 0);
});

test('the status says connected, authentication required or disconnected, and shows the session', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  const m = await managerClient();
  await run();
  let st = await accountStatus(m);
  assert.equal(st.connection, 'connected');
  assert.ok(st.session.active);
  assert.ok(st.session.startedAt);
  assert.ok(st.session.ageSeconds >= 0);
  await db.query(`UPDATE merchant_feed_status SET state = 'needs_code' WHERE provider = 'golis'`);
  assert.equal((await accountStatus(m)).connection, 'authentication_required');
  await db.query(`UPDATE merchant_feed_status SET state = 'ready', result_code = 'error' WHERE provider = 'golis'`);
  assert.equal((await accountStatus(m)).connection, 'disconnected');
  assert.equal((await m.rpc('manage_sahal_connection_check')).error, null);
});

// ---- Sahal's SMS access code, read from the merchant phone ----
// (migrations/*_sahal_auto_code.sql: agent_sahal_sms_code)

const SAHAL_SMS = '-SAHAL SERVICES- Access code is 654321 DIGNIIN FADLAN QOFNA HALA WADAAGIN NUMBERADAN'; // as Sahal sends it, from 898
const smsCode = (c, body, extra = {}) =>
  c.rpc('agent_sahal_sms_code', { p_sender: '898', p_body: body, p_received_at: new Date().toISOString(), p_device_id: 'dev-1', ...extra });
const setSetting = (key, value) =>
  db.query(`INSERT INTO app_settings (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`, [key, value]);

async function waitForCode() {
  portal.login = 'sms';
  await run();
  assert.equal((await status()).state, 'needs_code');
}

test('SMS code: the phone sends it, it is entered by itself, once, and the session is used from then on', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await waitForCode();
  const a = await managerClient();
  const r = await smsCode(a, SAHAL_SMS);
  assert.equal(r.error, null);
  assert.deepEqual(r.data, { result: 'submitted' });
  assert.equal((await status()).state, 'code_entered');
  // A second SMS (or the same one again) finds Sahal no longer waiting.
  assert.deepEqual((await smsCode(a, SAHAL_SMS)).data, { result: 'not_waiting' });
  await run();
  const auth = seen.find((x) => x.path === '/api/account/2auth').body;
  assert.deepEqual(auth, { userNature: 'MERCHANT', type: 'MERCHANT', code: '654321', sessionId: portal.pending });
  assert.equal((await status()).state, 'ok');
  assert.equal(calls('/api/account/2auth'), 1, 'sent once');
  // The code is nowhere it could be read back.
  const s = await status();
  const { rows: [sess] } = await db.query(`SELECT code FROM private.merchant_feed_sessions WHERE provider = 'golis'`);
  assert.equal(sess.code, null, 'cleared once taken');
  const { rows: logs } = await db.query(`SELECT before_json::text AS b, after_json::text AS a FROM audit_logs WHERE action = 'merchant_feed.auto_code' ORDER BY created_at DESC LIMIT 1`);
  assert.equal(logs.length, 1, 'audited');
  assert.ok(!JSON.stringify([s, logs]).includes('654321'), 'no code in the status or the log');
});

test('SMS code: not entered when Sahal is not waiting, when it was asked long ago, or when the SMS is old', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  const a = await managerClient();
  // Nothing asked for: a code-looking SMS changes nothing.
  assert.deepEqual((await smsCode(a, SAHAL_SMS)).data, { result: 'not_waiting' });
  assert.equal((await status()).state, 'ready');

  await waitForCode();
  // An SMS from before Sahal was asked (an old code).
  const old = new Date(Date.now() - 20 * 60 * 1000).toISOString();
  assert.deepEqual((await smsCode(a, SAHAL_SMS, { p_received_at: old })).data, { result: 'ignored', reason: 'old' });
  assert.equal((await status()).state, 'needs_code');
  // Asked more than 10 minutes ago: expired, the manual sign-in starts again.
  await db.query(`UPDATE private.merchant_feed_sessions SET second_at = now() - interval '11 minutes' WHERE provider = 'golis'`);
  assert.deepEqual((await smsCode(a, SAHAL_SMS)).data, { result: 'expired' });
  assert.notEqual((await status()).state, 'code_entered');
});

test('SMS code: only an authorized sender, and only a clear code', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  const a = await managerClient();
  await waitForCode();
  // Not Sahal's: another SMS with a number in it.
  assert.deepEqual((await smsCode(a, 'Your balance is 123456', { p_sender: '192' })).data, { result: 'ignored', reason: 'sender' });
  // A payment SMS that mentions a number.
  assert.equal((await smsCode(a, '[-EVCPLUS-] waxaad $5 ka heshay 252611234567 haraagaagu waa $9', { p_sender: '192' })).data.reason, 'sender');
  // Sahal's, but two different numbers and no "code": not guessed.
  assert.deepEqual((await smsCode(a, 'SAHAL SERVICES 123456 or 654321')).data, { result: 'ignored', reason: 'no_code' });
  // No code at all.
  assert.deepEqual((await smsCode(a, 'SAHAL SERVICES: welcome')).data, { result: 'ignored', reason: 'no_code' });
  assert.equal((await status()).state, 'needs_code', 'none of these changed anything');

  // Sahal's own words from another sender, or its sender without its words.
  assert.equal((await smsCode(a, SAHAL_SMS, { p_sender: '192' })).data.reason, 'sender');
  assert.equal((await smsCode(a, 'Your code is 654321', { p_sender: '898' })).data.reason, 'sender');
  assert.equal((await status()).state, 'needs_code');
  // With no sender listed, the words alone decide.
  await setSetting('sahal_sms_senders', '');
  try {
    assert.deepEqual((await smsCode(a, SAHAL_SMS, { p_sender: 'SAHAL' })).data, { result: 'submitted' });
  } finally {
    await setSetting('sahal_sms_senders', '898');
  }
});

test('SMS code: reads "Access code is ..." in other layouts, and can be switched off', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  const a = await managerClient();
  await waitForCode();
  await setSetting('sahal_auto_code', 'off');
  try {
    assert.deepEqual((await smsCode(a, SAHAL_SMS)).data, { result: 'off' });
    assert.equal((await status()).state, 'needs_code', 'the manual entry is still there');
  } finally {
    await setSetting('sahal_auto_code', 'on');
  }
  assert.deepEqual((await smsCode(a, 'SAHAL: Your 2nd step access code: 87 12 34 expires in 10 minutes')).data, { result: 'ignored', reason: 'no_code' });
  assert.deepEqual((await smsCode(a, 'SAHAL: Your access code is 8712 expires in 10 minutes. Do not share.')).data, { result: 'submitted' });
  assert.equal((await db.query(`SELECT code FROM private.merchant_feed_sessions WHERE provider = 'golis'`)).rows[0].code, '8712');
});

test('SMS code: only an agent or manager can send it, not a customer', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await waitForCode();
  const anon = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  assert.notEqual((await smsCode(anon, SAHAL_SMS)).error, null);
  const c = await customer(evcLocal());
  assert.notEqual((await smsCode(c, SAHAL_SMS)).error, null);
  assert.equal((await status()).state, 'needs_code');
});

test('SMS code: a withdrawal waiting for the session goes out once after the automatic sign-in, and a refused code sends nothing', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  await sahalOn();
  try {
    await run();
    portal.canSend.clear();
    portal.login = 'sms';
    const local = evcLocal();
    const c = await richCustomer(local);
    const w = await withdrawalOf(c, local, 3);
    await run();
    assert.equal((await status()).state, 'needs_code');
    assert.equal(portal.transfers.length, 0);
    const a = await managerClient();

    // A wrong code (Sahal refuses it): the feed stops, nothing is paid, the
    // customer is not refunded, and the manual sign-in is still there.
    assert.equal((await smsCode(a, '-SAHAL SERVICES- Access code is 111111')).data.result, 'submitted');
    await run();
    assert.equal((await status()).state, 'stopped');
    assert.equal(portal.transfers.length, 0);
    assert.equal((await order(w.id)).status, 'pending');
    assert.equal(await walletOf(c), '7.00');

    // Manual sign-in again; this time the SMS is right.
    const m = await managerClient();
    assert.equal((await m.rpc('manage_merchant_feed_sign_in', { p_provider: 'golis' })).error, null);
    await run();
    assert.equal((await status()).state, 'needs_code');
    assert.equal((await smsCode(a, SAHAL_SMS)).data.result, 'submitted');
    await run();
    assert.equal((await status()).state, 'ok');
    assert.equal((await order(w.id)).status, 'completed', 'resumed by itself');
    assert.equal(portal.transfers.length, 1);
    assert.equal(await walletOf(c), '7.00', 'taken once');
    await run();
    await run();
    assert.equal(portal.transfers.length, 1, 'never sent again');
  } finally {
    await sahalOff();
  }
});

// ---- An SMS-forwarding app posting the SMS (functions/sahal-sms-hook) ----

const hookUrl = `${URL}/functions/v1/sahal-sms-hook`;
const hook = async (token, body, { as = 'json', headers = {} } = {}) => {
  const h = { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers };
  let init;
  if (as === 'json') init = { method: 'POST', headers: { ...h, 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
  else if (as === 'form') init = { method: 'POST', headers: { ...h, 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(body).toString() };
  else if (as === 'text') init = { method: 'POST', headers: { ...h, 'Content-Type': 'text/plain' }, body };
  else init = { method: 'GET', headers: h };
  const res = await fetch(as === 'get' ? `${hookUrl}?${new URLSearchParams(body)}` : hookUrl, init);
  return { status: res.status, body: await res.json().catch(() => null) };
};
let hookServed = false;
before(async () => {
  hookServed = (await fetch(hookUrl, { method: 'POST' }).catch(() => null))?.status === 403;
});
const newToken = async () => {
  const m = await managerClient();
  const r = await m.rpc('manage_sahal_sms_hook_rotate');
  assert.equal(r.error, null);
  return r.data.token;
};

test('SMS forwarder: a manager makes the token; it is shown once and only its hash is kept', async (t) => {
  const m = await managerClient();
  const token = await newToken();
  assert.match(token, /^shk_[0-9a-f]{48}$/);
  const { rows } = await db.query(`SELECT token_hash FROM private.sahal_sms_hooks WHERE revoked_at IS NULL`);
  assert.equal(rows.length, 1);
  assert.ok(!rows[0].token_hash.includes(token));
  const st = (await m.rpc('manage_sahal_sms_hook_status')).data;
  assert.equal(st.configured, true);
  assert.ok(!JSON.stringify(st).includes(token), 'the status never shows it');
  const { rows: log } = await db.query(`SELECT after_json::text AS a FROM audit_logs WHERE action = 'sahal_sms_hook.rotate' ORDER BY created_at DESC LIMIT 1`);
  assert.ok(!JSON.stringify(log).includes(token), 'not in the audit log');
  // A customer cannot make one.
  const c = await customer(evcLocal());
  assert.notEqual((await c.rpc('manage_sahal_sms_hook_rotate')).error, null);
});

test('SMS forwarder: the posted SMS enters the code once and the session is used from then on', async (t) => {
  if (!served || !hookServed) return t.skip('the functions are not served');
  const token = await newToken();
  await waitForCode();
  // Nobody without the token gets anything.
  assert.equal((await hook(null, { from: '898', text: SAHAL_SMS })).status, 403);
  assert.equal((await hook('shk_wrong', { from: '898', text: SAHAL_SMS })).status, 403);
  assert.equal((await status()).state, 'needs_code');

  const ok = await hook(token, { from: '898', text: SAHAL_SMS });
  assert.deepEqual([ok.status, ok.body], [200, { result: 'submitted' }]);
  assert.ok(!JSON.stringify(ok).includes('654321'), 'the answer never has the code');
  // The same SMS again (a forwarder's retry): Sahal is no longer waiting.
  assert.deepEqual((await hook(token, { from: '898', text: SAHAL_SMS })).body, { result: 'not_waiting' });
  await run();
  assert.equal(calls('/api/account/2auth'), 1, 'sent once');
  assert.deepEqual(seen.find((x) => x.path === '/api/account/2auth').body,
    { userNature: 'MERCHANT', type: 'MERCHANT', code: '654321', sessionId: portal.pending });
  assert.equal((await status()).state, 'ok');
  const st = await db.query(`SELECT last_used_at FROM private.sahal_sms_hooks WHERE revoked_at IS NULL`);
  assert.ok(st.rows[0].last_used_at);
});

test('SMS forwarder: forms, text and GET with other field names also work; other SMS and old tokens do not', async (t) => {
  if (!served || !hookServed) return t.skip('the functions are not served');
  const old = await newToken();
  const token = await newToken();
  assert.equal((await hook(old, { from: '898', text: SAHAL_SMS })).status, 403, 'a new token revokes the old one');

  await waitForCode();
  // Not Sahal's: nothing.
  assert.deepEqual((await hook(token, { sender: '192', message: 'Your balance is 123456' }, { as: 'form' })).body,
    { result: 'ignored', reason: 'sender' });
  assert.equal((await status()).state, 'needs_code');
  // Token in a header, the SMS as a form.
  const r = await hook(null, { address: '898', body: SAHAL_SMS }, { as: 'form', headers: { 'X-Hook-Token': token } });
  assert.deepEqual(r.body, { result: 'submitted' });
  assert.equal((await status()).state, 'code_entered');

  // GET with the token in the query (some forwarders can only do that).
  await db.query(`UPDATE merchant_feed_status SET state = 'ready' WHERE provider = 'golis'`);
  await waitForCode();
  const g = await hook(null, { token, from: '898', msg: 'Sahal access code is 246810' }, { as: 'get' });
  assert.deepEqual(g.body, { result: 'submitted' });
  assert.equal((await db.query(`SELECT code FROM private.merchant_feed_sessions WHERE provider = 'golis'`)).rows[0].code, '246810');
});

test('SMS forwarder: no sender field (as some forwarders send it) is accepted on Sahal\'s words; the Agent App path still needs 898', async (t) => {
  if (!served || !hookServed) return t.skip('the functions are not served');
  const token = await newToken();
  await waitForCode();
  // Not Sahal's words and no sender: nothing.
  assert.deepEqual((await hook(token, { text: 'Your balance is 123456' })).body, { result: 'ignored', reason: 'sender' });
  // A different sender is still refused when one is given.
  assert.equal((await hook(token, { from: '192', text: SAHAL_SMS })).body.reason, 'sender');
  assert.equal((await status()).state, 'needs_code');
  // The GET form some forwarders use, with only the message.
  const g = await hook(token, { text: SAHAL_SMS }, { as: 'get' });
  assert.deepEqual(g.body, { result: 'submitted' });
  // The Agent App's own path with no sender is still refused.
  await db.query(`UPDATE merchant_feed_status SET state = 'ready' WHERE provider = 'golis'`);
  await waitForCode();
  const a = await managerClient();
  assert.equal((await smsCode(a, SAHAL_SMS, { p_sender: '' })).data.reason, 'sender');
});

test('SMS forwarder: revoked, nothing gets in', async (t) => {
  if (!served || !hookServed) return t.skip('the functions are not served');
  const token = await newToken();
  const m = await managerClient();
  assert.equal((await m.rpc('manage_sahal_sms_hook_revoke')).data.configured, false);
  await waitForCode();
  assert.equal((await hook(token, { from: '898', text: SAHAL_SMS })).status, 403);
  assert.equal((await status()).state, 'needs_code');
});

test('Sahal balance: read with the feed about once a minute and recorded as read; a failed read is recorded with its reason', async (t) => {
  if (!served) return t.skip('golis-merchant is not served');
  portal.rows = [row('7012000001', '1.00', '252610346060')];
  portal.balance = '1,234.56';
  const r = await run();
  assert.equal(r.status, 200, r.body);
  assert.equal(calls('/api/account/balance'), 1);
  let rows = (await db.query('SELECT ok, balance_cents, error FROM sahal_balances')).rows;
  assert.deepEqual(rows.map((x) => [x.ok, String(x.balance_cents)]), [[true, '123456']]);

  // A second run inside the minute does not ask again, and the feed is as before.
  await run();
  assert.equal(calls('/api/account/balance'), 1);
  assert.equal((await status()).state, 'ok');
  assert.equal((await stored()).length, 1);

  // Due again: a read that fails is recorded with why; the good read stays.
  await db.query(`UPDATE sahal_balances SET checked_at = now() - interval '2 minutes'`);
  portal.balance = null; // the stand-in has no balance to give
  await run();
  rows = (await db.query('SELECT ok, balance_cents, error FROM sahal_balances ORDER BY checked_at')).rows;
  assert.equal(rows.length, 2);
  assert.equal(rows[1].ok, false);
  assert.match(rows[1].error, /did not return a balance/);
  assert.equal(String(rows[0].balance_cents), '123456');
  assert.equal((await status()).state, 'ok', 'a balance problem is not a feed problem');
});
