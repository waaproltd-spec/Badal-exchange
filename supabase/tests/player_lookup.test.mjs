// Customer App "Find a Player" (functions/player-lookup and
// migrations/*_player_lookup.sql), against a stand-in CashdeskBot.
//
//   Needs the local stack and the function served with the stand-in:
//   supabase functions serve --env-file tests/player_lookup.env
//   (CASHDESKBOT_BASE_URL / CASHDESKBOT_1XBET_BASE_URL -> this file's
//   stand-in on port 4999, reached from Docker at the network gateway).

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const seed = Number(Date.now().toString().slice(-6));
let n = 0;

// Stand-in CashdeskBot player search: GET /Users/{id}.
const players = {
  '1847412855': { UserId: 1847412855, CurrencyId: 1, Name: 'Yaasin Maxamed' },
  '2222': { UserId: 2222, CurrencyId: 1 }, // no name given
};
const asked = [];
const standIn = http.createServer((req, res) => {
  const m = req.url.match(/^\/Users\/(\d+)/);
  asked.push(req.url);
  if (!m) return res.writeHead(404).end();
  if (m[1] === '5555') return res.writeHead(500).end('boom');
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(players[m[1]] ?? { UserId: 0, CurrencyId: 0 }));
});

let served = false;
before(async () => {
  await new Promise((r) => standIn.listen(4999, '0.0.0.0', r));
  const res = await fetch(`${URL}/functions/v1/player-lookup`, { method: 'OPTIONS' }).catch(() => null);
  served = res?.ok ?? false;
});
after(async () => {
  standIn.close();
  await db.end();
});

async function customer() {
  const phone = `2526${String(seed).padStart(6, '0')}${String(n++).padStart(2, '0')}`;
  await db.query(`WITH u AS (INSERT INTO users (role, phone, name, password_hash)
      VALUES ('customer', $1, 'Lookup Test', private.hash_password($2)) RETURNING id)
    INSERT INTO wallets (customer_id) SELECT id FROM u`, [phone, PASSWORD]);
  const c = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}

const lookup = async (c, method, accountId) => {
  const token = c && (await c.auth.getSession()).data.session.access_token;
  const res = await fetch(`${URL}/functions/v1/player-lookup`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: ANON_KEY, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ method, accountId }),
  });
  return { status: res.status, body: await res.json() };
};

test('a known player: found, with the name the platform gave', async (t) => {
  if (!served) return t.skip('player-lookup is not served');
  const c = await customer();
  assert.deepEqual(await lookup(c, '888starz', '1847412855'),
    { status: 200, body: { found: true, accountId: '1847412855', name: 'Yaasin Maxamed' } });
  assert.deepEqual((await lookup(c, 'onexbet', '1847412855')).body.name, 'Yaasin Maxamed');
});

test('a player without a name: found, name null (never made up)', async (t) => {
  if (!served) return t.skip('player-lookup is not served');
  const c = await customer();
  assert.deepEqual(await lookup(c, '888starz', '2222'), { status: 200, body: { found: true, accountId: '2222', name: null } });
});

test('an unknown player ID: not found', async (t) => {
  if (!served) return t.skip('player-lookup is not served');
  const c = await customer();
  assert.deepEqual(await lookup(c, '888starz', '9999'), { status: 200, body: { found: false, accountId: '9999' } });
});

test('the platform failing: 503, nothing invented', async (t) => {
  if (!served) return t.skip('player-lookup is not served');
  const c = await customer();
  const r = await lookup(c, '888starz', '5555');
  assert.equal(r.status, 503);
  assert.equal(r.body.error.code, 'PLAYER_LOOKUP_UNAVAILABLE');
});

test('checked before asking the platform: sign-in, method, ID, rate limit', async (t) => {
  if (!served) return t.skip('player-lookup is not served');
  const before = asked.length;
  assert.equal((await lookup(null, '888starz', '1847412855')).status, 401);
  const c = await customer();
  assert.equal((await lookup(c, 'evc_plus', '1847412855')).body.error.code, 'VALIDATION_ERROR');
  assert.equal((await lookup(c, '888starz', '12ab')).body.error.code, 'VALIDATION_ERROR');
  assert.equal(asked.length, before, 'CashdeskBot was not asked');
  // 30 an hour per customer.
  await db.query(`INSERT INTO player_lookups (customer_id, method, account_id)
    SELECT u.id, '888starz', '1' FROM users u, generate_series(1, 30) WHERE u.phone = (
      SELECT phone FROM users WHERE name = 'Lookup Test' ORDER BY created_at DESC LIMIT 1)`);
  const r = await lookup(c, '888starz', '1847412855');
  assert.equal(r.status, 429);
  assert.equal(r.body.error.code, 'RATE_LIMITED');
});

test('staff can not use it; customers can not read the lookups', async () => {
  const c = await customer();
  const { data, error } = await c.from('player_lookups').select('*');
  assert.ok(error || data.length === 0);
  const agent = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  await agent.auth.signInWithPassword({ email: '252610000002@phone.baari.invalid', password: PASSWORD });
  const { error: e2 } = await agent.rpc('customer_begin_player_lookup', { p_method: '888starz', p_account_id: '1' });
  assert.ok(e2);
});
