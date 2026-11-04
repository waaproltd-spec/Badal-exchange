// Scheduled messages as push notifications to the Customer App (migrations/*_scheduled_push.sql and the
// push-notifications function): every active customer once, each registered device, customers without a
// device and devices FCM says are gone, the counts, and who may do what. Database parts run in a rolled
// back transaction; the worker part needs the functions served (a stand-in Firebase on port 4996).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
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
const token = (prefix = 'tok') => `${prefix}-${randomUUID()}-${randomUUID()}`;

/** Customers: with devices, without, disabled; and a staff account with a device. */
async function seedCustomers(tx) {
  const mk = async (role = 'customer', status = 'active', devices = []) => {
    const phone = `2526${String(seed * 10 + n++).padStart(8, '0').slice(-8)}`;
    const id = (await tx.query(`INSERT INTO public.users (role, phone, name, password_hash, status)
                                  VALUES ($1, $2, 'Push Test', private.hash_password('ChangeMe123!'), $3) RETURNING id`, [role, phone, status])).rows[0].id;
    for (const t of devices) await tx.query(`INSERT INTO public.push_tokens (token, customer_id) VALUES ($1, $2)`, [t, id]);
    return { id, phone };
  };
  return {
    two: await mk('customer', 'active', [token(), token()]),
    one: await mk('customer', 'active', [token('gone')]),
    none: await mk('customer', 'active', []),
    disabled: await mk('customer', 'disabled', [token()]),
    staff: await mk('agent', 'active', [token()]),
  };
}

const dueSchedule = (tx, channels, extra = {}) => tx.query(
  `INSERT INTO public.broadcast_schedules (title, message, kind, send_time, status, channels, next_run_at)
   VALUES ($1, 'Fariin jadwal ah', 'daily', '08:00', 'active', $2, now() - interval '1 minute') RETURNING *`, [extra.title ?? 'BADAL EXCHANGE', channels]).then((r) => r.rows[0]);

test('a push run: every active Customer App customer once, with or without Telegram; never staff or a disabled customer', async () => {
  await asService(async (tx) => {
    const t = await seedCustomers(tx);
    const s = await dueSchedule(tx, ['push']);
    assert.ok((await tx.call('public.broadcast_tick()')).started >= 1);
    assert.equal((await tx.call('public.broadcast_tick()')).started, 0, 'the same moment is not started twice');
    const runs = (await tx.query(`SELECT * FROM public.broadcast_runs WHERE schedule_id = $1`, [s.id])).rows;
    assert.equal(runs.length, 1);
    assert.equal(runs[0].channel, 'push');
    assert.equal(runs[0].title, 'BADAL EXCHANGE');
    const ids = (await tx.query(`SELECT customer_id FROM public.broadcast_deliveries WHERE run_id = $1`, [runs[0].id])).rows.map((r) => r.customer_id);
    for (const c of [t.two, t.one, t.none]) assert.equal(ids.filter((i) => i === c.id).length, 1, 'once each');
    assert.ok(!ids.includes(t.disabled.id));
    assert.ok(!ids.includes(t.staff.id));
    const active = Number((await tx.query(`SELECT count(*) AS n FROM public.users WHERE role = 'customer' AND status = 'active'`)).rows[0].n);
    assert.equal(runs[0].total, active, 'the total is every active customer');
    assert.equal(ids.length, active);
    const chats = (await tx.query(`SELECT count(*) AS n FROM public.broadcast_deliveries WHERE run_id = $1 AND chat_id IS NOT NULL`, [runs[0].id])).rows[0].n;
    assert.equal(Number(chats), 0, 'push is not Telegram');
  });
});

