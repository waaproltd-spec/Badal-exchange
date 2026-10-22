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
    const reply = (o) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
    if (req.url === '/api/account/currencies') {
      return reply({ resultCode: 2001, currencies: [{ CURRENCYCODE: '706', CURRENCYNAME: 'SOS' }, { CURRENCYCODE: '840', CURRENCYNAME: 'USD' }] });
    }
    if (req.url === '/api/account/login') {
      if (portal.login === 'otp') return reply({ resultCode: 6083, replyMessage: 'Enter the code sent to your phone' });
      if (portal.login === 'wrong') return reply({ resultCode: 4001, replyMessage: 'Invalid username or password' });
      if (portal.login === 'sms') {
        portal.pending = `P${portal.next++}`;
        return reply({ resultCode: 1001, sessionId: portal.pending, replyMessage: 'Access code sent' });
      }
      const s = `S${portal.next++}`;
      portal.sessions.add(s);
      return reply({ resultCode: 2001, sessionId: s, name: 'BULSHO AGENT' });
    }
    if (req.url === '/api/account/2auth') {
      if (b.sessionId !== portal.pending || b.code !== '654321') return reply({ resultCode: 4002, replyMessage: 'Invalid access code' });
      const s = `S${portal.next++}`;
      portal.sessions.add(s);
      return reply({ resultCode: 2001, sessionId: s });
    }
    if (req.url === '/api/account/transactions') {
      if (!portal.sessions.has(b.sessionId)) return reply({ resultCode: 4005, replyMessage: 'Session expired' });
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
  Object.assign(portal, { login: 'ok', sessions: new Set(), rows: [], pending: null });
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
