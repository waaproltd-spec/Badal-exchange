// Betting Platform Management (migrations/*_betting_platforms.sql): adding a
// platform, required fields per adapter, credentials kept in Vault and
// never returned, Test connection gating real use and switching on, removing
// while keeping history, and the built-in platforms unchanged. Run with the
// other suites: npm test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const opts = { auth: { persistSession: false, autoRefreshToken: false } };
const service = SERVICE_KEY ? createClient(URL, SERVICE_KEY, opts) : null;
const check = (name, fn) => test(name, { skip: !SERVICE_KEY && 'set SUPABASE_SERVICE_ROLE_KEY' }, fn);

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
async function rejects(promise, code) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `expected ${code}, got ${e.code}: ${e.message}`);
    return true;
  });
}

const seed = Date.now().toString().slice(-7);
let manager;
let customer;
const SECRET = `hash-${seed}-do-not-leak`;
const PASS = `cashier-${seed}-secret`;
const platform = async (method) => (await rpc(manager, 'manage_betting_platforms')).platforms.find((p) => p.method === method);
const config = (method, forTest = false) => rpc(service, 'betting_platform_config', { p_method: method, p_for_test: forTest });

before(async () => {
  manager = await login('252610000002');
  customer = await login('252610000003');
});
after(() => db.end());

let method;
check('adding a platform: validated, its own payment method, switched off', async () => {
  await rejects(rpc(manager, 'manage_create_betting_platform', { p_name: 'X', p_adapter: 'cashdeskbot' }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'manage_create_betting_platform', { p_name: `Other API ${seed}`, p_adapter: 'someapi' }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'manage_create_betting_platform', { p_name: 'MELBET' }), 'PLATFORM_EXISTS');
  const p = await rpc(manager, 'manage_create_betting_platform', { p_name: `Test Bet ${seed}`, p_adapter: 'cashdeskbot' });
  method = p.method;
  assert.equal(method, `testbet${seed}`);
  const listed = await platform(method);
  assert.equal(listed.status, 'not_configured');
  assert.equal(listed.active, false);
  assert.equal(listed.builtIn, false);
  await rejects(rpc(customer, 'manage_create_betting_platform', { p_name: `Nope ${seed}` }), 'FORBIDDEN');
});

check('required fields of the adapter are checked; secrets are kept and never returned or logged', async () => {
  await rejects(rpc(manager, 'manage_save_betting_platform', { p_method: method, p_login: 'cashier1' }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'manage_save_betting_platform', {
    p_method: method, p_login: 'cashier1', p_password: PASS, p_account_id: '12ab', p_api_secret: SECRET }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'manage_save_betting_platform', {
    p_method: method, p_api_url: 'http://insecure', p_login: 'cashier1', p_password: PASS, p_account_id: '1198475', p_api_secret: SECRET }),
  'VALIDATION_ERROR');
  const saved = await rpc(manager, 'manage_save_betting_platform', {
    p_method: method, p_login: 'cashier1', p_password: PASS, p_account_id: '1198475', p_api_secret: SECRET });
  assert.equal(saved.status, 'not_tested');
  assert.equal(saved.accountId, '1198475');
  assert.equal(saved.login, 'ca••••r1', 'the login is masked');
  assert.equal(saved.hasPassword, true);
  assert.equal(saved.hasApiSecret, true);
  const everything = JSON.stringify(await rpc(manager, 'manage_betting_platforms'));
  assert.ok(!everything.includes(PASS) && !everything.includes(SECRET), 'no secret comes back to the app');
  const { rows } = await db.query(`SELECT after_json::text AS a FROM audit_logs WHERE entity_id = $1 ORDER BY created_at`, [`betting:${method}`]);
  assert.ok(rows.length >= 2);
  assert.ok(rows.every((r) => !r.a.includes(PASS) && !r.a.includes(SECRET)), 'the audit log says which fields changed, never their values');
  // Kept in Vault, readable by the server only.
  const c = await config(method, true);
  assert.equal(c.cashierpass, PASS);
  assert.equal(c.hash, SECRET);
  assert.equal(c.baseUrl, 'https://partners.servcul.com/CashdeskBotAPI');
  await assert.rejects(rpc(manager, 'betting_platform_config', { p_method: method, p_for_test: true }));
  // An empty secret keeps the saved one.
  await rpc(manager, 'manage_save_betting_platform', { p_method: method, p_account_id: '1198475' });
  assert.equal((await config(method, true)).cashierpass, PASS);
});