test('both channels make one run each; the Telegram worker never takes a push delivery', async () => {
  await asService(async (tx) => {
    await seedCustomers(tx);
    const s = await dueSchedule(tx, ['push', 'telegram']);
    await tx.call('public.broadcast_tick()');
    const runs = (await tx.query(`SELECT channel FROM public.broadcast_runs WHERE schedule_id = $1 ORDER BY channel`, [s.id])).rows.map((r) => r.channel);
    assert.deepEqual(runs, ['push', 'telegram']);
    await tx.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status IN ('pending', 'sending') AND run_id NOT IN (SELECT id FROM public.broadcast_runs WHERE schedule_id = $1)`, [s.id]);
    const taken = await tx.call('public.broadcast_claim($1)', [50]);
    for (const d of taken) assert.ok(d.chatId, 'only Telegram deliveries (with a chat)');
  });
});

test('sending: tokens per customer; no device is settled; a gone token is removed; the counts and the finish', async () => {
  await asService(async (tx) => {
    await tx.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status IN ('pending', 'sending')`);
    const t = await seedCustomers(tx);
    const s = await dueSchedule(tx, ['push'], { title: 'Salaan' });
    await tx.call('public.broadcast_tick()');
    const claimed = [];
    for (;;) {
      const batch = await tx.call('public.broadcast_push_claim($1)', [500]);
      if (!batch.length) break;
      assert.ok(batch.length <= 200, 'a batch is at most 200');
      claimed.push(...batch);
    }
    const byCustomer = (c) => claimed.find((d) => d.customerId === c.id);
    assert.equal(byCustomer(t.two).tokens.length, 2, 'both devices');
    assert.equal(byCustomer(t.two).title, 'Salaan');
    assert.equal(byCustomer(t.two).body, 'Fariin jadwal ah');
    assert.equal(byCustomer(t.none), undefined, 'no device: nothing to send');
    const none = (await tx.query(`SELECT status FROM public.broadcast_deliveries WHERE customer_id = $1`, [t.none.id])).rows[0];
    assert.equal(none.status, 'no_device');
    assert.equal(new Set(claimed.map((d) => d.id)).size, claimed.length, 'never offered twice');

    // Results: one sent, one failed because its only device was gone (and that token is removed), the rest sent.
    const goneTokens = byCustomer(t.one).tokens;
    const results = claimed.map((d) => d.customerId === t.one.id
      ? { id: d.id, ok: false, error: 'invalid_token' }
      : { id: d.id, ok: true, devices: d.tokens.length });
    await tx.call('public.broadcast_push_result($1,$2)', [JSON.stringify(results), goneTokens]);
    assert.equal(Number((await tx.query(`SELECT count(*) AS n FROM public.push_tokens WHERE token = ANY($1)`, [goneTokens])).rows[0].n), 0, 'gone tokens are removed');
    const run = (await tx.query(`SELECT * FROM public.broadcast_runs WHERE schedule_id = $1`, [s.id])).rows[0];
    assert.equal(run.status, 'done');
    assert.equal(run.failed, 1);
    assert.equal(run.skipped >= 1, true);
    assert.equal(run.sent + run.failed + run.skipped, run.total, 'sent, failed and no-device add up to the total');
    assert.equal(Number((await tx.query(`SELECT devices FROM public.broadcast_deliveries WHERE customer_id = $1 AND run_id = $2`, [t.two.id, run.id])).rows[0].devices), 2);
    // A result again changes nothing.
    const okOne = results.find((r) => r.ok);
    await tx.call('public.broadcast_push_result($1,$2)', [JSON.stringify([{ id: okOne.id, ok: false, error: 'late' }]), []]);
    assert.equal((await tx.query(`SELECT status FROM public.broadcast_deliveries WHERE id = $1`, [okOne.id])).rows[0].status, 'sent', 'a late second result changes nothing');
  });
});

