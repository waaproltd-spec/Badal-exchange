// Agent App Company Balances (functions/company-balances and
// migrations/*_company_balances.sql), against a stand-in CashdeskBot.
//
//   Needs the local stack, SUPABASE_SERVICE_ROLE_KEY, and the functions
//   served with the stand-in: supabase functions serve --env-file tests/player_lookup.env

import { test, before, after } from 'node:test';
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
const seed = Number(Date.now().toString().slice(-6));
let n = 0;

// Stand-in CashdeskBot balances: cash desk 1 is 888STARZ, 2 is 1XBET, 3 is WinWin
// (tests/player_lookup.env).
const registers = { 1: { Balance: 850, Limit: 1000 }, 2: 'down', 3: { Balance: 500, Limit: 200 } };
const asked = [];
const standIn = http.createServer((req, res) => {
  const m = req.url.match(/^\/Cashdesk\/(\d+)\/Balance/);
  if (!m) return res.writeHead(404).end();
  asked.push(m[1]);
  const r = registers[m[1]];
  if (r === 'down') return res.writeHead(500).end('down');
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(r));
});

let served = false;
const client = (key = ANON_KEY) => createClient(URL, key, { auth: { persistSession: false, autoRefreshToken: false } });

async function signIn(phone) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}

async function newUser(role, responsibilities = [], balanceCents = 0) {
  const phone = `${role === 'customer' ? '2526' : '2527'}${String(seed).padStart(6, '0')}${String(n++).padStart(2, '0')}`;
  const { rows } = await db.query(`INSERT INTO users (role, phone, name, password_hash)
    VALUES ($1, $2, $3, private.hash_password($4)) RETURNING id`, [role, phone, `${role} ${n}`, PASSWORD]);
  if (role === 'customer') {
    await db.query('INSERT INTO wallets (customer_id, available_cents) VALUES ($1, $2)', [rows[0].id, balanceCents]);
  } else {
    await db.query(`INSERT INTO agent_profiles (user_id, responsibilities) VALUES ($1, $2)
      ON CONFLICT (user_id) DO UPDATE SET responsibilities = EXCLUDED.responsibilities`, [rows[0].id, responsibilities]);
  }
  return { id: rows[0].id, c: await signIn(phone) };
}

