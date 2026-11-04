// Several accounts under one betting platform (migrations/*_betting_accounts.sql):
// two 888STARZ accounts with their own credentials, ON / OFF, Test connection
// and status; the admin selects the one in use; everything stays apart; and the
// platforms with one account (1XBET, DBbet, ...) work as they did.
//
// Every scenario runs in a transaction that is rolled back, as the signed-in
// manager (the functions check auth.uid()), so the other suites -- which count
// platforms and companies of the shared test database -- never see it.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const seed = Number(Date.now().toString().slice(-6));
const key = `multiacct${seed}`;
let managerId;
let customerId;

before(async () => {
  managerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  customerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000003'`)).rows[0].id;
  // A platform of its own for the "any platform, any number of accounts" scenario (an enum value with no row).
  await db.query(`ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS '${key}'`);
});
after(() => db.end());

/** Runs fn in a transaction (rolled back) as the given signed-in user. */
async function asUser(userId, fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    const claims = JSON.stringify({ sub: userId, role: 'authenticated', aud: 'authenticated' });
    await c.query(`SELECT set_config('request.jwt.claims', $1, true), set_config('role', 'authenticated', true)`, [claims]);
    await c.query(`RESET ROLE`).catch(() => {});
    let n = 0;
    const tx = {
      /** A function's JSON answer. */
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
      /** The same, as the service (the Edge Functions' own access). */
      service: async (sql, params = []) => {
        await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ role: 'service_role' })]);
        try {
          return (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r;
        } finally {
          await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [claims]);
        }
      },
      /** The error code a call is refused with. */
      refused: async (sql, params = []) => {
        const sp = `sp${n++}`;
        await c.query(`SAVEPOINT ${sp}`);
        try {
          await c.query(`SELECT ${sql} AS r`, params);
          return null;
        } catch (e) {
          return e.hint ?? e.message;
        } finally {
          await c.query(`ROLLBACK TO ${sp}`);
        }
      },
    };
    return await fn(tx);
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

const platform = async (tx, method) => (await tx.call('public.manage_betting_platforms()')).platforms.find((p) => p.method === method);
const addAccount = (tx, method, label = null) => tx.call('public.manage_add_betting_account($1, $2)', [method, label]);
const save = (tx, id, v) => tx.call('public.manage_save_betting_account($1, $2, $3, $4, $5, $6, $7)',
  [id, v.url ?? null, v.login ?? null, v.password ?? null, v.cashdesk ?? null, v.secret ?? null, v.apiKey ?? null]);
const passTest = async (tx, method, accountId) => {
  const cfg = await tx.service('public.betting_platform_config($1, true, $2)', [method, accountId]);
  return tx.service('public.betting_platform_record_test($1, $2, true, $3, NULL, $4)', [method, cfg.version, 'Connected: balance 100', accountId]);
};
const CRED1 = { login: 'cashier-one', password: 'pass-one-secret', cashdesk: '1111111', secret: 'hash-one-secret' };
const CRED2 = { login: 'cashier-two', password: 'pass-two-secret', cashdesk: '2222222', secret: 'hash-two-secret' };

test('a platform can have a second account: added under the same name, not a duplicate; the first one is untouched', async () => {
  await asUser(managerId, async (tx) => {
    const before = await platform(tx, '888starz');
    assert.equal(before.accounts.length, 1, 'one account, as always');
    assert.deepEqual([before.accounts[0].label, before.accounts[0].selected, before.accounts[0].enabled, before.accounts[0].status],
      ['Account 1', true, true, 'server']);
    const after = await addAccount(tx, '888starz');
    assert.equal(after.method, '888starz');
    assert.equal(after.name, before.name, 'the same platform, not another one');
    assert.equal(after.accounts.length, 2);
    const [one, two] = after.accounts;
    assert.deepEqual([one.label, one.selected, one.enabled, one.status], ['Account 1', true, true, 'server']);
    assert.deepEqual([two.label, two.selected, two.enabled, two.status], ['Account 2', false, false, 'not_configured']);
    assert.equal(after.selectedAccountId, one.id);
    // The platform's own switch, status and logo are as they were.
    assert.deepEqual([after.active, after.status, after.builtIn, after.mode], [before.active, before.status, true, 'cashdesk']);
    // Still one payment method of that name for customers.
    const catalog = await tx.call(`public.payment_method_catalog()`);
    assert.equal(catalog.filter((m) => m.method === '888starz').length, 1);
  });
});

