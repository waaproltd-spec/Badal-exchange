// Betting platforms are dynamic (migrations/*_betting_platforms_dynamic.sql): a
// platform that exists as a payment method gets its connection record by itself,
// shows in the Agent App with its status, keeps its own ON/OFF and credentials,
// stays as it was for customers until its cash desk is connected, and then
// reaches the Customer App as a cash desk without any new release.
//
// Every scenario runs inside a transaction that is rolled back, as the signed-in
// manager (the functions check auth.uid()), so the other suites -- which count
// the platforms and companies of the shared test database -- never see it.
// Run with the other suites: npm test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const PASSWORD = 'ChangeMe123!';
const seed = Number(Date.now().toString().slice(-6));
const key = `dynplat${seed}`;
let managerId;

before(async () => {
  managerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  // An enum value with no row: harmless to everyone else (it can not be added inside a transaction and used there).
  await db.query(`ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS '${key}'`);
});
after(() => db.end());

/** Runs fn in a transaction (rolled back) as the given signed-in user. */
async function asUser(userId, fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('request.jwt.claims', $1, true), set_config('role', 'authenticated', true)`,
      [JSON.stringify({ sub: userId, role: 'authenticated', aud: 'authenticated' })]);
    await c.query(`RESET ROLE`).catch(() => {});
    return await fn({
      /** A function's JSON answer. */
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}
const addPlatform = (q) => q.query(
  `INSERT INTO public.payment_methods (method, label, kind, color, initials, sort_order, enabled)
   VALUES ($1::public.order_method, 'Dyn Plat', 'platform', '#6B7280', 'DP', 900, true)`, [key]);
const listed = async (tx, method) => (await tx.call('public.manage_betting_platforms()')).platforms.find((p) => p.method === method);
const catalogRow = async (tx, method) => (await tx.call('public.payment_method_catalog()')).find((m) => m.method === method);

test('a platform added as a payment method gets its connection record by itself and shows in the Agent App; for customers nothing changes yet', async () => {
  await asUser(managerId, async (tx) => {
    await addPlatform(tx);
    const { rows } = await tx.query(`SELECT kind, adapter, legacy_manual, built_in, deleted_at FROM payment_integrations WHERE method_key = $1`, [key]);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].kind, rows[0].adapter, rows[0].legacy_manual, rows[0].built_in, rows[0].deleted_at], ['betting', 'cashdeskbot', true, false, null]);
    const p = await listed(tx, key);
    assert.ok(p, 'it is in the Agent App list');
    assert.deepEqual([p.name, p.active, p.status, p.mode, p.builtIn], ['Dyn Plat', true, 'not_configured', 'manual', false]);
    // Doing it again changes nothing.
    await tx.query(`SELECT private.adopt_betting_platform($1)`, [key]);
    assert.equal((await tx.query(`SELECT count(*)::int AS n FROM payment_integrations WHERE method_key = $1`, [key])).rows[0].n, 1);
    // For customers: still on, still the manual deposit.
    const c = await catalogRow(tx, key);
    assert.deepEqual([c.enabled, c.cashdesk, c.label], [true, false, 'Dyn Plat']);
  });
});

test('its credentials are saved on their own without switching it off; its own switch works both ways; once connected it is a cash desk', async () => {
  await asUser(managerId, async (tx) => {
    await addPlatform(tx);
    const saved = await tx.call(
      `public.manage_save_betting_platform($1, NULL, 'dynlogin', 'dynpass1234', '123456', 'dynhash-secret')`, [key]);
    assert.deepEqual([saved.status, saved.mode, saved.active, saved.hasPassword, saved.hasApiSecret], ['not_tested', 'manual', true, true, true]);
    assert.ok(!JSON.stringify(saved).includes('dynpass1234') && !JSON.stringify(saved).includes('dynhash-secret'), 'secrets never come back');
    assert.deepEqual([(await catalogRow(tx, key)).enabled, (await catalogRow(tx, key)).cashdesk], [true, false]);

    // Its own switch, without a test (it was live before it had a cash desk).
    assert.equal((await tx.call(`public.manage_set_betting_platform_active($1, false)`, [key])).active, false);
    assert.equal((await catalogRow(tx, key)).enabled, false);
    assert.equal((await tx.call(`public.manage_set_betting_platform_active($1, true)`, [key])).active, true);

    // The customers' method list (what the deposit screen is built from) says the same as the catalog.
    const number = `61${String(seed).padStart(7, '0').slice(-7)}`;
    const { rows: [u] } = await tx.query(
      `INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Methods Test', private.hash_password($2)) RETURNING id`,
      [`252${number}`, PASSWORD]);
    const methodsFor = async () => {
      await tx.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: u.id, role: 'authenticated', aud: 'authenticated' })]);
      const list = await tx.call('public.customer_payment_methods()');
      await tx.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: managerId, role: 'authenticated', aud: 'authenticated' })]);
      return Object.fromEntries(list.map((m) => [m.method, m]));
    };
    let methods = await methodsFor();
    for (const m of Object.values(methods)) assert.equal(typeof m.cashdesk, 'boolean', `${m.method} says whether it is a cash desk`);
    assert.equal(methods.onexbet.cashdesk, true);
    assert.equal(methods.evc_plus.cashdesk, false);
    assert.equal(methods[key].cashdesk, false, 'not connected: the manual deposit');

    // Connected (its credentials passed their test): a cash desk for customers, from the data alone.
    await tx.query(`UPDATE payment_integrations SET tested_version = config_version, last_test_result = 'ok' WHERE method_key = $1 AND kind = 'betting'`, [key]);
    const p = await listed(tx, key);
    assert.deepEqual([p.status, p.mode, p.active], ['connected', 'cashdesk', true]);
    assert.equal((await catalogRow(tx, key)).cashdesk, true);
    methods = await methodsFor();
    assert.equal(methods[key].cashdesk, true, 'the deposit screen gets the code, with no app release');

    // Its credentials change: the new version must pass again, and until then it is manual again (it never stops working).
    await tx.call(`public.manage_save_betting_platform($1, NULL, NULL, 'another-pass-99', NULL, NULL)`, [key]);
    const again = await listed(tx, key);
    assert.deepEqual([again.status, again.mode, again.active], ['not_tested', 'manual', true]);
  });
});