check('untested credentials are never used and cannot be switched on; a passed test allows both', async () => {
  assert.equal(await config(method), null, 'not for real orders before a test');
  await rejects(rpc(manager, 'manage_set_betting_platform_active', { p_method: method, p_active: true }), 'NOT_TESTED');
  await rejects(rpc(manager, 'manage_set_payment_method', { p_method: method, p_enabled: true }), 'NOT_TESTED',
    'nor from Payment Methods');
  const v = (await config(method, true)).version;
  // A failed test: error with the provider's answer.
  let p = await rpc(service, 'betting_platform_record_test', { p_method: method, p_version: v, p_ok: false, p_message: 'CashdeskBot rejected the request: invalid or missing "sign" signature.' });
  assert.equal(p.status, 'error');
  assert.match(p.lastMessage, /invalid or missing "sign"/);
  await rejects(rpc(manager, 'manage_set_betting_platform_active', { p_method: method, p_active: true }), 'NOT_TESTED');
  // A passed one.
  p = await rpc(service, 'betting_platform_record_test', { p_method: method, p_version: v, p_ok: true, p_message: 'Connected: balance 100' });
  assert.equal(p.status, 'connected');
  assert.ok(p.lastOkAt);
  assert.equal((await config(method)).cashdeskid, '1198475', 'now used for real orders');
  p = await rpc(manager, 'manage_set_betting_platform_active', { p_method: method, p_active: true });
  assert.equal(p.active, true);
  const catalog = await rpc(customer, 'payment_method_catalog');
  assert.equal(catalog.find((m) => m.method === method)?.cashdesk, true, 'the Customer App sees a cash desk');
  const { rows } = await db.query(`SELECT private.is_cashdesk_method($1::order_method) AS c`, [method]);
  assert.equal(rows[0].c, true);
});

check('changing a credential needs a new test: switched off, not used until it passes; a stale result proves nothing', async () => {
  const old = (await config(method, true)).version;
  const p = await rpc(manager, 'manage_save_betting_platform', { p_method: method, p_password: `${PASS}-2` });
  assert.equal(p.status, 'not_tested');
  assert.equal(p.active, false, 'switched off until tested again');
  assert.equal(await config(method), null);
  await rpc(service, 'betting_platform_record_test', { p_method: method, p_version: old, p_ok: true, p_message: 'old' });
  assert.equal((await platform(method)).status, 'not_tested', 'a result for the previous credentials does not count');
});

check('built-in platforms: unchanged, on their server secrets, cannot be removed', async () => {
  const melbet = await platform('melbet');
  assert.equal(melbet.builtIn, true);
  assert.ok(['server', 'connected', 'not_tested', 'error'].includes(melbet.status));
  await rejects(rpc(manager, 'manage_delete_betting_platform', { p_method: 'melbet', p_reason: 'test' }), 'BUILT_IN');
  for (const m of ['888starz', 'onexbet', 'winwin', 'betwinner', 'dbbet', 'betjam', 'betongame', 'melbet']) {
    const { rows } = await db.query(`SELECT private.is_cashdesk_method($1::order_method) AS c`, [m]);
    assert.equal(rows[0].c, true, `${m} is still a cash desk`);
  }
  if (melbet.status === 'server') {
    // On / off works as before for a platform on server secrets.
    const was = melbet.active;
    await rpc(manager, 'manage_set_betting_platform_active', { p_method: 'melbet', p_active: !was });
    await rpc(manager, 'manage_set_betting_platform_active', { p_method: 'melbet', p_active: was });
  }
  const integrations = await rpc(manager, 'admin_payment_integrations');
  assert.ok(integrations.every((i) => !String(i.provider).startsWith('betting:')), 'Payment Integrations is unchanged');
});

check('removing a platform: a reason, off and hidden, secrets deleted, its orders kept', async () => {
  const { rows: [u] } = await db.query(`SELECT id FROM users WHERE phone = '252610000003'`);
  await db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
     VALUES ($1, $2, 'deposit', $3::order_method, 'completed', 100, 1, 100, 0)`, [`EXBP${seed}`, u.id, method]);
  await rejects(rpc(manager, 'manage_delete_betting_platform', { p_method: method, p_reason: '' }), 'VALIDATION_ERROR');
  await rpc(manager, 'manage_delete_betting_platform', { p_method: method, p_reason: 'Contract ended' });
  assert.equal(await platform(method), undefined, 'hidden');
  assert.ok(!(await rpc(customer, 'payment_method_catalog')).some((m) => m.method === method), 'gone from the Customer App');
  assert.equal(await config(method, true), null, 'credentials deleted');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM orders WHERE order_code = $1`, [`EXBP${seed}`]);
  assert.equal(rows[0].n, 1, 'its orders are kept');
  await rejects(rpc(manager, 'manage_set_betting_platform_active', { p_method: method, p_active: true }), 'NOT_FOUND');
  await rejects(rpc(manager, 'manage_set_payment_method', { p_method: method, p_enabled: true }), 'NOT_FOUND');
  assert.ok(!(await rpc(manager, 'manage_payment_methods')).some((m) => m.method === method), 'gone from Payment Methods');
});