test('each account has its own credentials, kept apart and never returned', async () => {
  await asUser(managerId, async (tx) => {
    let p = await addAccount(tx, '888starz');
    const [one, two] = p.accounts;
    p = await save(tx, one.id, CRED1);
    p = await save(tx, two.id, CRED2);
    const [a1, a2] = p.accounts;
    assert.deepEqual([a1.accountId, a2.accountId], ['1111111', '2222222'], 'own cashdesk IDs');
    assert.notEqual(a1.login, a2.login, 'own (masked) logins');
    assert.deepEqual([a1.hasPassword, a1.hasApiSecret, a2.hasPassword, a2.hasApiSecret], [true, true, true, true]);
    // The apps never see a secret.
    const text = JSON.stringify(p);
    for (const secret of [CRED1.password, CRED1.secret, CRED2.password, CRED2.secret, CRED1.login, CRED2.login]) {
      assert.equal(text.includes(secret), false, `${secret} must not be returned`);
    }
    // The service reads each account's own credentials.
    const c1 = await tx.service('public.betting_platform_config($1, true, $2)', ['888starz', one.id]);
    const c2 = await tx.service('public.betting_platform_config($1, true, $2)', ['888starz', two.id]);
    assert.deepEqual([c1.cashdeskid, c1.login, c1.cashierpass, c1.hash], ['1111111', CRED1.login, CRED1.password, CRED1.secret]);
    assert.deepEqual([c2.cashdeskid, c2.login, c2.cashierpass, c2.hash], ['2222222', CRED2.login, CRED2.password, CRED2.secret]);
    assert.notEqual(c1.version, c2.version);
    // Separate vault entries.
    const { rows } = await tx.query(`SELECT count(DISTINCT id)::int AS n FROM vault.secrets WHERE name LIKE 'betting:888starz:%'`);
    assert.equal(rows[0].n, 6, 'login, password and hash each');
    // Changing one account does not touch the other.
    await save(tx, two.id, { password: 'pass-two-changed' });
    const again = await tx.service('public.betting_platform_config($1, true, $2)', ['888starz', one.id]);
    assert.equal(again.cashierpass, CRED1.password);
    assert.equal(again.version, c1.version);
  });
});

test('each account has its own Test connection and status; ON needs a passed test', async () => {
  await asUser(managerId, async (tx) => {
    let p = await addAccount(tx, '888starz');
    const [one, two] = p.accounts;
    await save(tx, one.id, CRED1);
    p = await save(tx, two.id, CRED2);
    assert.deepEqual(p.accounts.map((a) => a.status), ['not_tested', 'not_tested']);
    // Not switched on before it passed.
    assert.equal(await tx.refused('public.manage_set_betting_account_enabled($1, true)', [two.id]), 'NOT_TESTED');
    // A failed test on account 2 says so there only.
    const cfg2 = await tx.service('public.betting_platform_config($1, true, $2)', ['888starz', two.id]);
    p = await tx.service(`public.betting_platform_record_test($1, $2, false, 'rejected: invalid sign', NULL, $3)`, ['888starz', cfg2.version, two.id]);
    assert.deepEqual(p.accounts.map((a) => a.status), ['not_tested', 'error']);
    assert.match(p.accounts[1].lastMessage, /invalid sign/);
    assert.equal(p.accounts[0].lastMessage, null, 'account 1 has no result of that test');
    // A passed one.
    p = await passTest(tx, '888starz', two.id);
    assert.deepEqual(p.accounts.map((a) => a.status), ['not_tested', 'connected']);
    assert.ok(p.accounts[1].lastOkAt);
    assert.equal(p.accounts[0].lastOkAt, null);
    // Its own ON / OFF.
    p = await tx.call('public.manage_set_betting_account_enabled($1, true)', [two.id]);
    assert.deepEqual(p.accounts.map((a) => a.enabled), [true, true]);
    p = await tx.call('public.manage_set_betting_account_enabled($1, false)', [two.id]);
    assert.deepEqual(p.accounts.map((a) => a.enabled), [true, false]);
    // Saving other credentials needs a new test: the account is switched off again.
    p = await passTest(tx, '888starz', two.id);
    p = await tx.call('public.manage_set_betting_account_enabled($1, true)', [two.id]);
    p = await save(tx, two.id, { secret: 'a-new-hash' });
    assert.deepEqual([p.accounts[1].status, p.accounts[1].enabled], ['not_tested', false]);
  });
});