test('FCM was down: the messages are released and offered again; one a day old is given up', async () => {
  await asService(async (tx) => {
    await tx.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status IN ('pending', 'sending')`);
    const t = await seedCustomers(tx);
    await dueSchedule(tx, ['push']);
    await tx.call('public.broadcast_tick()');
    // Claim in batches (at most 200 each) until this customer's message comes.
    let mine;
    const taken = [];
    for (let i = 0; i < 100 && !mine; i++) {
      const batch = await tx.call('public.broadcast_push_claim($1)', [200]);
      if (!batch.length) break;
      taken.push(...batch.map((d) => d.id));
      mine = batch.find((d) => d.customerId === t.two.id);
    }
    assert.ok(mine, 'the customer\'s message is offered');
    await tx.call('public.broadcast_push_release($1)', [taken]);
    let again;
    for (let i = 0; i < 100 && !again; i++) {
      const batch = await tx.call('public.broadcast_push_claim($1)', [200]);
      if (!batch.length) break;
      again = batch.find((d) => d.id === mine.id);
    }
    assert.ok(again, 'offered again after it was released');
    await tx.call('public.broadcast_push_release($1)', [[mine.id]]);
    await tx.query(`UPDATE public.broadcast_runs SET started_at = now() - interval '2 days' WHERE channel = 'push'`);
    await tx.call('public.broadcast_push_claim($1)', [1]);
    const row = (await tx.query(`SELECT status, error FROM public.broadcast_deliveries WHERE id = $1`, [mine.id])).rows[0];
    assert.deepEqual([row.status, row.error], ['failed', 'expired']);
  });
});

const saveArgs = (o = {}) => [o.id ?? null, o.message ?? 'Salaan', o.kind ?? 'daily', o.time ?? '08:00', o.weekday ?? null, o.monthDay ?? null, o.status ?? 'active', o.title ?? null, o.channels ?? ['push']];
const SAVE = 'public.manage_save_broadcast($1,$2,$3,$4,$5,$6,$7,$8,$9)';

test('managers choose the channels and a title; the schedule is checked; the stats say who can be reached', async () => {
  await asManager(async (tx) => {
    const push = await tx.call(SAVE, saveArgs({ title: 'Ogeysiis', message: 'Fariin' }));
    assert.deepEqual(push.channels, ['push']);
    assert.equal(push.title, 'Ogeysiis');
    const both = await tx.call(SAVE, saveArgs({ id: push.id, channels: ['telegram', 'push'], title: null }));
    assert.deepEqual(both.channels, ['push', 'telegram']);
    assert.equal(both.title, null);
    for (const channels of [[], ['sms'], ['push', 'email']]) assert.equal(await tx.refused(SAVE, saveArgs({ channels })), 'VALIDATION_ERROR', JSON.stringify(channels));
    assert.equal(await tx.refused(SAVE, saveArgs({ title: 'x'.repeat(101) })), 'VALIDATION_ERROR');
    // The old calls (without channels) still work and mean push.
    assert.deepEqual((await tx.call('public.manage_save_broadcast($1,$2,$3,$4)', [null, 'x', 'daily', '09:00'])).channels, ['push']);

    const before = (await tx.call('public.manage_broadcasts()')).stats;
    const t = await seedCustomers(tx);
    const after = (await tx.call('public.manage_broadcasts()')).stats;
    assert.equal(after.activeCustomers - before.activeCustomers, 3, 'three active customers (not the disabled one, not the staff)');
    assert.equal(after.pushReachable - before.pushReachable, 2, 'two of them have a device');
    assert.ok(t.staff.id);
  });
});

test('a test push goes to one customer by phone number, never to everyone', async () => {
  await asManager(async (tx) => {
    const t = await seedCustomers(tx);
    const r = await tx.call('public.manage_test_push($1,$2,$3)', ['Tijaabo', 'Fariin tijaabo ah', t.two.phone]);
    assert.equal(r.hasDevice, true);
    const run = (await tx.query(`SELECT * FROM public.broadcast_runs WHERE id = $1`, [r.runId])).rows[0];
    assert.deepEqual([run.is_test, run.channel, run.total, run.title], [true, 'push', 1, 'Tijaabo']);
    const d = (await tx.query(`SELECT customer_id FROM public.broadcast_deliveries WHERE run_id = $1`, [r.runId])).rows;
    assert.deepEqual(d.map((x) => x.customer_id), [t.two.id]);
    // The local nine digits work too; a number without a device says so; an unknown one is refused.
    assert.equal((await tx.call('public.manage_test_push($1,$2,$3)', [null, 'x', t.none.phone.slice(-9)])).hasDevice, false);
    assert.equal(await tx.refused('public.manage_test_push($1,$2,$3)', [null, 'x', '252699999999']), 'NOT_FOUND');
    assert.equal(await tx.refused('public.manage_test_push($1,$2,$3)', [null, 'x', t.staff.phone]), 'NOT_FOUND', 'staff are not customers');
    assert.equal(await tx.refused('public.manage_test_push($1,$2,$3)', [null, '', t.two.phone]), 'VALIDATION_ERROR');
  });
});

test('who may do it: managers only; the worker functions are for the service role only', async () => {
  const calls = [
    [SAVE, saveArgs()],
    ['public.manage_test_push($1,$2,$3)', [null, 'x', '252610000003']],
  ];
  await inTx({ sub: customerId, role: 'authenticated', aud: 'authenticated' }, async (tx) => {
    for (const [sql, params] of calls) assert.equal(await tx.refused(sql, params), 'FORBIDDEN', 'a customer is refused');
    assert.ok(await tx.refused('public.broadcast_push_claim($1)', [10]));
  });
  if (plainAgentId) {
    await inTx({ sub: plainAgentId, role: 'authenticated', aud: 'authenticated' }, async (tx) => {
      for (const [sql, params] of calls) assert.equal(await tx.refused(sql, params), 'FORBIDDEN', 'an agent without the permission is refused');
    });
  }
  for (const [role, fn] of [['anon', 'public.broadcast_push_claim(int)'], ['authenticated', 'public.broadcast_push_claim(int)'], ['authenticated', 'public.broadcast_push_result(jsonb,text[])'],
    ['authenticated', 'public.broadcast_push_release(bigint[])'], ['anon', 'public.manage_test_push(text,text,text)'], ['anon', 'private.broadcast_refresh_runs(uuid[])'],
    ['authenticated', 'private.broadcast_push_kick_if_work()']]) {
    const { rows } = await db.query(`SELECT has_function_privilege($1, $2, 'EXECUTE') AS a`, [role, fn]);
    assert.equal(rows[0].a, false, `${role} can not run ${fn}`);
  }
});

// ---------------------------------------------------------------- the worker

const fcm = { sent: [] };
const standIn = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (req.url === '/token') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ access_token: 'stand-in-access', expires_in: 3600 }));
    }
    if (req.url === '/v1/projects/baari-test/messages:send' && req.headers.authorization === 'Bearer stand-in-access') {
      const { message } = JSON.parse(body);
      fcm.sent.push(message);
      if (message.token?.startsWith('gone-')) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }));
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ name: `projects/baari-test/messages/${fcm.sent.length}` }));
    }
    res.writeHead(404).end();
  });
});

test('the worker: a due push schedule reaches every device, once; a customer without a device and a gone token are handled', async (t) => {
  const probe = await fetch(`${URL}/functions/v1/push-notifications`, { method: 'GET' }).catch(() => null);
  const secret = (await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`)).rows[0]?.decrypted_secret;
  if (probe?.status !== 403 || !SERVICE_KEY || !secret) return t.skip('push-notifications is not served');
  await new Promise((r) => standIn.listen(4996, '0.0.0.0', r));
  const made = [];
  let schedule;
  try {
    const mk = async (devices) => {
      const phone = `2526${String(seed * 10 + n++).padStart(8, '0').slice(-8)}`;
      const id = (await db.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Worker Push', private.hash_password('ChangeMe123!')) RETURNING id`, [phone])).rows[0].id;
      for (const d of devices) await db.query(`INSERT INTO public.push_tokens (token, customer_id) VALUES ($1, $2)`, [d, id]);
      made.push(id);
      return { id, devices };
    };
    const A = await mk([token(), token()]);
    const B = await mk([token('gone')]);
    const C = await mk([]);
    const D = await mk([token('gone'), token()]);
    await db.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status IN ('pending', 'sending')`);
    const title = `Salaan ${seed}`;
    schedule = (await db.query(`INSERT INTO public.broadcast_schedules (title, message, kind, send_time, status, channels, next_run_at)
                                 VALUES ($1, 'Macaamiisha sharafta leh', 'daily', '08:00', 'active', ARRAY['push'], now() - interval '1 minute') RETURNING id`, [title])).rows[0].id;
    fcm.sent.length = 0;
    const wake = () => fetch(`${URL}/functions/v1/push-notifications`, { method: 'POST', headers: { 'x-worker-secret': secret, 'Content-Type': 'application/json' }, body: '{}' });
    assert.equal((await fetch(`${URL}/functions/v1/push-notifications`, { method: 'POST', headers: { 'x-worker-secret': 'nope' }, body: '{}' })).status, 403);
    const woke = await wake();
    assert.equal(woke.status, 200);
    const reply = await woke.text();
    const where = async () => JSON.stringify({
      reply: reply.slice(0, 400),
      deliveries: (await db.query(`SELECT d.status, count(*) AS n FROM public.broadcast_deliveries d JOIN public.broadcast_runs r ON r.id = d.run_id WHERE r.schedule_id = $1 GROUP BY 1`, [schedule])).rows,
      sentSoFar: fcm.sent.length,
    });

    const mine = fcm.sent.filter((m) => m.notification?.title === title);
    const to = (tok) => mine.filter((m) => m.token === tok);
    for (const tok of A.devices) assert.equal(to(tok).length, 1, `each device once ${await where()}`);
    assert.equal(to(B.devices[0]).length, 1);
    assert.equal(to(D.devices[1]).length, 1);
    const sample = to(A.devices[0])[0];
    assert.equal(sample.notification.body, 'Macaamiisha sharafta leh');
    assert.equal(sample.data.type, 'scheduled_message');
    assert.equal(sample.android.priority, 'high', 'delivered with the app closed');

    const run = (await db.query(`SELECT * FROM public.broadcast_runs WHERE schedule_id = $1`, [schedule])).rows[0];
    assert.equal(run.status, 'done');
    const st = async (c) => (await db.query(`SELECT status, error, devices FROM public.broadcast_deliveries WHERE run_id = $1 AND customer_id = $2`, [run.id, c.id])).rows[0];
    assert.deepEqual(await st(A), { status: 'sent', error: null, devices: 2 });
    assert.equal((await st(B)).status, 'failed');
    assert.equal((await st(B)).error, 'invalid_token');
    assert.equal((await st(C)).status, 'no_device');
    assert.deepEqual([(await st(D)).status, (await st(D)).devices], ['sent', 1]);
    assert.equal(Number((await db.query(`SELECT count(*) AS n FROM public.push_tokens WHERE token = ANY($1)`, [[B.devices[0], D.devices[0]]])).rows[0].n), 0, 'gone tokens are removed');
    assert.equal(Number((await db.query(`SELECT count(*) AS n FROM public.push_tokens WHERE token = ANY($1)`, [[...A.devices, D.devices[1]]])).rows[0].n), 3, 'good tokens stay');
    assert.equal(run.sent + run.failed + run.skipped, run.total);

    // Woken again: nothing is sent twice.
    const before = fcm.sent.length;
    await wake();
    assert.equal(fcm.sent.slice(before).filter((m) => m.notification?.title === title).length, 0);
  } finally {
    standIn.close();
    if (schedule) await db.query(`DELETE FROM public.broadcast_schedules WHERE id = $1`, [schedule]);
    await db.query(`DELETE FROM public.push_tokens WHERE customer_id = ANY($1)`, [made]);
  }
});

test('a long run of customers without a device does not hide the ones with one: a claim goes on until it has something to send', async () => {
  await asService(async (tx) => {
    await tx.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status IN ('pending', 'sending')`);
    // 250 customers without a device, then one with a device (the newest customer is the last delivery).
    await tx.query(`INSERT INTO public.users (role, phone, name, password_hash, status)
                      SELECT 'customer', '252990' || lpad((${seed % 1000} * 1000 + g)::text, 6, '0'), 'No Device', private.hash_password('ChangeMe123!'), 'active'
                        FROM generate_series(1, 250) g`);
    const last = (await tx.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'With Device', private.hash_password('ChangeMe123!')) RETURNING id`,
      [`252991${String(seed % 1000 * 10 + n++).padStart(6, '0')}`])).rows[0].id;
    await tx.query(`INSERT INTO public.push_tokens (token, customer_id) VALUES ($1, $2)`, [token(), last]);
    await dueSchedule(tx, ['push']);
    await tx.call('public.broadcast_tick()');
    // The customer with a device is the newest, so after more than 100 customers without one.
    const claimed = await tx.call('public.broadcast_push_claim($1)', [100]);
    assert.ok(claimed.some((d) => d.customerId === last), 'the customer with a device is reached by one claim');
    assert.ok(claimed.every((d) => d.tokens.length > 0), 'only deliveries with a device are returned');
  });
});
