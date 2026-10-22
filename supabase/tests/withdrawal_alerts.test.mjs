// Withdrawal alerts on Telegram (functions/withdrawal-alerts,
// migrations/*_withdrawal_alerts.sql), against a stand-in Telegram API.
//
//   Needs the local stack and the functions served with tests/.functions.env.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });

// The stand-in Telegram: queued updates and every call it got.
const tg = { updates: [], calls: [], nextId: 100 };
const standIn = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const b = body ? JSON.parse(body) : {};
    const method = req.url.split('/').pop();
    tg.calls.push({ method, body: b, url: req.url });
    const reply = (result) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: true, result })); };
    if (method === 'getUpdates') return reply(tg.updates.filter((u) => u.update_id >= (b.offset ?? 0)));
    if (method === 'sendMessage') return reply({ message_id: tg.nextId++, chat: { id: b.chat_id } });
    if (method === 'editMessageText') return reply({ message_id: b.message_id });
    res.writeHead(404).end();
  });
});

let secret;
let served = false;
let agent;
const run = async (key = secret) => {
  const res = await fetch(`${URL}/functions/v1/withdrawal-alerts`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-worker-secret': key }, body: '{}',
  });
  return { status: res.status, body: await res.json().catch(() => null) };
};
const sent = (method, chat) => tg.calls.filter((c) => c.method === method && (chat == null || c.body.chat_id === chat));
let updateId = 1;
const start = (chatId, username) => tg.updates.push({ update_id: updateId++,
  message: { message_id: 1, text: '/start', chat: { id: chatId, type: 'private', username } } });

const authEmail = (phone) => `${phone.replace(/\D/g, '')}@phone.baari.invalid`;
async function login(phone) {
  const c = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await c.auth.signInWithPassword({ email: authEmail(phone), password: PASSWORD });
  if (error) throw error;
  return c;
}
const seed = Number(Date.now().toString().slice(-6));
let n = 0;
const golisNumber = () => `90${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
async function withdrawal(amount) {
  const number = golisNumber();
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Alert Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 10000 FROM u`, [`252${number}`, PASSWORD]);
  const customer = await login(`252${number}`);
  const { data, error } = await customer.rpc('customer_create_withdrawal', {
    p_method: 'golis', p_amount: String(amount), p_phone_number: number, p_idempotency_key: randomUUID() });
  if (error) throw error;
  return { customer, w: data, number };
}

const CHAT = 5550001;
const OTHER = 5550002;

