// Block / Unblock customers (migrations/*_customer_blocking.sql): the action with its reason, the
// history (who, when, why), the counters and the Blocked tab, and the enforcement: a blocked
// customer's login is banned and its sessions are gone, and every customer API call is refused
// until the customer is unblocked.
//
// Scenarios run in a transaction that is rolled back, as the signed-in user. The real sign-in
// check needs the real Auth service (CI); without it that scenario is skipped.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
let managerId; // an agent allowed to manage settings
let customerId;
let plainAgentId; // an agent without that permission
let otherCustomerId;
let adminId;

before(async () => {
  managerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  customerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000003'`)).rows[0].id;
  otherCustomerId = (await db.query(`SELECT id FROM users WHERE role = 'customer' AND id <> $1 AND status = 'active' ORDER BY created_at LIMIT 1`, [customerId])).rows[0]?.id;
  adminId = (await db.query(`SELECT id FROM users WHERE role = 'admin' LIMIT 1`)).rows[0]?.id;
  plainAgentId = (await db.query(
    `SELECT u.id FROM users u LEFT JOIN agent_profiles p ON p.user_id = u.id
     WHERE u.role = 'agent' AND u.status = 'active' AND NOT ('manage_settings' = ANY (COALESCE(p.responsibilities, '{}'))) LIMIT 1`)).rows[0]?.id;
});
after(() => db.end());

async function asUser(userId, fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    const claims = JSON.stringify({ sub: userId, role: 'authenticated', aud: 'authenticated' });
    await c.query(`SELECT set_config('request.jwt.claims', $1, true), set_config('role', 'authenticated', true)`, [claims]);
    await c.query(`RESET ROLE`).catch(() => {});
    let n = 0;
    const tx = {
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
      as: (id) => c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: id, role: 'authenticated', aud: 'authenticated' })]),
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

const block = (tx, reason = 'Fraud: used a stolen account', id = customerId) => tx.call('public.manage_set_customer_blocked($1,true,$2)', [id, reason]);
const unblock = (tx, reason = null, id = customerId) => tx.call('public.manage_set_customer_blocked($1,false,$2)', [id, reason]);
const overview = (tx) => tx.call('public.agent_customer_overview()');

test('blocking (with or without a reason) blocks the customer, and says so everywhere', async () => {
  await asUser(managerId, async (tx) => {
    assert.equal(await tx.refused('public.manage_set_customer_blocked($1,true,$2)', [customerId, 'x'.repeat(301)]), 'VALIDATION_ERROR', 'at most 300 characters');
    const before = await overview(tx);
    const r = await block(tx);
    assert.equal(r.status, 'blocked');
    assert.equal(r.blockedReason, 'Fraud: used a stolen account');
    assert.ok(r.blockedAt);
    assert.equal(r.history.length, 1);
    assert.equal(r.history[0].action, 'blocked');
    assert.equal(r.history[0].byRole, 'agent');
    assert.equal((await tx.query(`SELECT status FROM public.users WHERE id = $1`, [customerId])).rows[0].status, 'disabled');
    // The counters follow at once: Blocked +1, Active -1, Total unchanged.
    const after = await overview(tx);
    assert.equal(after.blocked, before.blocked + 1);
    assert.equal(after.active, before.active - 1);
    assert.equal(after.total, before.total);
    // The Blocked tab lists them, the Active tab does not.
    const blockedTab = (await tx.call(`public.agent_customers(NULL, 'blocked', 'newest', 100, 0)`));
    const activeTab = (await tx.call(`public.agent_customers(NULL, 'active', 'newest', 100, 0)`));
    const ids = (rows) => rows.map((x) => x.id);
    assert.ok(ids(blockedTab.customers ?? blockedTab).includes(customerId));
    assert.ok(!ids(activeTab.customers ?? activeTab).includes(customerId));
    // Blocking twice is refused (once each way).
    assert.equal(await tx.refused('public.manage_set_customer_blocked($1,true,$2)', [customerId, 'again']), 'ALREADY_BLOCKED');
  });
});

