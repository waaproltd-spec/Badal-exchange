// Betting platforms are dynamic (migrations/*_betting_platforms_dynamic.sql): a
// platform that exists as a payment method gets its connection record by itself,
// shows in the Agent App with its status, keeps its own ON/OFF and credentials,
// stays as it was for customers until its cash desk is connected, and then
// reaches the Customer App as a cash desk without any new release.
// Run with the other suites: npm test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
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
const key = `dynplat${seed}`;
let manager;
const anon = createClient(URL, ANON_KEY, opts);
const listed = async (method) => (await rpc(manager, 'manage_betting_platforms')).platforms.find((p) => p.method === method);
const catalogRow = async (method) => (await rpc(anon, 'payment_method_catalog')).find((m) => m.method === method);

before(async () => {
  manager = await login('252610000002');
  // A platform added from the backend, the way Betandyou, LuckyPari and Goldpari exist: a payment method only.
  await db.query(`ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS '${key}'`);
  await db.query(
    `INSERT INTO public.payment_methods (method, label, kind, color, initials, sort_order, enabled)
     VALUES ($1::public.order_method, 'Dyn Plat', 'platform', '#6B7280', 'DP', 900, true)`, [key]);
});
after(() => db.end());

test('a platform added as a payment method gets its connection record by itself, and shows in the Agent App', async () => {
  const { rows } = await db.query(`SELECT kind, adapter, legacy_manual, built_in, deleted_at FROM payment_integrations WHERE method_key = $1`, [key]);
  assert.equal(rows.length, 1);
  assert.deepEqual([rows[0].kind, rows[0].adapter, rows[0].legacy_manual, rows[0].built_in, rows[0].deleted_at], ['betting', 'cashdeskbot', true, false, null]);
  const p = await listed(key);
  assert.ok(p, 'it is in the Agent App list');
  assert.deepEqual([p.name, p.active, p.status, p.mode, p.builtIn], ['Dyn Plat', true, 'not_configured', 'manual', false]);
  // Doing it again changes nothing.
  await db.query(`SELECT private.adopt_betting_platform($1)`, [key]);
  assert.equal((await db.query(`SELECT count(*)::int AS n FROM payment_integrations WHERE method_key = $1`, [key])).rows[0].n, 1);
});

test('for customers nothing changes until the cash desk is connected: still on, still the manual deposit', async () => {
  const c = await catalogRow(key);
  assert.deepEqual([c.enabled, c.cashdesk, c.label], [true, false, 'Dyn Plat']);
});

test('its credentials can be saved on their own, without switching it off; the manual deposit stays until it is connected', async () => {
  const saved = await rpc(manager, 'manage_save_betting_platform', {
    p_method: key, p_login: 'dynlogin', p_password: 'dynpass1234', p_account_id: '123456', p_api_secret: 'dynhash-secret' });
  assert.deepEqual([saved.status, saved.mode, saved.active, saved.hasPassword, saved.hasApiSecret], ['not_tested', 'manual', true, true, true]);
  assert.ok(!JSON.stringify(saved).includes('dynpass1234') && !JSON.stringify(saved).includes('dynhash-secret'), 'secrets never come back');
  const c = await catalogRow(key);
  assert.deepEqual([c.enabled, c.cashdesk], [true, false]);
  // Its own switch, in both directions, without a test (it was live before it had a cash desk).
  assert.equal((await rpc(manager, 'manage_set_betting_platform_active', { p_method: key, p_active: false })).active, false);
  assert.equal((await catalogRow(key)).enabled, false);
  assert.equal((await rpc(manager, 'manage_set_betting_platform_active', { p_method: key, p_active: true })).active, true);
  const { rows } = await db.query(`SELECT action FROM audit_logs WHERE entity_id = $1 AND action LIKE 'betting_platform.%' ORDER BY created_at`, ['betting:' + key]);
  assert.ok(rows.some((r) => r.action === 'betting_platform.adopt'));
});

test('connected (credentials passed their test): it becomes a cash desk for customers, from the catalog alone', async () => {
  await db.query(`UPDATE payment_integrations SET tested_version = config_version, last_test_result = 'ok' WHERE method_key = $1 AND kind = 'betting'`, [key]);
  const p = await listed(key);
  assert.deepEqual([p.status, p.mode, p.active], ['connected', 'cashdesk', true]);
  assert.deepEqual([(await catalogRow(key)).cashdesk, (await catalogRow(key)).enabled], [true, true]);
  // Its credentials change: the new version must pass again, and until then it is manual again (it never stops working).
  await rpc(manager, 'manage_save_betting_platform', { p_method: key, p_password: 'another-pass-99' });
  const again = await listed(key);
  assert.deepEqual([again.status, again.mode, again.active], ['not_tested', 'manual', true]);
});

test('a platform made in the Agent App is dynamic too: listed, off, not offered to customers until tested; the built-in ones are unchanged', async () => {
  const made = await rpc(manager, 'manage_create_betting_platform', { p_name: `Dynamic Two ${seed}` });
  const p = await listed(made.method);
  assert.deepEqual([p.status, p.active, p.mode, p.builtIn], ['not_configured', false, 'cashdesk', false], 'a platform made here is a cash-desk platform by definition (off until it is connected)');
  assert.equal((await db.query(`SELECT legacy_manual FROM payment_integrations WHERE method_key = $1`, [made.method])).rows[0].legacy_manual, false);
  await assert.rejects(rpc(manager, 'manage_set_betting_platform_active', { p_method: made.method, p_active: true }), (e) => e.code === 'NOT_TESTED');
  const built = await listed('onexbet');
  assert.deepEqual([built.builtIn, built.mode], [true, 'cashdesk']);
  assert.equal((await catalogRow('onexbet')).cashdesk, true);
});

test('an unknown platform is still not found; only management can save credentials', async () => {
  await assert.rejects(rpc(manager, 'manage_save_betting_platform', {
    p_method: 'nosuchplatform', p_login: 'a', p_password: 'b', p_account_id: '1', p_api_secret: 'c' }), (e) => e.code === 'NOT_FOUND');
  const number = `61${String(seed).padStart(7, '0').slice(-7)}`;
  await db.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Platform Test', private.hash_password($2))`, [`252${number}`, PASSWORD]);
  const cu = await login(`252${number}`);
  const { error } = await cu.rpc('manage_save_betting_platform', { p_method: key, p_login: 'x', p_password: 'y', p_account_id: '1', p_api_secret: 'z' });
  assert.ok(error, 'a customer can not');
});
