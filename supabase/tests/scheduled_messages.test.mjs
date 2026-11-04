// Scheduled mass messages on the Telegram support bot (migrations/*_scheduled_messages.sql and the
// worker in functions/support-bot): Mogadishu time, the schedules kept in the database, one run per
// moment and one message per customer, Telegram's rate limit, and who may manage them.
//
// The database parts run in a transaction that is rolled back; the worker part needs the local stack
// and the functions served with tests/.functions.env (a stand-in Telegram on port 4993).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
let managerId;
let customerId;
let plainAgentId;
const seed = Number(Date.now().toString().slice(-6));
let n = 0;

before(async () => {
  managerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  customerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000003'`)).rows[0].id;
  plainAgentId = (await db.query(
    `SELECT u.id FROM users u LEFT JOIN agent_profiles p ON p.user_id = u.id
     WHERE u.role = 'agent' AND u.status = 'active' AND NOT ('manage_settings' = ANY (COALESCE(p.responsibilities, '{}'))) LIMIT 1`)).rows[0]?.id;
});
after(() => db.end());

async function inTx(claims, fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('request.jwt.claims', $1, true), set_config('role', 'authenticated', true)`, [JSON.stringify(claims)]);
    await c.query(`RESET ROLE`).catch(() => {});
    let k = 0;
    const tx = {
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
      refused: async (sql, params = []) => {
        const sp = `sp${k++}`;
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
const asManager = (fn) => inTx({ sub: managerId, role: 'authenticated', aud: 'authenticated' }, fn);
const asService = (fn) => inTx({ role: 'service_role' }, fn);
const iso = (v) => new Date(v).toISOString();

const save = (tx, o = {}) => tx.call('public.manage_save_broadcast($1,$2,$3,$4,$5,$6,$7)',
  [o.id ?? null, o.message ?? 'Macaamiisha sharafta leh, mahadsanid.', o.kind ?? 'daily', o.time ?? '08:00', o.weekday ?? null, o.monthDay ?? null, o.status ?? 'active']);

test('Mogadishu time (GMT+3): the next moment of a daily, weekly and monthly schedule', async () => {
  const next = async (kind, time, weekday, monthDay, from) =>
    iso((await db.query(`SELECT private.broadcast_next($1,$2::time,$3,$4,$5::timestamptz) AS t`, [kind, time, weekday, monthDay, from])).rows[0].t);
  // 2026-11-04 22:05 in Mogadishu (a Wednesday)
  const now = '2026-11-04T19:05:00Z';
  assert.equal(await next('daily', '08:00', null, null, now), '2026-11-05T05:00:00.000Z', 'tomorrow 08:00');
  assert.equal(await next('daily', '23:00', null, null, now), '2026-11-04T20:00:00.000Z', 'today 23:00 is still ahead');
  assert.equal(await next('weekly', '10:00', 7, null, now), '2026-11-08T07:00:00.000Z', 'Sunday');
  assert.equal(await next('weekly', '10:00', 3, null, now), '2026-11-11T07:00:00.000Z', 'Wednesday 10:00 has passed: next week');
  assert.equal(await next('monthly', '09:00', null, 1, now), '2026-12-01T06:00:00.000Z', 'the 1st');
  assert.equal(await next('monthly', '09:00', null, 31, now), '2026-11-30T06:00:00.000Z', 'a shorter month: its last day');
  assert.equal(await next('monthly', '09:00', null, 31, '2027-02-10T00:00:00Z'), '2027-02-28T06:00:00.000Z', 'February');
  assert.equal(await next('monthly', '09:00', null, 4, now), '2026-12-04T06:00:00.000Z', 'the 4th at 09:00 has passed');
});

test('managers create, edit, pause, resume and delete; the schedule is kept in the database', async () => {
  await asManager(async (tx) => {
    const s = await save(tx, { message: 'Salaan', kind: 'weekly', time: '10:30', weekday: 7 });
    assert.equal(s.status, 'active');
    assert.equal(s.kind, 'weekly');
    assert.equal(s.time, '10:30');
    assert.equal(s.weekday, 7);
    assert.ok(s.nextRunAt, 'its next moment is set');
    const row = (await tx.query(`SELECT * FROM public.broadcast_schedules WHERE id = $1`, [s.id])).rows[0];
    assert.equal(row.message, 'Salaan');

    const edited = await save(tx, { id: s.id, message: 'Salaan cusub', kind: 'monthly', time: '09:00', monthDay: 1 });
    assert.equal(edited.message, 'Salaan cusub');
    assert.equal(edited.kind, 'monthly');
    assert.equal(edited.monthDay, 1);
    assert.equal(edited.weekday, null, 'a monthly schedule has no weekday');

    const paused = await tx.call('public.manage_set_broadcast_status($1,$2)', [s.id, 'paused']);
    assert.equal(paused.status, 'paused');
    const resumed = await tx.call('public.manage_set_broadcast_status($1,$2)', [s.id, 'active']);
    assert.equal(resumed.status, 'active');
    assert.ok(new Date(resumed.nextRunAt) > new Date(), 'resuming waits for the next moment');

    const list = await tx.call('public.manage_broadcasts()');
    assert.ok(list.schedules.some((x) => x.id === s.id));
    assert.ok(list.stats.activeSchedules >= 1);

    assert.deepEqual(await tx.call('public.manage_delete_broadcast($1)', [s.id]), { deleted: true });
    assert.ok(!(await tx.call('public.manage_broadcasts()')).schedules.some((x) => x.id === s.id), 'a deleted schedule is gone from the list');
    assert.equal(await tx.refused('public.manage_set_broadcast_status($1,$2)', [s.id, 'active']), 'NOT_FOUND');
    const actions = (await tx.query(`SELECT action FROM audit_logs WHERE entity_id = $1 ORDER BY action`, [s.id])).rows.map((r) => r.action);
    for (const a of ['broadcast.create', 'broadcast.update', 'broadcast.pause', 'broadcast.resume', 'broadcast.delete']) assert.ok(actions.includes(a), a);
  });
});

test('the schedule is checked: message, kind, time, day', async () => {
  await asManager(async (tx) => {
    const bad = async (o) => tx.refused('public.manage_save_broadcast($1,$2,$3,$4,$5,$6,$7)',
      [null, o.message ?? 'x', o.kind ?? 'daily', o.time ?? '08:00', o.weekday ?? null, o.monthDay ?? null, 'active']);
    assert.equal(await bad({ message: '' }), 'VALIDATION_ERROR');
    assert.equal(await bad({ message: 'x'.repeat(4001) }), 'VALIDATION_ERROR');
    assert.equal(await bad({ kind: 'hourly' }), 'VALIDATION_ERROR');
    assert.equal(await bad({ time: '25:99' }), 'VALIDATION_ERROR');
    assert.equal(await bad({ kind: 'weekly' }), 'VALIDATION_ERROR', 'a weekly schedule needs a day');
    assert.equal(await bad({ kind: 'weekly', weekday: 8 }), 'VALIDATION_ERROR');
    assert.equal(await bad({ kind: 'monthly' }), 'VALIDATION_ERROR', 'a monthly schedule needs a date');
    assert.equal(await bad({ kind: 'monthly', monthDay: 32 }), 'VALIDATION_ERROR');
    assert.equal((await save(tx, { message: 'x'.repeat(4000) })).status, 'active', '4000 characters are fine');
  });
});

test('who may do it: managers only; the worker functions are for the service role only', async () => {
  const calls = [
    ['public.manage_broadcasts()', []],
    ['public.manage_save_broadcast($1,$2,$3,$4,$5,$6,$7)', [null, 'x', 'daily', '08:00', null, null, 'active']],
    ['public.manage_test_broadcast($1)', ['x']],
  ];
  await inTx({ sub: customerId, role: 'authenticated', aud: 'authenticated' }, async (tx) => {
    for (const [sql, params] of calls) assert.equal(await tx.refused(sql, params), 'FORBIDDEN', `${sql} is refused to a customer`);
    for (const sql of ['public.broadcast_tick()', 'public.broadcast_claim(5)', 'public.broadcast_result($1)']) {
      assert.ok(await tx.refused(sql, sql.includes('$1') ? ['[]'] : []), `${sql} is not for customers`);
    }
  });
  if (plainAgentId) {
    await inTx({ sub: plainAgentId, role: 'authenticated', aud: 'authenticated' }, async (tx) => {
      for (const [sql, params] of calls) assert.equal(await tx.refused(sql, params), 'FORBIDDEN', `${sql} is refused to an agent without the permission`);
    });
  }
  await asManager(async (tx) => {
    for (const sql of ['public.broadcast_tick()', 'public.broadcast_claim(5)']) {
      assert.ok(await tx.refused(sql), `${sql} is for the worker, not for a manager`);
    }
  });
  for (const [role, fn] of [['anon', 'private.broadcast_next(text,time,int,int,timestamptz)'], ['anon', 'public.broadcast_tick()'], ['authenticated', 'public.broadcast_tick()'],
    ['authenticated', 'public.broadcast_claim(int)'], ['authenticated', 'public.broadcast_result(jsonb)'], ['anon', 'public.manage_broadcasts()']]) {
    const { rows } = await db.query(`SELECT has_function_privilege($1, $2, 'EXECUTE') AS a`, [role, fn]);
    assert.equal(rows[0].a, false, `${role} can not run ${fn}`);
  }
});

/** Three customers linked to the bot, one disabled, one not linked. */
async function seedChats(tx) {
  const mk = async (status, linked) => {
    const phone = `2526${String(seed * 10 + n++).padStart(8, '0').slice(-8)}`;
    const u = (await tx.query(`INSERT INTO public.users (role, phone, name, password_hash, status)
                                 VALUES ('customer', $1, 'Broadcast Test', private.hash_password('ChangeMe123!'), $2) RETURNING id`, [phone, status])).rows[0].id;
    const chat = 8800000000 + seed * 100 + n;
    if (linked) await tx.query(`INSERT INTO public.support_chats (chat_id, customer_id, state, linked_at) VALUES ($1,$2,'ready',now())`, [chat, u]);
    return { id: u, chat };
  };
  return { a: await mk('active', true), b: await mk('active', true), c: await mk('active', true), disabled: await mk('disabled', true), unlinked: await mk('active', false) };
}

test('a due schedule becomes one run, once: every eligible customer gets one message, no duplicates', async () => {
  let schedule;
  await asService(async (tx) => {
    const t = await seedChats(tx);
    schedule = (await tx.query(`INSERT INTO public.broadcast_schedules (message, kind, send_time, status, next_run_at, created_by)
                                  VALUES ('Fariin jadwal ah', 'daily', '08:00', 'active', now() - interval '2 minutes', $1) RETURNING *`, [managerId])).rows[0];
    const first = await tx.call('public.broadcast_tick()');
    assert.ok(first.started >= 1);
    const second = await tx.call('public.broadcast_tick()');
    assert.equal(second.started, 0, 'the same moment is not started twice');
    const runs = (await tx.query(`SELECT * FROM public.broadcast_runs WHERE schedule_id = $1`, [schedule.id])).rows;
    assert.equal(runs.length, 1);
    assert.equal(iso(runs[0].scheduled_for), iso(schedule.next_run_at));
    const chats = (await tx.query(`SELECT chat_id FROM public.broadcast_deliveries WHERE run_id = $1`, [runs[0].id])).rows.map((r) => Number(r.chat_id));
    for (const x of [t.a, t.b, t.c]) assert.equal(chats.filter((c) => c === x.chat).length, 1, 'one message each');
    assert.ok(!chats.includes(t.disabled.chat), 'a disabled customer gets nothing');
    assert.ok(!chats.includes(t.unlinked.chat), 'a customer who never linked Telegram can not be reached');
    assert.equal(runs[0].total, chats.length);
    const after = (await tx.query(`SELECT * FROM public.broadcast_schedules WHERE id = $1`, [schedule.id])).rows[0];
    assert.ok(new Date(after.next_run_at) > new Date(), 'the next moment is tomorrow');
    assert.equal(iso(after.last_run_at), iso(schedule.next_run_at));
  });
});

test('paused schedules do not run; a moment missed for more than 6 hours is skipped', async () => {
  await asService(async (tx) => {
    await seedChats(tx);
    const paused = (await tx.query(`INSERT INTO public.broadcast_schedules (message, kind, send_time, status, next_run_at)
                                      VALUES ('x', 'daily', '08:00', 'paused', now() - interval '1 minute') RETURNING id`)).rows[0].id;
    const missed = (await tx.query(`INSERT INTO public.broadcast_schedules (message, kind, send_time, status, next_run_at)
                                      VALUES ('y', 'daily', '08:00', 'active', now() - interval '7 hours') RETURNING id`)).rows[0].id;
    await tx.call('public.broadcast_tick()');
    assert.equal(Number((await tx.query(`SELECT count(*) AS n FROM public.broadcast_runs WHERE schedule_id = ANY($1)`, [[paused, missed]])).rows[0].n), 0);
    const after = (await tx.query(`SELECT next_run_at FROM public.broadcast_schedules WHERE id = $1`, [missed])).rows[0];
    assert.ok(new Date(after.next_run_at) > new Date(), 'but the next moment is kept');
  });
});

test('sending: claimed once, results counted, Telegram "slow down" waits, the run finishes', async () => {
  await asService(async (tx) => {
    await tx.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status IN ('pending', 'sending')`); // other runs are not this test's business
    const t = await seedChats(tx);
    await tx.query(`INSERT INTO public.broadcast_schedules (message, kind, send_time, status, next_run_at)
                      VALUES ('Fariin', 'daily', '08:00', 'active', now() - interval '1 minute')`);
    await tx.call('public.broadcast_tick()');
    // Claim everything, in batches (at most 50 at a time).
    const claimed = [];
    for (;;) {
      const batch = await tx.call('public.broadcast_claim($1)', [500]);
      if (!batch.length) break;
      assert.ok(batch.length <= 50, 'a batch is at most 50');
      claimed.push(...batch);
    }
    assert.ok(claimed.length >= 3);
    assert.equal(claimed[0].text, 'Fariin');
    assert.equal(new Set(claimed.map((d) => d.id)).size, claimed.length, 'no message was offered twice');

    const mine = claimed.filter((d) => [t.a.chat, t.b.chat, t.c.chat].includes(Number(d.chatId)));
    assert.equal(mine.length, 3);
    const [x, y, z] = mine;
    await tx.call('public.broadcast_release($1)', [[z.id]]);
    assert.equal((await tx.call('public.broadcast_claim($1)', [50])).length, 1, 'a released message is offered again');
    // The others (not mine) are just marked as sent
    const rest = claimed.filter((d) => !mine.includes(d)).map((d) => ({ id: d.id, ok: true }));
    await tx.call('public.broadcast_result($1)', [JSON.stringify([{ id: x.id, ok: true }, { id: y.id, ok: false, error: 'blocked' }, ...rest])]);
    let run = (await tx.query(`SELECT * FROM public.broadcast_runs WHERE message = 'Fariin' ORDER BY started_at DESC LIMIT 1`)).rows[0];
    assert.equal(run.status, 'sending', 'one message is still to send');
    assert.equal(run.failed, 1);
    await tx.call('public.broadcast_result($1)', [JSON.stringify([{ id: z.id, ok: true }])]);
    run = (await tx.query(`SELECT * FROM public.broadcast_runs WHERE id = $1`, [run.id])).rows[0];
    assert.equal(run.status, 'done');
    assert.ok(run.finished_at);
    assert.equal(run.sent + run.failed, run.total, 'sent and failed add up to the total');
    // The same result twice changes nothing.
    await tx.call('public.broadcast_result($1)', [JSON.stringify([{ id: x.id, ok: false, error: 'late' }])]);
    assert.equal((await tx.query(`SELECT status FROM public.broadcast_deliveries WHERE id = $1`, [x.id])).rows[0].status, 'sent');
  });
});

