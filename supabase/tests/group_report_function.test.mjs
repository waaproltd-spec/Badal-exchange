// The BADAL AGENT group worker end to end (functions/withdrawal-alerts/index.ts, migrations/*_group_daily_report.sql): the daily
// report is sent once, in parts under Telegram's limit and escaped; the deposit / failure notices are sent once; Telegram's
// temporary failures (429, 5xx) are retried; /report answers only in the linked chat. The function runs in a child process
// (a Deno shim) against stand-ins for Telegram and PostgREST, with the real database functions. No network, no real token.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
const PORTS = { tg: 49141, rest: 49142, fn: 49143 };
const CHAT = 7_300_000_000 + Number(Date.now().toString().slice(-7));

const tg = { updates: [], calls: [], nextId: 100, fail: [] };
const readBody = async (req) => { const c = []; for await (const x of req) c.push(x); return Buffer.concat(c).toString(); };
const listen = (server, port) => new Promise((r) => server.listen(port, '127.0.0.1', r));

const telegram = http.createServer(async (req, res) => {
  const b = JSON.parse((await readBody(req)) || '{}');
  const method = req.url.split('/').pop();
  const f = method === 'sendMessage' ? tg.fail.shift() : null;
  if (f) { res.writeHead(f.status, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ ok: false, description: f.text, parameters: f.parameters })); }
  tg.calls.push({ method, body: b });
  const reply = (result) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: true, result })); };
  if (method === 'getUpdates') return reply(tg.updates.filter((u) => u.update_id >= (b.offset ?? 0)));
  if (method === 'sendMessage') return reply({ message_id: tg.nextId++, chat: { id: b.chat_id } });
  if (method === 'editMessageText') return reply({ message_id: b.message_id });
  res.writeHead(404).end();
});
// PostgREST stand-in: the function's rpc calls, run as the service role on the real database.
const rest = http.createServer(async (req, res) => {
  const fn = req.url.split('/').pop();
  const args = JSON.parse((await readBody(req)) || '{}');
  const send = (code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
  if (fn === 'platform_worker_check') return send(200, true);
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`);
    const keys = Object.keys(args);
    const r = await c.query(`SELECT public.${fn}(${keys.map((k, i) => `${k} := $${i + 1}`).join(', ')}) AS r`,
      keys.map((k) => (args[k] !== null && typeof args[k] === 'object' && !Array.isArray(args[k]) ? JSON.stringify(args[k]) : args[k])));
    await c.query('COMMIT');
    send(200, r.rows[0].r);
  } catch (e) { await c.query('ROLLBACK'); send(400, { message: e.message }); } finally { c.release(); }
});

let child;
let saved;
let customer;
const seeded = [];
const run = async () => {
  const r = await fetch(`http://127.0.0.1:${PORTS.fn}/`, { method: 'POST', headers: { 'x-worker-secret': 'k', 'Content-Type': 'application/json' }, body: '{}' });
  return { status: r.status, body: await r.json().catch(() => null) };
};
const sent = () => tg.calls.filter((c) => c.method === 'sendMessage');
const about = (re) => sent().filter((c) => re.test(c.body.text));
let updateId = 1;

async function order(dir, status, code, minutesAgo, cents, reason = null) {
  const r = await db.query(
    `INSERT INTO public.orders (order_code, customer_id, direction, method, status, amount_cents, rate, fee_cents, net_cents, wallet_delta_cents,
       phone_number, winwin_id, created_at, updated_at, completed_at, failure_reason)
     VALUES ($1, $2, $3::public.order_direction, 'evc_plus', $4::public.order_status, $5, 1, 0, $5, 0, '61000000', 'W1',
       now() - ($6 || ' minutes')::interval, now() - ($6 || ' minutes')::interval,
       CASE WHEN $4 = 'completed' THEN now() - ($6 || ' minutes')::interval END, $7) RETURNING id`,
    [code, customer, dir, status, cents, String(minutesAgo), reason]);
  seeded.push(r.rows[0].id);
}

before(async () => {
  saved = (await db.query(`SELECT chat_id, linked_at, update_offset, summary_day FROM public.withdrawal_alert_chat`)).rows[0];
  customer = (await db.query(`SELECT id FROM public.users WHERE phone = '252610000003'`)).rows[0].id;
  await listen(telegram, PORTS.tg);
  await listen(rest, PORTS.rest);
  child = spawn('node', ['--experimental-strip-types', fileURLToPath(new URL('./group_report_harness.mjs', import.meta.url))], {
    env: { ...process.env, HARNESS_PORT: String(PORTS.fn), SUPABASE_URL: `http://127.0.0.1:${PORTS.rest}`, SUPABASE_SERVICE_ROLE_KEY: 'sb_secret_test',
      TELEGRAM_N8N_BOT_TOKEN: 'test-token', TELEGRAM_API_BASE: `http://127.0.0.1:${PORTS.tg}` },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  await new Promise((r) => child.stdout.on('data', (d) => { if (String(d).includes('ready')) r(); }));
  await db.query(`UPDATE public.withdrawal_alert_chat SET chat_id = $1, linked_at = now() - interval '2 days', update_offset = 0`, [CHAT]);
  await db.query(`UPDATE public.app_settings SET value = '0' WHERE key = 'daily_report_hour'`);                       // the morning hour has come
  await db.query(`UPDATE public.app_settings SET value = (now() - interval '1 hour')::text WHERE key = 'group_report_since'`);
  await db.query(`DELETE FROM public.daily_reports`);
  await db.query(`DELETE FROM public.group_notified`);
  await run();                                                                                                    // old alerts of the shared test database go out first
});
after(async () => {
  child?.kill();
  await new Promise((r) => telegram.close(r));
  await new Promise((r) => rest.close(r));
  await db.query(`DELETE FROM public.orders WHERE id = ANY($1)`, [seeded]).catch(() => {});
  await db.query(`UPDATE public.withdrawal_alert_chat SET chat_id = $1, linked_at = $2, update_offset = $3, summary_day = $4`,
    [saved.chat_id, saved.linked_at, saved.update_offset, saved.summary_day]);
  await db.query(`DELETE FROM public.daily_reports`);
  await db.query(`DELETE FROM public.group_notified`);
  await db.end();
});

test('the closed day is sent as a report in parts under the limit, escaped, with the deposit and failure notices; then never again', async () => {
  await order('deposit', 'completed', 'GRF1', 5, 2500);
  await order('deposit', 'failed', 'GRF2', 4, 800, 'Sahal: balance too low <b>&');
  const yesterday = (await db.query(`SELECT ((now() AT TIME ZONE 'Africa/Mogadishu')::date - 1)::text AS d`)).rows[0].d;
  const base = (await db.query(`SELECT private.report_build($1::date) AS r`, [yesterday])).rows[0].r;
  base.errors.failedOrders = Array.from({ length: 10 }, (_, i) => ({ code: `E${i}`, direction: 'withdraw', method: 'evc_plus', amount: '1.00', at: new Date().toISOString(), reason: 'x'.repeat(160) + ' <b>&' }));
  base.errors.incidents = { count: 40, list: Array.from({ length: 6 }, (_, i) => ({ direction: 'deposit', kind: 'failed', code: `I${i}`, method: 'edahab', amount: '5', at: new Date().toISOString(), reason: 'y'.repeat(160) })) };
  base.topCustomers = Array.from({ length: 5 }, (_, i) => ({ name: `Macmiil ${i}`, phone: '61••••66', deposits: '10.00', withdrawals: '5.00', volume: '15.00', count: 3 }));
  await db.query(`INSERT INTO public.daily_reports (day, data) VALUES ($1, $2) ON CONFLICT (day) DO UPDATE SET data = EXCLUDED.data, sent_at = NULL, send_attempts = 0, parts_sent = 0, claimed_at = NULL`,
    [yesterday, JSON.stringify(base)]);
  tg.calls.length = 0;
  const r = await run();
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const report = about(/WARBIXINTA MAALINTA|Top 5 macaamiil|Khaladaad iyo dhibaatooyin/);
  assert.ok(report.length >= 2, 'a long report goes in several messages');
  for (const c of sent()) assert.ok(c.body.text.length <= 4000, `a message of ${c.body.text.length} characters`);
  assert.ok(about(/WARBIXINTA MAALINTA/)[0].body.text.includes('00:00 → 23:59:59'));
  assert.equal(about(/Dhigasho guuleystay/).filter((c) => /GRF1/.test(c.body.text) && /25\.00/.test(c.body.text)).length, 1);
  assert.equal(about(/fashilmay/).filter((c) => /GRF2/.test(c.body.text) && /balance too low/.test(c.body.text)).length, 1);
  assert.ok(!sent().some((c) => /<b>&|&<b/.test(c.body.text)), 'the text of the records is escaped');
  assert.ok(sent().every((c) => c.body.chat_id === CHAT));
  const row = (await db.query(`SELECT sent_at, parts_sent FROM public.daily_reports WHERE day = $1`, [yesterday])).rows[0];
  assert.ok(row.sent_at && row.parts_sent >= 2);
  tg.calls.length = 0;
  assert.equal((await run()).status, 200);
  assert.equal(about(/WARBIXINTA MAALINTA|Top 5 macaamiil/).length, 0, 'the report is not sent twice');
  assert.equal(about(/GRF1|GRF2/).length, 0, 'the notices are not sent twice');
});

test("Telegram's temporary failures (429 with retry_after, 5xx) are retried and the notice is sent once", async () => {
  await order('deposit', 'completed', 'GRF3', 1, 700);
  tg.calls.length = 0;
  tg.fail.push({ status: 429, text: 'Too Many Requests', parameters: { retry_after: 1 } }, { status: 502, text: 'Bad Gateway' });
  assert.equal((await run()).status, 200);
  assert.equal(about(/GRF3/).length, 1);
  tg.calls.length = 0;
  await run();
  assert.equal(about(/GRF3/).length, 0);
});

test('a long Telegram outage fails the run visibly; the notice is sent later, once', async () => {
  await order('deposit', 'completed', 'GRF4', 1, 900);
  tg.calls.length = 0;
  tg.fail.push(...Array.from({ length: 40 }, () => ({ status: 502, text: 'Bad Gateway' })));
  assert.equal((await run()).status, 502);
  tg.fail.length = 0;
  tg.calls.length = 0;
  assert.equal((await run()).status, 200);
  assert.equal(about(/GRF4/).length, 1);
});

test('/report answers in the linked chat (today so far, or a saved day) and not at all in any other chat', async () => {
  const yesterday = (await db.query(`SELECT ((now() AT TIME ZONE 'Africa/Mogadishu')::date - 1)::text AS d`)).rows[0].d;
  tg.calls.length = 0;
  tg.updates.push(
    { update_id: updateId++, message: { message_id: 1, text: '/report', chat: { id: CHAT, type: 'group' } } },
    { update_id: updateId++, message: { message_id: 2, text: '/report', chat: { id: CHAT + 1, type: 'private' } } },
    { update_id: updateId++, message: { message_id: 3, text: `/report@SomeBot ${yesterday}`, chat: { id: CHAT, type: 'group' } } });
  assert.equal((await run()).status, 200);
  const mine = about(/WARBIXINTA MAALINTA/).filter((c) => c.body.chat_id === CHAT);
  assert.equal(mine.length, 2);
  assert.ok(mine.some((c) => /ilaa hadda/.test(c.body.text)), 'today is marked as not finished');
  assert.equal(sent().filter((c) => c.body.chat_id === CHAT + 1).length, 0);
});

test('/movehere in a group by the owner of the linked private chat moves the alerts there; a stranger gets no answer', async () => {
  const OWNER = CHAT;            // the linked chat is the owner's private chat: its id is the owner's id
  const GROUP = -(1_000_000_000_000 + (CHAT % 1_000_000));
  await db.query(`UPDATE public.withdrawal_alert_chat SET chat_id = $1, linked_at = now()`, [OWNER]);
  tg.calls.length = 0;
  tg.updates.push(
    { update_id: updateId++, message: { message_id: 1, text: '/movehere@SomeBot', from: { id: OWNER + 99 }, chat: { id: GROUP, type: 'supergroup', title: 'TEAM BADAL' } } },
    { update_id: updateId++, message: { message_id: 2, text: '/movehere', from: { id: OWNER }, chat: { id: OWNER, type: 'private' } } });
  assert.equal((await run()).status, 200);
  assert.equal((await db.query(`SELECT chat_id FROM public.withdrawal_alert_chat`)).rows[0].chat_id, String(OWNER), 'a stranger in the group, and the owner in a private chat, move nothing');
  assert.equal(sent().filter((c) => c.body.chat_id === GROUP).length, 0);
  tg.updates.push({ update_id: updateId++, message: { message_id: 3, text: '/movehere@SomeBot', from: { id: OWNER }, chat: { id: GROUP, type: 'supergroup', title: 'TEAM BADAL' } } });
  assert.equal((await run()).status, 200);
  assert.equal((await db.query(`SELECT chat_id, chat_name FROM public.withdrawal_alert_chat`)).rows[0].chat_id, String(GROUP));
  assert.equal(sent().filter((c) => c.body.chat_id === GROUP && /hadda halkan ayay ka imaanayaan/.test(c.body.text)).length, 1);
  await db.query(`UPDATE public.withdrawal_alert_chat SET chat_id = $1, linked_at = now() - interval '2 days'`, [CHAT]);
});