test('the admin selects the account in use; orders go through it; the other can not be mixed up with it', async () => {
  await asUser(managerId, async (tx) => {
    let p = await addAccount(tx, '888starz');
    const [one, two] = p.accounts;
    await save(tx, one.id, CRED1);
    await save(tx, two.id, CRED2);
    await passTest(tx, '888starz', one.id);
    await passTest(tx, '888starz', two.id);
    // The platform uses the selected account (Account 1) until another is selected.
    let live = await tx.service('public.betting_platform_config($1, false)', ['888starz']);
    assert.equal(live.cashdeskid, '1111111');
    assert.equal(live.accountRowId, one.id);
    // An account that is off can not be selected.
    assert.equal(await tx.refused('public.manage_select_betting_account($1)', [two.id]), 'ACCOUNT_OFF');
    await tx.call('public.manage_set_betting_account_enabled($1, true)', [two.id]);
    p = await tx.call('public.manage_select_betting_account($1)', [two.id]);
    assert.equal(p.selectedAccountId, two.id);
    assert.deepEqual(p.accounts.map((a) => a.selected), [false, true]);
    // Now it is Account 2 that serves orders; the platform's own fields follow it.
    live = await tx.service('public.betting_platform_config($1, false)', ['888starz']);
    assert.deepEqual([live.cashdeskid, live.accountRowId, live.accountLabel], ['2222222', two.id, 'Account 2']);
    assert.equal(p.accountId, '2222222', 'the platform shows the account in use');
    assert.equal(p.status, 'connected');
    // Account 1 is still there, still tested, usable on request.
    const first = await tx.service('public.betting_platform_config($1, false, $2)', ['888starz', one.id]);
    assert.equal(first.cashdeskid, '1111111');
    // Selecting the one in use again changes nothing.
    p = await tx.call('public.manage_select_betting_account($1)', [two.id]);
    assert.equal(p.selectedAccountId, two.id);
    // The account in use can not be switched off while the platform is on, nor removed.
    assert.equal(p.active, true);
    assert.equal(await tx.refused('public.manage_set_betting_account_enabled($1, false)', [two.id]), 'ACCOUNT_IN_USE');
    assert.equal(await tx.refused(`public.manage_remove_betting_account($1, 'not needed')`, [two.id]), 'ACCOUNT_IN_USE');
  });
});

test('every order records the account that handled it, so transactions stay apart', async () => {
  await asUser(managerId, async (tx) => {
    const order = (await tx.query(`SELECT id FROM orders WHERE method = '888starz' ORDER BY created_at LIMIT 1`)).rows[0];
    if (!order) return; // a fresh database has no 888STARZ order to mark
    let p = await addAccount(tx, '888starz');
    const [one, two] = p.accounts;
    await tx.query(`UPDATE orders SET betting_account_id = NULL WHERE id = $1`, [order.id]);
    await tx.service('public.platform_record_account($1)', [order.id]);
    let { rows } = await tx.query(`SELECT betting_account_id FROM orders WHERE id = $1`, [order.id]);
    assert.equal(rows[0].betting_account_id, one.id, 'the selected account when none is given');
    // Recorded once: a later call does not move it.
    await tx.service('public.platform_record_account($1, $2)', [order.id, two.id]);
    ({ rows } = await tx.query(`SELECT betting_account_id FROM orders WHERE id = $1`, [order.id]));
    assert.equal(rows[0].betting_account_id, one.id);
    p = await platform(tx, '888starz');
    assert.equal(p.accounts[0].orders, 1);
    assert.equal(p.accounts[1].orders, 0);
  });
});

test('an account can be renamed and removed; its secrets go, the others stay; names are per platform', async () => {
  await asUser(managerId, async (tx) => {
    let p = await addAccount(tx, '888starz', 'Cashier North');
    assert.deepEqual(p.accounts.map((a) => a.label), ['Account 1', 'Cashier North']);
    assert.equal(await tx.refused('public.manage_add_betting_account($1, $2)', ['888starz', 'cashier north']), 'ACCOUNT_EXISTS');
    const north = p.accounts[1];
    p = await tx.call('public.manage_rename_betting_account($1, $2)', [north.id, 'Account 2']);
    assert.equal(p.accounts[1].label, 'Account 2');
    assert.equal(await tx.refused('public.manage_rename_betting_account($1, $2)', [p.accounts[0].id, 'account 2']), 'ACCOUNT_EXISTS');
    // Another platform has its own "Account 2".
    const other = await addAccount(tx, 'melbet', 'Account 2');
    assert.deepEqual(other.accounts.map((a) => a.label), ['Account 1', 'Account 2']);
    // Remove it.
    await save(tx, north.id, CRED2);
    const before = (await tx.query(`SELECT count(*)::int AS n FROM vault.secrets WHERE name LIKE $1`, [`betting:888starz:${north.id}:%`])).rows[0].n;
    assert.equal(before, 3);
    assert.equal(await tx.refused(`public.manage_remove_betting_account($1, 'x')`, [north.id]), 'VALIDATION_ERROR', 'a reason is needed');
    p = await tx.call(`public.manage_remove_betting_account($1, 'closed the cash desk')`, [north.id]);
    assert.deepEqual(p.accounts.map((a) => a.label), ['Account 1']);
    const after = (await tx.query(`SELECT count(*)::int AS n FROM vault.secrets WHERE name LIKE $1`, [`betting:888starz:${north.id}:%`])).rows[0].n;
    assert.equal(after, 0, 'its credentials are deleted');
    // The name can be used again.
    p = await addAccount(tx, '888starz', 'Cashier North');
    assert.equal(p.accounts.length, 2);
  });
});

