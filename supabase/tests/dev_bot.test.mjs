// The AI Developer Bot's database side (migrations/*_dev_bot.sql): who may use it, the task queue and its limits, the
// memory, the one-time approvals, the audit. Every test runs in a transaction that is rolled back.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
let adminId;
let agentId;
let customerId;
const seed = Number(Date.now().toString().slice(-7));
const OWNER = 7_100_000_000 + seed;
const DEV = OWNER + 1;
const STRANGER = OWNER + 2;
const NON_ADMIN = OWNER + 3;
const MANAGER_AGENT = OWNER + 4;

before(async () => {
  adminId = (await db.query(`SELECT id FROM users WHERE phone = '252610000001'`)).rows[0].id;
  agentId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  customerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000003'`)).rows[0].id;
});
after(() => db.end());

async function inTx(fn, claims = { role: 'service_role' }) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
    return await fn({
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
      refused: async (sql, params = []) => {
        await c.query('SAVEPOINT s');
        try { await c.query(`SELECT ${sql}`, params); return null; } catch (e) { return e.hint ?? e.message; } finally { await c.query('ROLLBACK TO s'); }
      },
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

/** A clean developer bot: nobody listed; OWNER, DEV and NON_ADMIN linked to a platform account. */
async function fresh(tx) {
  await tx.query(`DELETE FROM public.dev_pending`);
  await tx.query(`DELETE FROM public.dev_tasks`);
  await tx.query(`DELETE FROM public.dev_bot_users`);
  // One Telegram account per platform user: OWNER is the seeded admin, DEV a second administrator made here, NON_ADMIN an agent.
  const admin2 = (await tx.query(`INSERT INTO public.users (role, phone, name, password_hash, status) VALUES ('admin', $1, 'Second Admin', private.hash_password('ChangeMe123!'), 'active') RETURNING id`,
    [`2526${String(seed).padStart(8, '0').slice(-8)}`])).rows[0].id;
  // MANAGER_AGENT is the seeded agent with the settings responsibility (how the real owner's account is); PLAIN is an agent without it.
  const plain = (await tx.query(`INSERT INTO public.users (role, phone, name, password_hash, status) VALUES ('agent', $1, 'Plain Agent', private.hash_password('ChangeMe123!'), 'active') RETURNING id`,
    [`2527${String(seed).padStart(8, '0').slice(-8)}`])).rows[0].id;
  await tx.query(`DELETE FROM public.telegram_operators WHERE user_id IN ($1, $2, $3, $4)`, [adminId, admin2, agentId, plain]);
  await tx.query(`INSERT INTO public.telegram_operators (telegram_user_id, user_id) VALUES ($1, $2), ($3, $4), ($5, $6), ($7, $8)`,
    [OWNER, adminId, DEV, admin2, NON_ADMIN, plain, MANAGER_AGENT, agentId]);
}

test('the first start makes a linked MANAGER the owner (an administrator, or an agent with the settings responsibility); a stranger, a plain agent and a second claim get nothing', async () => {
  await inTx(async (tx) => {
    await fresh(tx);
    assert.equal(await tx.call(`public.dev_claim_owner($1, 'x')`, [STRANGER]), false, 'not linked to the platform');
    assert.equal(await tx.call(`public.dev_claim_owner($1, 'x')`, [NON_ADMIN]), false, 'a plain agent is not a manager');
    assert.equal(await tx.call(`public.dev_claim_owner($1, 'Owner')`, [MANAGER_AGENT]), true, 'an agent with the settings responsibility is: this is the real owner\'s kind of account');
    await tx.query(`DELETE FROM public.dev_bot_users`);
    assert.equal((await tx.call(`public.dev_auth($1)`, [OWNER])).authorized, false, 'listed nowhere yet');
    assert.equal(await tx.call(`public.dev_claim_owner($1, 'Owner')`, [OWNER]), true);
    const a = await tx.call(`public.dev_auth($1)`, [OWNER]);
    assert.deepEqual([a.authorized, a.role], [true, 'owner']);
    assert.equal(await tx.call(`public.dev_claim_owner($1, 'Other')`, [DEV]), false, 'there is one owner');
    assert.equal((await tx.call(`public.dev_auth($1)`, [STRANGER])).authorized, false);
  });
});

test('the owner authorizes another linked administrator and can take the access away; nobody else can', async () => {
  await inTx(async (tx) => {
    await fresh(tx);
    await tx.call(`public.dev_claim_owner($1, 'Owner')`, [OWNER]);
    assert.equal(await tx.call(`public.dev_user_set($1, $2, 'Dev', true)`, [DEV, STRANGER]), 'not_owner', 'a stranger can not add anyone');
    assert.equal(await tx.call(`public.dev_user_set($1, $2, 'S', true)`, [OWNER, STRANGER]), 'not_admin', 'only a linked platform administrator');
    assert.equal(await tx.call(`public.dev_user_set($1, $2, 'N', true)`, [OWNER, NON_ADMIN]), 'not_admin', 'a plain agent is refused');
    assert.equal(await tx.call(`public.dev_user_set($1, $2, 'Dev', true)`, [OWNER, DEV]), 'ok');
    assert.equal((await tx.call(`public.dev_auth($1)`, [DEV])).role, 'developer');
    assert.equal(await tx.call(`public.dev_user_set($1, $2, 'x', false)`, [DEV, OWNER]), 'not_owner', 'a developer can not remove the owner');
    assert.equal(await tx.call(`public.dev_user_set($1, $2, 'x', false)`, [OWNER, DEV]), 'ok');
    assert.equal((await tx.call(`public.dev_auth($1)`, [DEV])).authorized, false, 'revoked');
    // an administrator who is un-linked from the platform loses the bot at once
    await tx.query(`DELETE FROM public.telegram_operators WHERE telegram_user_id = $1`, [OWNER]);
    assert.equal((await tx.call(`public.dev_auth($1)`, [OWNER])).reason, 'not_admin');
  });
});

test('tasks: one runs at a time, the rest wait; 10 a day at most; a final status never changes', async () => {
  await inTx(async (tx) => {
    await fresh(tx);
    const mk = (title, status = 'queued') => tx.call(`public.dev_task_create($1, 1, $2, 'do it', 'low', $3)`, [OWNER, title, status]);
    const a = await mk('A');
    const b = await mk('B');
    assert.ok(a.number < b.number);
    const first = await tx.call(`public.dev_task_claim_next()`);
    assert.equal(first.id, a.id, 'the oldest first');
    assert.equal(first.status, 'running');
    assert.equal(await tx.call(`public.dev_task_claim_next()`), null, 'B waits while A runs');
    const done = await tx.call(`public.dev_task_set($1, 'done', $2::jsonb)`, [a.id, JSON.stringify({ summary: 'ok', prUrl: 'https://github.com/x/y/pull/1', prNumber: 1 })]);
    assert.equal(done.status, 'done');
    assert.equal(done.pr_number, 1);
    assert.equal((await tx.call(`public.dev_task_set($1, 'running')`, [a.id])).refused, true, 'done is final');
    assert.equal((await tx.call(`public.dev_task_claim_next()`)).id, b.id, 'then B');
    await tx.query(`DELETE FROM public.dev_tasks`);
    for (let i = 0; i < 10; i++) await mk(`T${i}`);
    assert.equal((await mk('one too many')).limited, true);
  });
});

test('a clarifying question: the next answer is added to the same task, then it is queued', async () => {
  await inTx(async (tx) => {
    await fresh(tx);
    const t = await tx.call(`public.dev_task_create($1, 42, 'Virtual card', 'add a card', 'medium', 'clarify')`, [OWNER]);
    assert.equal((await tx.call(`public.dev_task_open_clarify(42)`)).id, t.id);
    assert.equal(await tx.call(`public.dev_task_open_clarify(43)`), null, 'another chat');
    const r = await tx.call(`public.dev_task_refine($1, 'a debit card, USD only', 'Virtual debit card', 'high', 'awaiting_approval')`, [t.id]);
    assert.equal(r.status, 'awaiting_approval');
    assert.match(r.request, /add a card[\s\S]*USD only/);
    assert.equal(await tx.call(`public.dev_task_open_clarify(42)`), null, 'no open question any more');
    assert.equal(await tx.call(`public.dev_task_refine($1, 'x', NULL, NULL, 'queued')`, [t.id]), null, 'only a task that is waiting for an answer');
  });
});

test('a task that reported nothing for 90 minutes is failed, once', async () => {
  await inTx(async (tx) => {
    await fresh(tx);
    const t = await tx.call(`public.dev_task_create($1, 1, 'Stale', 'x', 'low', 'queued')`, [OWNER]);
    await tx.call(`public.dev_task_claim_next()`);
    assert.deepEqual(await tx.call(`public.dev_task_expire_stale()`), []);
    await tx.query(`UPDATE public.dev_tasks SET last_event_at = now() - interval '2 hours' WHERE id = $1`, [t.id]);
    const e = await tx.call(`public.dev_task_expire_stale()`);
    assert.equal(e.length, 1);
    assert.equal(e[0].id, t.id);
    assert.deepEqual(await tx.call(`public.dev_task_expire_stale()`), []);
    assert.equal((await tx.call(`public.dev_task_get($1)`, [String(t.number)])).status, 'failed');
  });
});

test('approval buttons: owner only, the person they were made for, once, before they expire', async () => {
  await inTx(async (tx) => {
    await fresh(tx);
    await tx.call(`public.dev_claim_owner($1, 'Owner')`, [OWNER]);
    await tx.call(`public.dev_user_set($1, $2, 'Dev', true)`, [OWNER, DEV]);
    const id = await tx.call(`public.dev_pending_create('deploy', $1, '{"sha":"abc"}'::jsonb)`, [OWNER]);
    assert.equal((await tx.call(`public.dev_pending_take($1, $2)`, [id, DEV])).refused, 'not_owner', 'a developer can not approve a deployment');
    assert.equal((await tx.call(`public.dev_pending_take($1, $2)`, [id, STRANGER])).refused, 'not_owner');
    const taken = await tx.call(`public.dev_pending_take($1, $2)`, [id, OWNER]);
    assert.equal(taken.kind, 'deploy');
    assert.equal(taken.payload.sha, 'abc');
    assert.equal((await tx.call(`public.dev_pending_take($1, $2)`, [id, OWNER])).refused, 'used_or_expired', 'a second press does nothing');
    const old = await tx.call(`public.dev_pending_create('deploy', $1, '{}'::jsonb)`, [OWNER]);
    await tx.query(`UPDATE public.dev_pending SET expires_at = now() - interval '1 minute' WHERE id = $1`, [old]);
    assert.equal((await tx.call(`public.dev_pending_take($1, $2)`, [old, OWNER])).refused, 'used_or_expired');
    const audit = (await tx.query(`SELECT action, ok FROM public.dev_audit WHERE actor IN ($1, $2) ORDER BY id`, [OWNER, DEV])).rows;
    assert.ok(audit.some((a) => a.action === 'approval_deploy' && a.ok), 'the approval is audited');
    assert.ok(audit.some((a) => a.action === 'approval_refused' && !a.ok), 'the refusal is audited');
  });
});

test('memory: pinned first, searchable, updated in place, and the agent context is bounded', async () => {
  await inTx(async (tx) => {
    await tx.query(`DELETE FROM public.dev_memory`);
    await tx.call(`public.dev_memory_add('bug', 'Wallet SIM check', 'SMS refused: change the wallet phone', false, NULL)`);
    await tx.call(`public.dev_memory_add('architecture', 'Platform', 'Supabase', true, NULL)`);
    await tx.call(`public.dev_memory_add('bug', 'Wallet SIM check', 'updated text', false, NULL)`);
    const all = await tx.call(`public.dev_memory_search(NULL, 10)`);
    assert.equal(all.length, 2, 'the same title is updated, not repeated');
    assert.equal(all[0].title, 'Platform', 'pinned first');
    assert.equal((await tx.call(`public.dev_memory_search('SIM', 10)`))[0].body, 'updated text');
    assert.deepEqual(await tx.call(`public.dev_memory_search('zzzz', 10)`), []);
    for (let i = 0; i < 50; i++) await tx.call(`public.dev_memory_add('note', $1, $2, false, NULL)`, [`n${i}`, 'x'.repeat(900)]);
    const ctx = await tx.call(`public.dev_memory_context()`);
    assert.ok(ctx.length <= 9000, 'bounded');
    assert.match(ctx, /^\[architecture\] Platform/, 'the pinned note leads');
    assert.ok(await tx.refused(`public.dev_memory_add('bad kind', 't', 'b')`));
  });
});

test('/health, /logs and the tick read what the platform knows; the tick is only needed while there is work', async () => {
  await inTx(async (tx) => {
    await fresh(tx);
    const s = await tx.call(`public.dev_system_summary()`);
    assert.ok(Array.isArray(s.open));
    assert.equal(typeof s.database.connections, 'number');
    const l = await tx.call(`public.dev_logs(5)`);
    assert.ok(Array.isArray(l.events) && Array.isArray(l.audit) && Array.isArray(l.incidents));
    assert.equal(await tx.call(`public.dev_tick_needed()`), false, 'nothing to do');
    await tx.call(`public.dev_task_create($1, 1, 'T', 'x', 'low', 'queued')`, [OWNER]);
    assert.equal(await tx.call(`public.dev_tick_needed()`), true);
    await tx.query(`SELECT private.devbot_kick()`); // never throws
  });
});

test('who may call: the service role only; no table is readable or writable by the apps', async () => {
  for (const claims of [{ sub: adminId, role: 'authenticated', aud: 'authenticated' }, { sub: customerId, role: 'authenticated', aud: 'authenticated' }]) {
    await inTx(async (tx) => {
      for (const sql of [`public.dev_auth(1)`, `public.dev_task_list(5, false)`, `public.dev_memory_context()`, `public.dev_claim_owner(1, 'x')`, `public.dev_pending_take('00000000-0000-0000-0000-000000000000', 1)`]) {
        assert.ok(await tx.refused(sql), `${sql} is not for a signed-in user`);
      }
    }, claims);
  }
  for (const role of ['anon', 'authenticated']) {
    for (const t of ['dev_bot_users', 'dev_tasks', 'dev_task_events', 'dev_memory', 'dev_audit', 'dev_pending']) {
      const { rows } = await db.query(`SELECT has_table_privilege($1, $2, 'SELECT') AS s, has_table_privilege($1, $2, 'INSERT') AS i`, [role, `public.${t}`]);
      assert.deepEqual([rows[0].s, rows[0].i], [false, false], `${role} on ${t}`);
    }
    const f = await db.query(`SELECT has_function_privilege($1, 'public.dev_task_set(uuid, text, jsonb)', 'EXECUTE') AS a`, [role]);
    assert.equal(f.rows[0].a, false);
  }
});