async function balances(c, query = '') {
  const token = c && (await c.auth.getSession()).data.session.access_token;
  const res = await fetch(`${URL}/functions/v1/company-balances${query}`, {
    headers: { apikey: ANON_KEY, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  });
  return { status: res.status, body: await res.json() };
}
const company = (body, method) => body.companies.find((x) => x.method === method);

let manager;
let worker;

before(async () => {
  await new Promise((r) => standIn.listen(4999, '0.0.0.0', r));
  const res = await fetch(`${URL}/functions/v1/company-balances`, { method: 'OPTIONS' }).catch(() => null);
  served = (res?.ok ?? false) && Boolean(SERVICE_KEY);
  if (!served) return;
  await db.query('DELETE FROM cashdesk_balances');
  // Nothing from other test files may be waiting for the worker or a top-up.
  await db.query(`UPDATE orders SET auto_claimed_at = now(), low_funds_since = NULL WHERE method IN ('888starz', 'onexbet', 'winwin')
    AND (auto_claimed_at IS NULL OR low_funds_since IS NOT NULL)`);
  await db.query(`UPDATE orders SET status = 'failed' WHERE method IN ('888starz', 'onexbet', 'winwin') AND status IN ('pending', 'processing')`);
  manager = { c: await signIn('252610000002') };
  worker = client(SERVICE_KEY);
});
after(async () => {
  standIn.close();
  await db.end();
});

test('who may see balances: managers and agents given view_company_balances, nobody else', async (t) => {
  if (!served) return t.skip('company-balances is not served');
  assert.equal((await balances(null)).status, 401);
  const plain = await newUser('agent');
  const r = await balances(plain.c);
  assert.equal(r.status, 403);
  assert.equal(r.body.error.code, 'FORBIDDEN');
  assert.ok((await plain.c.rpc('agent_company_detail', { p_method: '888starz' })).error);
  const cu = await newUser('customer');
  assert.equal((await balances(cu.c)).status, 403);
  assert.equal(asked.length, 0, 'no cash register was asked for them');
  const viewer = await newUser('agent', ['view_company_balances']);
  assert.equal((await balances(viewer.c)).status, 200);
});

test('live, offline and not-connected companies; the total only adds verified balances', async (t) => {
  if (!served) return t.skip('company-balances is not served');
  const { status, body } = await balances(manager.c, '?refresh=1');
  assert.equal(status, 200);
  const starz = company(body, '888starz');
  assert.deepEqual([starz.status, starz.balance, starz.limit, starz.source, starz.connected],
    ['available', '850.00', '1000.00', 'CashdeskBot', true]);
  assert.ok(starz.lastSuccessAt);
  const onex = company(body, 'onexbet');
  assert.equal(onex.status, 'offline');
  assert.equal(onex.balance, null, 'never read: no amount, not zero');
  assert.match(onex.lastError, /HTTP 500|CashdeskBot/);
  const winwin = company(body, 'winwin');
  assert.deepEqual([winwin.status, winwin.balance, winwin.limit, winwin.connected], ['available', '500.00', '200.00', true]);
  for (const m of ['melbet', 'dbbet', 'betwinner', 'evc_plus']) {
    const x = company(body, m);
    assert.deepEqual([x.status, x.balance, x.connected], ['not_connected', null, false], m);
  }
  assert.deepEqual(body.companies.slice(0, 3).map((x) => x.method).sort(), ['888starz', 'onexbet', 'winwin'], 'connected first');
  assert.equal(body.total, '1350.00');
  assert.equal(body.totalCompanies, 2);
  assert.equal(body.unavailableCount, 1);
  assert.equal(body.notConnectedCount, 7);
});

test('refreshes are limited: a register is read at most every 15 seconds', async (t) => {
  if (!served) return t.skip('company-balances is not served');
  const before = asked.length;
  await balances(manager.c, '?refresh=1');
  await balances(manager.c, '?refresh=1');
  await balances(manager.c);
  assert.equal(asked.length, before, 'read moments ago');
  await db.query(`UPDATE cashdesk_balances SET checked_at = checked_at - interval '20 seconds'`);
  await balances(manager.c, '?refresh=1');
  assert.equal(asked.length, before + 3);
});

test('withdrawals waiting for a top-up: low, with how much more is needed', async (t) => {
  if (!served) return t.skip('company-balances is not served');
  registers[1] = { Balance: 900, Limit: 350 }; // Limit: what it can still sell
  await db.query(`UPDATE cashdesk_balances SET checked_at = checked_at - interval '1 minute'`);
  await balances(manager.c, '?refresh=1');
  const cu = await newUser('customer', [], 100000);
  const { data: o, error } = await cu.c.rpc('customer_create_withdrawal', {
    p_method: '888starz', p_amount: '400', p_account_id: '1847412855', p_idempotency_key: randomUUID() });
  if (error) throw error;
  const job = (await worker.rpc('platform_claim_next')).data;
  assert.equal(job.orderId, o.id);
  await worker.rpc('platform_finish', { p_order_id: o.id, p_outcome: 'low_funds', p_message: 'maximum of 350' });

  const body = (await balances(manager.c)).body;
  const starz = company(body, '888starz');
  assert.equal(starz.status, 'low');
  assert.deepEqual([starz.waitingWithdrawals, starz.waitingAmount, starz.topUpNeeded], [1, '400.00', '50.00']);
  assert.equal(starz.openWithdrawals, 1);
  assert.equal(body.lowCount, 1);
  assert.equal(body.total, '1400.00', 'still counted: the balance is verified (plus WinWin\'s 500)');

  const detail = (await manager.c.rpc('agent_company_detail', { p_method: '888starz', p_status: 'open' })).data;
  assert.equal(detail.orders[0].id, o.id);
  assert.equal(detail.orders[0].waitingTopUp, true);
  assert.equal(detail.checks[0].balance, '900.00');
  assert.equal(detail.checks[0].limit, '350.00');

  // Paid once topped up: no longer low, counted as sent in the period.
  await db.query(`UPDATE orders SET updated_at = now() - interval '2 minutes' WHERE id = $1`, [o.id]);
  await worker.rpc('platform_claim_next');
  await worker.rpc('platform_finish', { p_order_id: o.id, p_outcome: 'done', p_reference: '888starz deposit 400' });
  registers[1] = { Balance: 1300, Limit: 600 };
  await db.query(`UPDATE cashdesk_balances SET checked_at = checked_at - interval '1 minute'`);
  const after = company((await balances(manager.c, '?refresh=1')).body, '888starz');
  assert.equal(after.status, 'available');
  // Counted once, when it completed (other tests' orders today are in there too).
  assert.equal(Number(after.period.sent) - Number(starz.period.sent), 400);
  assert.equal(after.period.sentCount - starz.period.sentCount, 1);
});

test('a low balance on its own, and an old read: low, then stale and left out of the total', async (t) => {
  if (!served) return t.skip('company-balances is not served');
  registers[1] = { Balance: 900, Limit: 12.5 };
  await db.query(`UPDATE cashdesk_balances SET checked_at = checked_at - interval '1 minute'`);
  const low = company((await balances(manager.c, '?refresh=1')).body, '888starz');
  assert.deepEqual([low.status, low.balance, low.limit, low.topUpNeeded], ['low', '900.00', '12.50', null]);

  await db.query(`UPDATE cashdesk_balances SET checked_at = checked_at - interval '20 minutes' WHERE method = '888starz'`);
  // The worker's own refresh is what normally keeps it fresh; read without one.
  const body = (await manager.c.rpc('agent_company_balances')).data;
  assert.equal(company(body, '888starz').status, 'stale');
  // Last known, labelled stale: the read plus what moved after it.
  const stale = company(body, '888starz');
  assert.equal(stale.liveBalance, '900.00');
  assert.equal(Number(stale.balance), 900 + Number(stale.salesSinceCheck) - Number(stale.payoutsSinceCheck));
  assert.equal(body.total, '500.00', 'only WinWin\'s fresh read');
  assert.equal(body.unavailableCount, 2);
});

test('nobody can set a balance from the app', async (t) => {
  if (!served) return t.skip('company-balances is not served');
  const { error } = await manager.c.rpc('company_balance_record', {
    p_method: '888starz', p_balance: 999999, p_limit: null, p_error: null });
  assert.ok(error);
  const { error: e2 } = await manager.c.from('cashdesk_balances').insert({ method: '888starz', ok: true, balance_cents: 1 });
  assert.ok(e2);
  await assert.rejects(worker.rpc('company_balance_record', { p_method: 'melbet', p_balance: 5, p_limit: null, p_error: null })
    .then((r) => { if (r.error) throw r.error; }));
});