test('a test message goes to the team chat only, and needs the team chat to be linked', async () => {
  await asManager(async (tx) => {
    await tx.query(`DELETE FROM public.support_admin`);
    assert.equal(await tx.refused('public.manage_test_broadcast($1)', ['Tijaabo']), 'TEAM_CHAT_NOT_LINKED');
    await tx.query(`INSERT INTO public.support_admin (id, chat_id) VALUES (true, -1009990001)`);
    const r = await tx.call('public.manage_test_broadcast($1)', ['Tijaabo']);
    const run = (await tx.query(`SELECT * FROM public.broadcast_runs WHERE id = $1`, [r.runId])).rows[0];
    assert.equal(run.is_test, true);
    assert.equal(run.total, 1);
    const d = (await tx.query(`SELECT chat_id FROM public.broadcast_deliveries WHERE run_id = $1`, [r.runId])).rows;
    assert.deepEqual(d.map((x) => Number(x.chat_id)), [-1009990001], 'only the team chat');
    const list = await tx.call('public.manage_broadcasts()');
    assert.equal(list.stats.teamChatLinked, true);
    assert.ok(list.runs.some((x) => x.id === r.runId && x.isTest));
  });
});

// ---------------------------------------------------------------- the worker

const tg = { calls: [], slowOnce: new Set() };
const telegram = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const method = req.url.split('/').pop();
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
    tg.calls.push({ method, body });
    const reply = (code, payload) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(payload)); };
    if (method === 'sendMessage') {
      if (tg.blocked?.has(Number(body.chat_id))) return reply(403, { ok: false, description: 'Forbidden: bot was blocked by the user' });
      if (tg.slowOnce.has(Number(body.chat_id))) {
        tg.slowOnce.delete(Number(body.chat_id));
        return reply(429, { ok: false, description: 'Too Many Requests: retry after 1' });
      }
      return reply(200, { ok: true, result: { message_id: 1 } });
    }
    return reply(200, { ok: true, result: true });
  });
});