test('any platform can have any number of accounts; the platform switch is its own; a connected selected account makes it a cash desk', async () => {
  await asUser(managerId, async (tx) => {
    await tx.query(`INSERT INTO public.payment_methods (method, label, kind, color, initials, sort_order, enabled)
                    VALUES ($1::public.order_method, 'Multi Acct', 'platform', '#6B7280', 'MA', 900, true)`, [key]);
    let p = await platform(tx, key);
    assert.deepEqual(p.accounts.map((a) => [a.label, a.selected, a.enabled]), [['Account 1', true, true]], 'a platform made by hand gets its Account 1');
    assert.equal(p.mode, 'manual', 'for customers nothing changes until a cash desk is connected');
    for (let n = 2; n <= 4; n++) p = await addAccount(tx, key);
    assert.deepEqual(p.accounts.map((a) => a.label), ['Account 1', 'Account 2', 'Account 3', 'Account 4']);
    assert.equal(p.accounts.filter((a) => a.selected).length, 1, 'exactly one account is in use');
    // The platform's own switch.
    p = await tx.call('public.manage_set_betting_platform_active($1, false)', [key]);
    assert.equal(p.active, false);
    assert.equal(p.accounts.length, 4);
    // Account 3 is connected and selected: now the platform is a cash desk for customers.
    const three = p.accounts[2];
    await save(tx, three.id, CRED1);
    await passTest(tx, key, three.id);
    await tx.call('public.manage_set_betting_account_enabled($1, true)', [three.id]);
    p = await tx.call('public.manage_select_betting_account($1)', [three.id]);
    assert.equal(p.selectedAccountId, three.id);
    assert.equal(p.mode, 'cashdesk');
    const live = await tx.service('public.betting_platform_config($1, false)', [key]);
    assert.equal(live.cashdeskid, '1111111');
    // Account 1 (no cash desk) can be removed now that it is not in use.
    p = await tx.call(`public.manage_remove_betting_account($1, 'replaced')`, [p.accounts[0].id]);
    assert.deepEqual(p.accounts.map((a) => a.label), ['Account 2', 'Account 3', 'Account 4']);
    // Removing the platform removes every account's credentials.
    await tx.call(`public.manage_delete_betting_platform($1, 'test')`, [key]);
    const { rows } = await tx.query(`SELECT count(*)::int AS n FROM betting_accounts WHERE method_key = $1 AND removed_at IS NULL`, [key]);
    assert.equal(rows[0].n, 0);
    assert.equal((await tx.query(`SELECT count(*)::int AS n FROM vault.secrets WHERE name LIKE $1`, [`betting:${key}:%`])).rows[0].n, 0);
  });
});

test('only a manager can manage accounts; the other platforms keep working as before', async () => {
  await asUser(customerId, async (tx) => {
    assert.equal(await tx.refused(`public.manage_add_betting_account('888starz', NULL)`), 'FORBIDDEN');
    assert.equal(await tx.refused(`public.manage_select_betting_account(gen_random_uuid())`), 'FORBIDDEN');
    assert.equal(await tx.refused(`public.manage_set_betting_account_enabled(gen_random_uuid(), true)`), 'FORBIDDEN');
    assert.equal(await tx.refused(`public.manage_remove_betting_account(gen_random_uuid(), 'x')`), 'FORBIDDEN');
    assert.equal(await tx.refused(`public.manage_betting_platforms()`), 'FORBIDDEN');
  });
  await asUser(managerId, async (tx) => {
    const list = await tx.call('public.manage_betting_platforms()');
    for (const method of ['onexbet', 'dbbet', 'winwin', 'betwinner', 'melbet', '888starz']) {
      const p = list.platforms.find((x) => x.method === method);
      assert.ok(p, method);
      assert.equal(p.accounts.length, 1, `${method} has its one account`);
      assert.equal(p.accounts[0].selected, true);
      assert.equal(p.builtIn, true);
      assert.ok(['server', 'connected', 'not_tested', 'error'].includes(p.status));
    }
    // Nothing is created by listing, and the customers' list is the same.
    const catalog = await tx.call('public.payment_method_catalog()');
    assert.equal(catalog.filter((m) => m.method === 'onexbet').length, 1);
    // A made-up account is not found.
    assert.equal(await tx.refused(`public.manage_select_betting_account(gen_random_uuid())`), 'NOT_FOUND');
    assert.equal(await tx.refused(`public.manage_add_betting_account('nosuchplatform', NULL)`), 'NOT_FOUND');
  });
});
