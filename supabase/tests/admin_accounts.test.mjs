// Admin Dashboard, phase 1 (migrations/*_admin_accounts.sql): editing,
// resetting and deleting agent accounts, the last full administrator, login
// history, agent performance and bonus limits. Run with the other suites: npm test.
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

async function login(phone, password = PASSWORD) {
  const c = createClient(URL, ANON_KEY, opts);
  const { error } = await c.auth.signInWithPassword({ email: `${phone.replace(/\D/g, '')}@phone.baari.invalid`, password });
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
const phone = () => `25261${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;

let manager;
let managerId;
async function agent(responsibilities = ['evc_deposit']) {
  const p = phone();
  const a = await rpc(manager, 'admin_create_agent', { p_phone: p, p_name: 'Phase One Agent', p_password: PASSWORD,
    p_responsibilities: responsibilities });
  return { id: a.id, phone: p };
}

before(async () => {
  manager = await login('252610000002');
  managerId = (await rpc(manager, 'session_profile')).id;
});
after(async () => {
  await db.query(`UPDATE app_settings SET value = '' WHERE key IN ('bonus:daily_limit_micros', 'bonus:monthly_limit_micros')`);
  await db.end();
});

test('1. reset an agent\'s password: the old one stops working, the new one logs in, their sessions end', async () => {
  const a = await agent();
  const theirs = await login(a.phone);
  await rpc(theirs, 'agent_profile');
  await rpc(manager, 'admin_reset_agent_password', { p_id: a.id, p_new_password: 'NewPass-2026' });
  await assert.rejects(login(a.phone), 'the old password no longer works');
  await rpc(await login(a.phone, 'NewPass-2026'), 'agent_profile');
  await rejects(rpc(manager, 'admin_reset_agent_password', { p_id: a.id, p_new_password: 'short' }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'admin_reset_agent_password', { p_id: managerId, p_new_password: 'NewPass-2026' }), 'USE_CHANGE_PASSWORD');
  const { rows } = await db.query(`SELECT before_json, after_json FROM audit_logs WHERE action = 'agent.reset_password' AND entity_id = $1`, [a.id]);
  assert.equal(rows.length, 1, 'audited once');
  assert.ok(!JSON.stringify(rows[0]).includes('NewPass-2026'), 'the password is never in the audit log');
});

test('2. create, edit, deactivate and delete an agent; deleted ones are hidden and cannot log in', async () => {
  const a = await agent();
  const p2 = phone();
  const e = await rpc(manager, 'admin_update_agent', { p_id: a.id, p_name: 'Renamed Agent', p_phone: p2 });
  assert.equal(e.name, 'Renamed Agent');
  assert.equal(e.phone, p2);
  await rpc(await login(p2), 'agent_profile');
  const other = await agent();
  await rejects(rpc(manager, 'admin_update_agent', { p_id: a.id, p_name: 'X', p_phone: other.phone }), 'PHONE_TAKEN');

  await rpc(manager, 'admin_set_agent_status', { p_id: a.id, p_enabled: false });
  await rejects(rpc(manager, 'admin_delete_agent', { p_id: a.id, p_reason: '' }), 'VALIDATION_ERROR');
  await rpc(manager, 'admin_delete_agent', { p_id: a.id, p_reason: 'Left the company' });
  const list = await rpc(manager, 'admin_agents');
  assert.ok(!list.some((x) => x.id === a.id), 'hidden from the list');
  await assert.rejects((async () => rpc(await login(p2), 'agent_profile'))(), 'a deleted account cannot log in or work');
  await rejects(rpc(manager, 'admin_delete_agent', { p_id: a.id, p_reason: 'again' }), 'NOT_FOUND');
  await rejects(rpc(manager, 'admin_delete_agent', { p_id: managerId, p_reason: 'self' }), 'SELF_LOCKOUT');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM users WHERE id = $1`, [a.id]);
  assert.equal(rows[0].n, 1, 'kept for its orders and audit trail');
});