test('the worker: only the platform secret can wake it; it sends every message once, handles a blocked customer and a "retry after"', async (t) => {
  const secret = (await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`)).rows[0]?.decrypted_secret;
  const probe = await fetch(`${URL}/functions/v1/support-bot/broadcast`, { method: 'POST', body: '{}' }).catch(() => null);
  if (!secret || probe?.status !== 403) return t.skip('support-bot is not served');
  await new Promise((r) => telegram.listen(4993, '0.0.0.0', r));
  try {
    const wrong = await fetch(`${URL}/functions/v1/support-bot/broadcast`, { method: 'POST', headers: { 'x-worker-secret': 'nope' }, body: '{}' });
    assert.equal(wrong.status, 403);

    // Real, committed data: two customers linked to the bot, one who blocked the bot, one told to slow down.
    const made = [];
    const mk = async (blockedBot = false) => {
      const phone = `2526${String(seed * 10 + n++).padStart(8, '0').slice(-8)}`;
      const u = (await db.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Worker Test', private.hash_password('ChangeMe123!')) RETURNING id`, [phone])).rows[0].id;
      const chat = 8900000000 + seed * 100 + n;
      await db.query(`INSERT INTO public.support_chats (chat_id, customer_id, state, linked_at) VALUES ($1,$2,'ready',now())`, [chat, u]);
      made.push({ u, chat });
      return chat;
    };
    const ok1 = await mk();
    const ok2 = await mk();
    const stopped = await mk();
    const slow = await mk();
    tg.blocked = new Set([stopped]);
    tg.slowOnce = new Set([slow]);
    await db.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status IN ('pending', 'sending')`);
    const text = `Fariin tijaabo ${seed}`;
    const sched = (await db.query(`INSERT INTO public.broadcast_schedules (message, kind, send_time, status, next_run_at)
                                     VALUES ($1, 'daily', '08:00', 'active', now() - interval '1 minute') RETURNING id`, [text])).rows[0].id;
    try {
      const res = await fetch(`${URL}/functions/v1/support-bot/broadcast`, { method: 'POST', headers: { 'x-worker-secret': secret }, body: '{}' });
      assert.equal(res.status, 200);
      const sends = tg.calls.filter((c) => c.method === 'sendMessage' && c.body.text === text);
      const count = (chat) => sends.filter((c) => Number(c.body.chat_id) === chat).length;
      assert.equal(count(ok1), 1);
      assert.equal(count(ok2), 1);
      assert.equal(count(stopped), 1, 'one try; a blocked customer is not retried');
      assert.equal(count(slow), 2, 'told to slow down once: sent again later, not lost');
      const run = (await db.query(`SELECT * FROM public.broadcast_runs WHERE schedule_id = $1`, [sched])).rows[0];
      assert.equal(run.status, 'done');
      const d = (await db.query(`SELECT chat_id, status, error FROM public.broadcast_deliveries WHERE run_id = $1`, [run.id])).rows;
      const by = (chat) => d.find((x) => Number(x.chat_id) === chat);
      assert.equal(by(ok1).status, 'sent');
      assert.equal(by(slow).status, 'sent');
      assert.equal(by(stopped).status, 'failed');
      assert.equal(by(stopped).error, 'blocked');
      assert.ok(run.failed >= 1 && run.sent >= 3);
      // Waking it again sends nothing twice.
      const before = tg.calls.length;
      await fetch(`${URL}/functions/v1/support-bot/broadcast`, { method: 'POST', headers: { 'x-worker-secret': secret }, body: '{}' });
      assert.equal(tg.calls.slice(before).filter((c) => c.body.text === text).length, 0);
    } finally {
      await db.query(`DELETE FROM public.broadcast_schedules WHERE id = $1`, [sched]);
      await db.query(`DELETE FROM public.support_chats WHERE chat_id = ANY($1)`, [made.map((m) => m.chat)]);
    }
  } finally {
    telegram.close();
  }
});