test('a blocked customer: login banned, sessions gone, every customer call refused; unblocking restores it', async () => {
  await asUser(managerId, async (tx) => {
    await tx.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, 500) ON CONFLICT (customer_id) DO NOTHING`, [customerId]);
    const hasAuth = (await tx.query(`SELECT count(*)::int AS n FROM auth.users WHERE id = $1`, [customerId])).rows[0].n;
    await block(tx);
    if (hasAuth) {
      const a = (await tx.query(`SELECT banned_until FROM auth.users WHERE id = $1`, [customerId])).rows[0];
      assert.ok(a.banned_until && new Date(a.banned_until) > new Date('2900-01-01'), 'the login is banned');
      assert.equal((await tx.query(`SELECT count(*)::int AS n FROM auth.sessions WHERE user_id = $1`, [customerId])).rows[0].n, 0, 'signed out everywhere');
    }
    // A token the customer still holds is useless: the API refuses every call.
    await tx.as(customerId);
    for (const sql of ['public.customer_tips()', 'public.customer_bonus()', 'public.customer_tip_purchases()', 'public.customer_payment_methods()']) {
      assert.equal(await tx.refused(sql), 'FORBIDDEN', sql);
    }
    assert.equal(await tx.refused('public.customer_buy_tip($1, NULL)', ['00000000-0000-0000-0000-000000000000']), 'FORBIDDEN');
    // Unblock: the customer is back.
    await tx.as(managerId);
    const r = await unblock(tx, 'Verified, it was a mistake');
    assert.equal(r.status, 'active');
    assert.equal(r.blockedReason, null);
    assert.equal(r.history.length, 2);
    assert.deepEqual(r.history.map((h) => h.action), ['unblocked', 'blocked']);
    if (hasAuth) {
      assert.equal((await tx.query(`SELECT banned_until FROM auth.users WHERE id = $1`, [customerId])).rows[0].banned_until, null);
    }
    await tx.as(customerId);
    assert.ok(Array.isArray((await tx.call('public.customer_tips()')).tips));
    await tx.as(managerId);
    assert.equal(await tx.refused('public.manage_set_customer_blocked($1,false,NULL)', [customerId]), 'NOT_BLOCKED');
  });
});

test('the reason is optional: a block without one is recorded as such', async () => {
  await asUser(managerId, async (tx) => {
    const r = await tx.call('public.manage_set_customer_blocked($1,true,NULL)', [customerId]);
    assert.equal(r.status, 'blocked');
    assert.equal(r.blockedReason, null);
    assert.equal(r.history[0].reason, null);
    const ws = await tx.call('public.manage_set_customer_blocked($1,false,$2)', [customerId, '   ']);
    assert.equal(ws.history[0].reason, null, 'blank is no reason');
  });
});

test('blocking closes the door to new activity and touches nothing else: balance, orders, ledger, other customers', async () => {
  await asUser(managerId, async (tx) => {
    await tx.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, 1234) ON CONFLICT (customer_id) DO UPDATE SET available_cents = 1234`, [customerId]);
    const snapshot = async () => ({
      wallet: (await tx.query(`SELECT available_cents, pending_cents, total_deposit_cents, total_withdraw_cents FROM public.wallets WHERE customer_id = $1`, [customerId])).rows[0],
      orders: (await tx.query(`SELECT id, status, amount_cents FROM public.orders WHERE customer_id = $1 ORDER BY id`, [customerId])).rows,
      ledger: (await tx.query(`SELECT l.id, l.entry_type, l.amount_cents FROM public.ledger_entries l JOIN public.wallets w ON w.id = l.wallet_id WHERE w.customer_id = $1 ORDER BY l.id`, [customerId])).rows,
    });
    const other = otherCustomerId ? (await tx.query(`SELECT status FROM public.users WHERE id = $1`, [otherCustomerId])).rows[0].status : null;
    const before = await snapshot();
    await block(tx);
    assert.deepEqual(await snapshot(), before, 'balance, order history and ledger are exactly as they were');
    if (otherCustomerId) assert.equal((await tx.query(`SELECT status FROM public.users WHERE id = $1`, [otherCustomerId])).rows[0].status, other, 'no other customer is affected');
    // No new deposit, withdrawal or service transaction.
    await tx.as(customerId);
    assert.equal(await tx.refused(`public.customer_create_deposit('evc_plus', '5.00', 'blk-dep-1', '252611111111')`), 'FORBIDDEN');
    assert.equal(await tx.refused(`public.customer_create_withdrawal('evc_plus', '5.00', 'blk-wd-1', '252611111111')`), 'FORBIDDEN');
    assert.equal(await tx.refused(`public.customer_create_exchange_order('{}')`) !== null, true);
    assert.equal(await tx.refused('public.customer_tips()'), 'FORBIDDEN');
    await tx.as(managerId);
    assert.deepEqual(await snapshot(), before, 'the refused attempts changed nothing');
    await unblock(tx);
    assert.deepEqual(await snapshot(), before, 'unblocking restores the access and changes nothing else');
  });
});