before(async () => {
  await new Promise((r) => standIn.listen(4994, '0.0.0.0', r));
  secret = (await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`)).rows[0]?.decrypted_secret;
  const probe = await fetch(`${URL}/functions/v1/withdrawal-alerts`, { method: 'GET' }).catch(() => null);
  served = Boolean(secret) && probe?.status === 403;
  agent = await login('252610000002');
  await db.query(`UPDATE withdrawal_alert_chat SET chat_id = NULL, chat_name = NULL, linked_at = NULL, update_offset = 0,
                    summary_day = (now() AT TIME ZONE 'Africa/Mogadishu')::date`);
  await db.query(`DELETE FROM withdrawal_alerts`);
});
beforeEach(() => { tg.calls.length = 0; });
after(async () => {
  standIn.close();
  await db.query(`UPDATE withdrawal_alert_chat SET chat_id = NULL, chat_name = NULL, linked_at = NULL, update_offset = 0`);
  await db.end();
});

test('the worker secret is required', async (t) => {
  if (!served) return t.skip('withdrawal-alerts is not served');
  assert.equal((await run('wrong')).status, 403);
  assert.equal(tg.calls.length, 0);
});

test('nothing is sent before a chat is linked; the first /start links, another chat is refused', async (t) => {
  if (!served) return t.skip('withdrawal-alerts is not served');
  await withdrawal(3); // before linking: never announced
  let r = await run();
  assert.equal(r.body.linked, false);
  assert.equal(sent('sendMessage').length, 0);

  start(CHAT, 'badal_owner');
  start(OTHER, 'stranger');
  r = await run();
  assert.equal(r.status, 200);
  assert.match(sent('sendMessage', CHAT)[0].body.text, /alerts are on/);
  assert.match(sent('sendMessage', OTHER)[0].body.text, /not allowed/);
  assert.equal(sent('sendMessage').length, 2, 'the earlier withdrawal is not announced');
  const m = (await agent.rpc('manage_withdrawal_alerts')).data;
  assert.equal(m.linked, true);
  assert.match(m.chatName, /badal_owner/);

  // Updates are read once (offset kept).
  tg.calls.length = 0;
  await run();
  assert.equal(sent('sendMessage').length, 0);
});

test('a new withdrawal is announced once with code, number and exact amount; never a secret', async (t) => {
  if (!served) return t.skip('withdrawal-alerts is not served');
  const { w, number } = await withdrawal(7.5);
  await run();
  await run();
  const msgs = sent('sendMessage', CHAT).filter((c) => c.body.text.includes(w.orderCode));
  assert.equal(msgs.length, 1, 'announced once');
  const text = msgs[0].body.text;
  assert.match(text, /Withdrawal waiting/);
  assert.match(text, /\$7\.50/);
  assert.ok(text.includes(number));
  assert.ok(!/pin|password|token|secret/i.test(text));
  assert.ok(!tg.calls.some((c) => JSON.stringify(c.body).includes('TEST-not-a-real-token')));
});

test('completed: the message turns into "paid" with the reference; failed shows the reason', async (t) => {
  if (!served) return t.skip('withdrawal-alerts is not served');
  const a = await withdrawal(4);
  const b = await withdrawal(5);
  await run();
  await db.query(`SELECT private.complete_withdraw_order($1, 'Sahal 7509990001', NULL, NULL)`, [a.w.id]);
  await db.query(`SELECT private.fail_order($1, 'Number not registered', NULL, NULL)`, [b.w.id]);
  tg.calls.length = 0;
  await run();
  const edits = sent('editMessageText', CHAT);
  const paid = edits.find((e) => e.body.text.includes(a.w.orderCode));
  assert.match(paid.body.text, /Withdrawal paid/);
  assert.match(paid.body.text, /Sahal 7509990001/);
  const failed = edits.find((e) => e.body.text.includes(b.w.orderCode));
  assert.match(failed.body.text, /failed/);
  assert.match(failed.body.text, /Number not registered/);
  tg.calls.length = 0;
  await run();
  assert.equal(sent('editMessageText').length, 0, 'edited once');
});

test('still waiting after 15 minutes: one reminder', async (t) => {
  if (!served) return t.skip('withdrawal-alerts is not served');
  const { w } = await withdrawal(2);
  await run();
  await db.query(`UPDATE orders SET created_at = now() - interval '16 minutes' WHERE id = $1`, [w.id]);
  tg.calls.length = 0;
  await run();
  await run();
  const reminders = sent('sendMessage', CHAT).filter((c) => c.body.text.includes(`${w.orderCode} is still waiting`));
  assert.equal(reminders.length, 1);
});

test('a Sahal transfer that matched no withdrawal is reported once', async (t) => {
  if (!served) return t.skip('withdrawal-alerts is not served');
  const id = `T${Date.now()}`;
  // Read 3 minutes ago (time for the matcher), after the chat was linked.
  await db.query(`UPDATE withdrawal_alert_chat SET linked_at = now() - interval '10 minutes' WHERE id`);
  await db.query(`INSERT INTO merchant_transactions (provider, transaction_id, raw, first_seen_at, payer_phone, amount_cents, paid_at, match_status, direction)
                  VALUES ('golis', $1, '{}', now() - interval '3 minutes', '619990000', 300, now(), 'unmatched', 'out')`, [id]);
  await run();
  await run();
  const warn = sent('sendMessage', CHAT).filter((c) => c.body.text.includes(id));
  assert.equal(warn.length, 1);
  assert.match(warn[0].body.text, /matched no withdrawal/);
  assert.match(warn[0].body.text, /\$3\.00/);
});

test('only managers see or unlink the chat; the worker functions are service-only', async (t) => {
  const number = golisNumber();
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Alert Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 0 FROM u`, [`252${number}`, PASSWORD]);
  const customer = await login(`252${number}`);
  assert.ok((await customer.rpc('manage_withdrawal_alerts')).error);
  for (const fn of ['withdrawal_alerts_todo', 'withdrawal_alerts_state']) {
    assert.ok((await customer.rpc(fn)).error, `${fn} refused`);
    assert.ok((await agent.rpc(fn)).error, `${fn} refused for staff too`);
  }
  for (const table of ['withdrawal_alert_chat', 'withdrawal_alerts']) {
    const { data, error } = await customer.from(table).select('*');
    assert.ok(error || data.length === 0);
  }
  if (!served) return;
  const off = (await agent.rpc('manage_withdrawal_alerts', { p_unlink: true })).data;
  assert.equal(off.linked, false);
  start(OTHER, 'new_owner');
  tg.calls.length = 0;
  await run();
  assert.match(sent('sendMessage', OTHER)[0].body.text, /alerts are on/);
});