test('3. permissions: only managers manage accounts; the last full administrator is protected', async () => {
  const plain = await agent(['evc_deposit']);
  const c = await login(plain.phone);
  await rejects(rpc(c, 'admin_reset_agent_password', { p_id: managerId, p_new_password: 'NewPass-2026' }), 'FORBIDDEN');
  await rejects(rpc(c, 'admin_delete_agent', { p_id: managerId, p_reason: 'nope' }), 'FORBIDDEN');
  await rejects(rpc(c, 'admin_login_history'), 'FORBIDDEN');

  const second = await agent(['manage_settings']);
  assert.equal((await rpc(manager, 'admin_agents')).find((x) => x.id === second.id).full_admin, true);
  // With every other full administrator out of the way (in a transaction rolled back), `second` is the last one.
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    await client.query(`UPDATE users SET status = 'disabled' WHERE role IN ('agent', 'admin') AND id <> $1`, [second.id]);
    await assert.rejects(client.query(`SELECT private.ensure_other_full_admin($1)`, [second.id]), /last full administrator/);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
  // With others around it is allowed.
  await rpc(manager, 'admin_set_agent_responsibilities', { p_id: second.id, p_responsibilities: ['evc_deposit'] });
});

test('10. login history and security changes are recorded, without passwords', async () => {
  const a = await agent();
  const c = await login(a.phone);
  await rpc(c, 'session_profile', { p_record_login: true });
  await rpc(manager, 'admin_reset_agent_password', { p_id: a.id, p_new_password: 'NewPass-2026' });
  const h = await rpc(manager, 'admin_login_history', { p_user_id: a.id });
  const actions = h.map((x) => x.action);
  assert.ok(actions.includes('user.login'));
  assert.ok(actions.includes('agent.reset_password'));
  assert.ok(actions.includes('agent.create'));
  assert.ok(!JSON.stringify(h).includes('NewPass-2026'));
  assert.ok((await rpc(manager, 'admin_agents')).find((x) => x.id === a.id).last_login_at);
});

test('agent performance over a period', async () => {
  const today = new Date().toISOString().slice(0, 10);
  const perf = await rpc(manager, 'admin_agent_performance', { p_from: today, p_to: today });
  assert.ok(Array.isArray(perf));
  for (const p of perf) {
    assert.ok(p.deposits >= 0 && p.withdrawals >= 0 && p.failed >= 0);
    assert.match(p.depositAmount, /^\d+\.\d\d$/);
  }
  await rejects(rpc(manager, 'admin_agent_performance', { p_from: '2026-02-02', p_to: '2026-02-01' }), 'VALIDATION_ERROR');
});

test('6/7. bonus daily limit: credited up to the limit, the rest not, once', async () => {
  const p = phone().replace('25261', '25262');
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO users (role, phone, name, password_hash) VALUES ('customer', $1, 'Limit Test', private.hash_password($2)) RETURNING id)
     INSERT INTO wallets (customer_id) SELECT id FROM u RETURNING customer_id`, [p, PASSWORD]);
  const s = await rpc(manager, 'manage_set_bonus_limits', { p_daily: '1.50', p_monthly: '10' });
  assert.equal(s.dailyLimit, '1.50');
  assert.equal(s.monthlyLimit, '10.00');
  await rejects(rpc(manager, 'manage_set_bonus_limits', { p_daily: '20', p_monthly: '10' }), 'VALIDATION_ERROR');
  const order = async (cents) => {
    const { rows: [o] } = await db.query(
      `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
       VALUES ($1, $2, 'withdraw', 'edahab', 'pending', $3, 1, $3, 0) RETURNING id`, [`EXLM${seed}${n++}`, u.customer_id, cents]);
    await db.query(`UPDATE orders SET status = 'completed', completed_at = now() WHERE id = $1`, [o.id]);
    return o.id;
  };
  try {
    await order(10_000);  // 1% of $100 = $1.00
    await order(10_000);  // $1.00 more, but only $0.50 left today
    await order(10_000);  // nothing left today
    const { rows } = await db.query(`SELECT amount_micros, note FROM bonus_entries WHERE customer_id = $1 ORDER BY created_at`, [u.customer_id]);
    assert.deepEqual(rows.map((r) => [r.amount_micros, r.note]), [['1000000', null], ['500000', 'Daily bonus limit reached']]);
    const { rows: [b] } = await db.query(`SELECT balance_micros FROM bonus_wallets WHERE customer_id = $1`, [u.customer_id]);
    assert.equal(b.balance_micros, '1500000');
    await rejects(rpc(await login(p), 'manage_set_bonus_limits', { p_daily: '', p_monthly: '' }), 'FORBIDDEN');
  } finally {
    await rpc(manager, 'manage_set_bonus_limits', { p_daily: '', p_monthly: '' });
  }
  assert.equal((await rpc(manager, 'manage_bonus_settings')).dailyLimit, null);
});