check('a name added and removed before it was ever saved can be added again; names in use and removed payment methods stay refused', async () => {
  const name = `Re Add ${seed}`;
  const key = `readd${seed}`;
  const first = await rpc(manager, 'manage_create_betting_platform', { p_name: name, p_adapter: 'cashdeskbot' });
  assert.equal(first.method, key);
  // Added and still there: the name is taken.
  await rejects(rpc(manager, 'manage_create_betting_platform', { p_name: name }), 'PLATFORM_EXISTS');
  await rpc(manager, 'manage_delete_betting_platform', { p_method: key, p_reason: 'Added by mistake' });
  assert.equal(await platform(key), undefined, 'removed: hidden');
  // Removed before it was saved (no payment method, no order): it can be added again.
  const again = await rpc(manager, 'manage_create_betting_platform', { p_name: name, p_adapter: 'cashdeskbot' });
  assert.equal(again.method, key);
  const listed = await platform(key);
  assert.equal(listed.status, 'not_configured');
  assert.equal(listed.active, false);
  assert.equal(listed.hasPassword, false);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM payment_integrations WHERE provider = $1`, [`betting:${key}`]);
  assert.equal(rows[0].n, 1, 'one row, revived');
  // Still refused: a built-in, and the platform removed earlier that had become a payment method.
  await rejects(rpc(manager, 'manage_create_betting_platform', { p_name: 'MELBET' }), 'PLATFORM_EXISTS');
  await rejects(rpc(manager, 'manage_create_betting_platform', { p_name: `Test Bet ${seed}` }), 'PLATFORM_EXISTS');
  await rejects(rpc(customer, 'manage_create_betting_platform', { p_name: name }), 'FORBIDDEN');
  await rpc(manager, 'manage_delete_betting_platform', { p_method: key, p_reason: 'Test cleanup' });
});

const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

check('a logo for an added platform: validated, shown in the Customer App catalog, removable; built-ins keep theirs', async () => {
  const p = await rpc(manager, 'manage_create_betting_platform', { p_name: `Logo Bet ${seed}`, p_adapter: 'cashdeskbot' });
  const key = p.method;
  assert.equal((await platform(key)).logo, null, 'none at first');
  const saved = await rpc(manager, 'manage_save_betting_platform', {
    p_method: key, p_login: 'cashier1', p_password: PASS, p_account_id: '1198475', p_api_secret: SECRET });
  assert.equal(saved.status, 'not_tested');

  // Only a small PNG or JPEG.
  await rejects(rpc(manager, 'manage_set_betting_platform_logo', { p_method: key, p_logo: 'not base64!!' }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'manage_set_betting_platform_logo', {
    p_method: key, p_logo: Buffer.from('this is text, not a picture').toString('base64') }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'manage_set_betting_platform_logo', {
    p_method: key, p_logo: Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), Buffer.alloc(70000)]).toString('base64') }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'manage_set_betting_platform_logo', { p_method: 'melbet', p_logo: PNG }), 'BUILT_IN');
  await rejects(rpc(manager, 'manage_set_betting_platform_logo', { p_method: 'nosuchplatform', p_logo: PNG }), 'NOT_FOUND');
  await rejects(rpc(customer, 'manage_set_betting_platform_logo', { p_method: key, p_logo: PNG }), 'FORBIDDEN');
  assert.equal((await platform(key)).logo, null, 'nothing changed');

  const set = await rpc(manager, 'manage_set_betting_platform_logo', { p_method: key, p_logo: PNG });
  assert.equal(set.logo, PNG);
  assert.equal(set.status, 'not_tested', 'credentials and tests are untouched');
  assert.equal((await platform(key)).logo, PNG);
  // The Customer App's catalog carries it (and only this platform's).
  const catalog = await rpc(customer, 'payment_method_catalog');
  assert.equal(catalog.find((m) => m.method === key).logo, PNG);
  assert.equal(catalog.find((m) => m.method === 'melbet').logo, null);
  const { rows } = await db.query(`SELECT after_json::text AS a FROM audit_logs WHERE entity_id = $1 AND action = 'betting_platform.logo'`, [`betting:${key}`]);
  assert.equal(rows.length, 1, 'audited');
  assert.ok(!rows[0].a.includes(PNG), 'the picture itself is not copied into the audit log');

  const cleared = await rpc(manager, 'manage_set_betting_platform_logo', { p_method: key, p_logo: '' });
  assert.equal(cleared.logo, null);
  assert.equal((await rpc(customer, 'payment_method_catalog')).find((m) => m.method === key).logo, null);
  await rpc(manager, 'manage_set_betting_platform_logo', { p_method: key, p_logo: PNG });
  await rpc(manager, 'manage_delete_betting_platform', { p_method: key, p_reason: 'Logo test cleanup' });
  assert.ok(!(await rpc(customer, 'payment_method_catalog')).some((m) => m.method === key), 'a removed platform is gone, logo and all');
});