test('Users: search by name or phone, the Blocked tab and the counters, and it all persists (committed, seen from other connections)', async () => {
  const phone = `2526${String(Date.now()).slice(-8)}`;
  const name = `Blocky Search ${phone.slice(-4)}`;
  const user = (await db.query(
    `INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, $2, private.hash_password('ChangeMe123!')) RETURNING id`, [phone, name])).rows[0];
  await db.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, 777)`, [user.id]);
  const asManager = async (fn) => {
    const c = await db.connect(); // a connection of its own: what another phone sees
    try {
      await c.query('BEGIN');
      await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: managerId, role: 'authenticated', aud: 'authenticated' })]);
      const r = await fn(c);
      await c.query('COMMIT');
      return r;
    } catch (e) {
      await c.query('ROLLBACK').catch(() => {});
      throw e;
    } finally {
      c.release();
    }
  };
  const call = (sql, params = []) => asManager(async (c) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r);
  const list = async (status, q) => (await call(`public.agent_customers($1, $2, 'newest', 100, 0)`, [q, status])).map((x) => x.id);
  const overview = () => call('public.agent_customer_overview()');
  const before = await overview();
  assert.ok((await list('active', phone)).includes(user.id), 'found by phone, in Active');
  assert.ok((await list('active', name.slice(0, 12))).includes(user.id), 'found by name');
  assert.ok(!(await list('blocked', phone)).includes(user.id));

  await call('public.manage_set_customer_blocked($1,true,$2)', [user.id, 'Suspected abuse']);
  const mid = await overview();
  assert.equal(mid.blocked, before.blocked + 1);
  assert.equal(mid.active, before.active - 1);
  assert.equal(mid.total, before.total);
  assert.ok((await list('blocked', phone)).includes(user.id), 'in the Blocked tab, found by phone');
  assert.ok((await list('blocked', name.slice(0, 12))).includes(user.id), 'in the Blocked tab, found by name');
  assert.ok(!(await list('active', phone)).includes(user.id), 'out of Active');
  assert.ok((await list('all', phone)).includes(user.id));
  // Persisted: the history is in the table, with the customer as they were, and the wallet is untouched.
  const { rows: [h] } = await db.query(`SELECT * FROM public.customer_block_history WHERE customer_id = $1`, [user.id]);
  assert.deepEqual([h.action, h.reason, h.customer_name, h.customer_phone, h.actor_id], ['blocked', 'Suspected abuse', name, phone, managerId]);
  assert.equal((await db.query(`SELECT available_cents FROM public.wallets WHERE customer_id = $1`, [user.id])).rows[0].available_cents, '777');

  await call('public.manage_set_customer_blocked($1,false,NULL)', [user.id]);
  const after = await overview();
  assert.deepEqual([after.blocked, after.active, after.total], [before.blocked, before.active, before.total]);
  assert.ok((await list('active', phone)).includes(user.id));
  assert.ok(!(await list('blocked', phone)).includes(user.id));
  const info = await call('public.manage_customer_block_info($1)', [user.id]);
  assert.equal(info.status, 'active');
  assert.deepEqual(info.history.map((x) => x.action), ['unblocked', 'blocked'], 'both kept, newest first');
  assert.equal(info.history[0].byId, managerId);
  assert.equal(info.history[1].customerPhone, phone);
});

test('the history records who, why and when, and is kept across block / unblock / block', async () => {
  await asUser(managerId, async (tx) => {
    await block(tx, 'First reason');
    await unblock(tx, 'Cleared');
    await block(tx, 'Second reason');
    const info = await tx.call('public.manage_customer_block_info($1)', [customerId]);
    assert.equal(info.status, 'blocked');
    assert.equal(info.blockedReason, 'Second reason');
    assert.deepEqual(info.history.map((h) => [h.action, h.reason]), [['blocked', 'Second reason'], ['unblocked', 'Cleared'], ['blocked', 'First reason']]);
    for (const h of info.history) {
      assert.ok(h.at);
      assert.equal(h.by !== undefined, true);
      assert.equal(h.byRole, 'agent');
    }
    const audit = (await tx.query(`SELECT action FROM public.audit_logs WHERE entity_type = 'user' AND entity_id = $1 AND action LIKE 'customer.%' ORDER BY created_at`, [customerId])).rows.map((r) => r.action);
    assert.deepEqual(audit.slice(-3), ['customer.block', 'customer.unblock', 'customer.block']);
  });
});

test('who may do it: managers only; only customers can be blocked; the tables are closed', async () => {
  await asUser(managerId, async (tx) => {
    assert.equal(await tx.refused('public.manage_set_customer_blocked($1,true,$2)', [managerId, 'not a customer']), 'NOT_FOUND', 'an agent can not be blocked this way');
    assert.equal(await tx.refused('public.manage_set_customer_blocked($1,true,$2)', ['00000000-0000-0000-0000-000000000000', 'nobody']), 'NOT_FOUND');
    await tx.as(customerId);
    assert.equal(await tx.refused('public.manage_set_customer_blocked($1,true,$2)', [customerId, 'block myself']), 'FORBIDDEN');
    assert.equal(await tx.refused('public.manage_customer_block_info($1)', [customerId]), 'FORBIDDEN');
    if (plainAgentId) {
      await tx.as(plainAgentId);
      assert.equal(await tx.refused('public.manage_set_customer_blocked($1,true,$2)', [customerId, 'no permission']), 'FORBIDDEN');
      assert.equal(await tx.refused('public.manage_customer_block_info($1)', [customerId]), 'FORBIDDEN');
    }
    assert.equal((await tx.query(`SELECT status FROM public.users WHERE id = $1`, [customerId])).rows[0].status, 'active');
  });
  const r = await db.query(`SELECT has_table_privilege('authenticated','public.customer_block_history','SELECT') AS a,
                                   has_table_privilege('anon','public.customer_block_history','INSERT') AS b,
                                   has_function_privilege('anon','public.manage_set_customer_blocked(uuid,boolean,text)','EXECUTE') AS c`);
  assert.deepEqual(r.rows[0], { a: false, b: false, c: false });
});

test('real sign-in: a blocked customer can not log in, after unblocking can again (needs the Auth service)', async (t) => {
  let up = true;
  try {
    await fetch(`${URL}/auth/v1/health`, { signal: AbortSignal.timeout(2000) });
  } catch {
    up = false;
  }
  if (!up) return t.skip('Auth service is not running here');
  const phone = `2526${String(Date.now()).slice(-8)}`;
  const email = `${phone}@phone.baari.invalid`;
  const user = (await db.query(
    `INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Block test', private.hash_password('ChangeMe123!')) RETURNING id`, [phone])).rows[0];
  const login = async () => {
    const res = await fetch(`${URL}/auth/v1/token?grant_type=password`, {
      method: 'POST', headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: 'ChangeMe123!' }),
    });
    return { ok: res.ok, body: await res.json() };
  };
  try {
    const first = await login();
    assert.equal(first.ok, true, JSON.stringify(first.body));
    const c = await db.connect();
    try {
      const set = async (blocked, reason) => {
        await c.query('BEGIN');
        await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: managerId, role: 'authenticated', aud: 'authenticated' })]);
        await c.query(`SELECT public.manage_set_customer_blocked($1,$2,$3)`, [user.id, blocked, reason]);
        await c.query('COMMIT');
      };
      await set(true, 'Real sign-in test');
      const blocked = await login();
      assert.equal(blocked.ok, false);
      assert.match(JSON.stringify(blocked.body), /banned/i);
      // The access token from before no longer works for the app's own functions.
      const rpc = await fetch(`${URL}/rest/v1/rpc/customer_tips`, {
        method: 'POST', headers: { apikey: ANON_KEY, Authorization: `Bearer ${first.body.access_token}`, 'Content-Type': 'application/json' }, body: '{}',
      });
      assert.equal(rpc.ok, false);
      await set(false, null);
      assert.equal((await login()).ok, true);
    } finally {
      c.release();
    }
  } finally {
    // The audit log and history are append-only here: the throwaway customer stays, like the other suites' users.
    await db.query(`UPDATE public.users SET status = 'disabled' WHERE id = $1`, [user.id]);
  }
});