test('the built-in platforms are unchanged: cash desks, listed as built in', async () => {
  await asUser(managerId, async (tx) => {
    const built = await listed(tx, 'onexbet');
    assert.deepEqual([built.builtIn, built.mode], [true, 'cashdesk']);
    assert.equal((await catalogRow(tx, 'onexbet')).cashdesk, true);
  });
});

test('an unknown platform is still not found', async () => {
  await assert.rejects(asUser(managerId, (tx) => tx.call(
    `public.manage_save_betting_platform('nosuchplatform', NULL, 'a', 'b', '1', 'c')`)), /Betting platform not found/);
});

test('a platform name can start with a digit (888starz admin, 1Win); it still needs a letter and 2 to 30 characters', async () => {
  await asUser(managerId, async (tx) => {
    const made = await tx.call(`public.manage_create_betting_platform($1, 'cashdeskbot')`, [`888 starz admin ${seed}`]);
    assert.equal(made.method, `888starzadmin${seed}`);
    assert.equal(made.status, 'not_configured');
    assert.equal(made.active, false, 'a new platform starts switched off');
    const p = await listed(tx, `888starzadmin${seed}`);
    assert.ok(p, 'it is in the Agent App list');
  });
  for (const bad of ['X', '12345', '--', '']) {
    await asUser(managerId, async (tx) => {
      await assert.rejects(tx.call(`public.manage_create_betting_platform($1, 'cashdeskbot')`, [bad]), (e) => e.hint === 'VALIDATION_ERROR' || /VALIDATION_ERROR/.test(`${e.hint}${e.message}`), bad);
    });
  }
});
