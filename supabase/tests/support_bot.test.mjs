// BADAL AI Support Bot (functions/support-bot, migrations/*_support_bot.sql),
// against stand-in Telegram and AI servers: text only, Somali only, no voice,
// audio, photos or screenshots; the chat is linked by Wallet ID and the
// customer's own contact; orders are read; "La xiriir Admin" is a direct Telegram link, nothing is stored.
//
//   Needs the local stack and the functions served with tests/.functions.env.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const SECRET = 'test-support-webhook-secret'; // tests/player_lookup.env
const db = new pg.Pool({ connectionString: DATABASE_URL });
const opts = { auth: { persistSession: false, autoRefreshToken: false } };

// The stand-in Telegram (4993) and AI (4992): every call they got.
const tg = { calls: [], files: new Map(), members: new Map() };
const ai = { calls: [], reply: 'Sawirkan wuxuu muujinayaa in lacag-bixintu dib u dhacday. Fadlan sug 5 daqiiqo.' };
const telegram = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const method = req.url.split('/').pop();
    if (req.url.includes('/file/bot')) {
      tg.calls.push({ method: 'download', url: req.url });
      res.writeHead(200, { 'Content-Type': 'image/jpeg' });
      return res.end(Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
    }
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
    tg.calls.push({ method, body });
    let result = true;
    if (method === 'sendMessage') result = { message_id: 1 };
    if (method === 'getChatMember') result = { status: tg.members.get(body.user_id) ?? 'member' };
    if (method === 'getFile') result = { file_path: 'photos/f1.jpg', file_size: tg.files.get(body.file_id) ?? 1000 };
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, result }));
  });
});
const aiServer = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    ai.calls.push({ url: req.url, headers: req.headers, body: JSON.parse(Buffer.concat(chunks).toString()) });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ content: [{ type: 'text', text: ai.reply }] }));
  });
});

let served = false;
let manager;
const seed = Number(Date.now().toString().slice(-6));
let n = 0;
let chatId = 700000000 + seed;
const nextChat = () => chatId++;

async function login(phone) {
  const c = createClient(URL, ANON_KEY, opts);
  const { error } = await c.auth.signInWithPassword({ email: `${phone.replace(/\D/g, '')}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}
async function customer() {
  const number = `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Support Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 5000 FROM u RETURNING customer_id`,
    [`252${number}`, PASSWORD]);
  const { rows: [w] } = await db.query(`SELECT wallet_code FROM wallets WHERE customer_id = $1`, [u.customer_id]);
  return { id: u.customer_id, phone: `252${number}`, wallet: w.wallet_code };
}

/** One update to the webhook; returns the HTTP status and the calls it made. */
async function send(update, secret = SECRET) {
  const before = tg.calls.length;
  const aiBefore = ai.calls.length;
  const res = await fetch(`${URL}/functions/v1/support-bot`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-telegram-bot-api-secret-token': secret }, body: JSON.stringify(update),
  });
  await res.text();
  return { status: res.status, calls: tg.calls.slice(before), ai: ai.calls.slice(aiBefore) };
}
let updateId = 1;
const message = (chat, extra) => ({ update_id: updateId++, message: { message_id: updateId, chat: { id: chat, type: 'private' }, from: { id: chat }, ...extra } });
const callback = (chat, data) => ({ update_id: updateId++, callback_query: { id: `cb${updateId}`, data, from: { id: chat }, message: { chat: { id: chat, type: 'private' } } } });
const texts = (r) => r.calls.filter((c) => c.method === 'sendMessage').map((c) => c.body.text);

/** A chat linked to a new customer through the real steps. */
async function linked() {
  const c = await customer();
  const chat = nextChat();
  await send(message(chat, { text: '/start' }));
  await send(message(chat, { text: c.wallet }));
  const r = await send(message(chat, { contact: { phone_number: `+${c.phone}`, user_id: chat } }));
  assert.match(texts(r).join('\n'), /Akoonkaaga waa la xaqiijiyay/);
  return { ...c, chat };
}

before(async () => {
  await new Promise((r) => telegram.listen(4993, '0.0.0.0', r));
  await new Promise((r) => aiServer.listen(4992, '0.0.0.0', r));
  manager = await login('252610000002');
  const res = await fetch(`${URL}/functions/v1/support-bot`, { method: 'POST', body: '{}' }).catch(() => null);
  served = res?.status === 403;
});
after(async () => {
  if (verificationWas !== undefined && verificationWas !== null) await db.query(`UPDATE app_settings SET value = $1 WHERE key = 'withdrawal_verification'`, [verificationWas]);
  telegram.close();
  aiServer.close();
  await db.end();
});

test('only Telegram (the webhook secret) can call it', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  assert.equal((await send({}, 'wrong')).status, 403);
  const noHeader = await fetch(`${URL}/functions/v1/support-bot`, { method: 'POST', body: '{}' });
  assert.equal(noHeader.status, 403);
});

test('setup (opened once in a browser with the webhook secret) registers the webhook and the menu with Telegram', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const refused = await fetch(`${URL}/functions/v1/support-bot/setup?key=wrong`);
  assert.equal(refused.status, 403);
  assert.equal((await fetch(`${URL}/functions/v1/support-bot/setup`)).status, 403);
  const before = tg.calls.length;
  const res = await fetch(`${URL}/functions/v1/support-bot/setup?key=${SECRET}`);
  assert.equal(res.status, 200);
  const calls = tg.calls.slice(before);
  const hook = calls.find((c) => c.method === 'setWebhook');
  assert.match(hook.body.url, /\/functions\/v1\/support-bot$/);
  assert.equal(hook.body.secret_token, SECRET);
  assert.deepEqual(hook.body.allowed_updates, ['message', 'callback_query']);
  assert.ok(calls.some((c) => c.method === 'setMyCommands'));
});

test('linking: the Wallet ID, then the customer\'s own contact with the registered number', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await customer();
  const chat = nextChat();
  let r = await send(message(chat, { text: '/start' }));
  assert.match(texts(r)[0], /BADAL AI Support Bot/);
  assert.match(texts(r)[0], /Wallet ID/);
  assert.match(texts(r)[0], /tusaale: BE000000\)/, 'the example is not a real Wallet ID');

  // A Wallet ID that does not exist is answered exactly like one that does: it can not be found out.
  r = await send(message(chat, { text: 'BE000000' }));
  const wrongAnswer = r.calls.find((x) => x.method === 'sendMessage');
  assert.match(wrongAnswer.body.text, /la wadaag lambarkaaga Telegram/);
  assert.equal(wrongAnswer.body.reply_markup.keyboard[0][0].request_contact, true);

  r = await send(message(chat, { text: c.wallet }));
  const ask = r.calls.find((x) => x.method === 'sendMessage');
  assert.equal(ask.body.text, wrongAnswer.body.text, 'the same answer');
  assert.deepEqual(ask.body.reply_markup, wrongAnswer.body.reply_markup);
  assert.match(ask.body.text, /la wadaag lambarkaaga Telegram/);
  assert.equal(ask.body.reply_markup.keyboard[0][0].request_contact, true);

  // With a Wallet ID that does not exist, nobody can finish: even their own contact is refused.
  const other = await customer();
  const ghost = nextChat();
  await send(message(ghost, { text: '/start' }));
  await send(message(ghost, { text: 'BE000001' }));
  const ghostContact = await send(message(ghost, { contact: { phone_number: `+${other.phone}`, user_id: ghost } }));
  assert.match(texts(ghostContact)[0], /Waan ku xaqiijin kari waynay/);
  assert.equal((await db.query(`SELECT customer_id FROM support_chats WHERE chat_id = $1`, [ghost])).rows[0].customer_id, null);

  // Someone else's contact, or another number: refused.
  r = await send(message(chat, { contact: { phone_number: `+${c.phone}`, user_id: 1 } }));
  assert.match(texts(r)[0], /adiga u gaarka ah/);
  r = await send(message(chat, { contact: { phone_number: '+252619999999', user_id: chat } }));
  assert.match(texts(r)[0], /Waan ku xaqiijin kari waynay/);
  assert.equal((await db.query(`SELECT customer_id FROM support_chats WHERE chat_id = $1`, [chat])).rows[0].customer_id, null);

  // The Wallet ID again, then the right contact.
  await send(message(chat, { text: c.wallet }));
  r = await send(message(chat, { contact: { phone_number: `+${c.phone}`, user_id: chat } }));
  assert.match(texts(r).join('\n'), /Akoonkaaga waa la xaqiijiyay/);
  const menuMessage = r.calls.filter((x) => x.method === 'sendMessage').pop();
  assert.ok(menuMessage.body.reply_markup.inline_keyboard.flat().some((b) => b.text.includes('La xiriir Admin')));
  assert.equal((await db.query(`SELECT customer_id FROM support_chats WHERE chat_id = $1`, [chat])).rows[0].customer_id, c.id);
});

test('too many wrong Wallet IDs: the chat is stopped for an hour', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const chat = nextChat();
  await send(message(chat, { text: '/start' }));
  for (let i = 0; i < 5; i++) await send(message(chat, { text: `BE00000${i}` }));
  const r = await send(message(chat, { text: 'BE000009' }));
  assert.match(texts(r)[0], /Isku-day badan/);
});

test('text only: voice, audio, photos, screenshots, videos and files are refused in Somali; nothing downloaded or sent to the AI', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await linked();
  const unlinkedChat = nextChat();
  const voiceCases = [
    ['voice', { voice: { file_id: 'v1', duration: 3 } }],
    ['audio', { audio: { file_id: 'a1' } }],
    ['video_note', { video_note: { file_id: 'n1' } }],
    ['audio file', { document: { file_id: 'd1', mime_type: 'audio/ogg' } }],
  ];
  for (const [name, extra] of voiceCases) {
    for (const chat of [c.chat, unlinkedChat]) {
      const r = await send(message(chat, extra));
      assert.equal(r.status, 200, name);
      assert.match(texts(r)[0], /Codka \(voice\) iyo faylasha cod ah lama aqbalo/, name);
      assert.ok(!r.calls.some((x) => x.method === 'getFile' || x.method === 'download'), `${name}: not downloaded`);
      assert.equal(r.ai.length, 0, `${name}: not processed`);
    }
  }
  const otherCases = [
    ['photo', { photo: [{ file_id: 'small', file_size: 100 }, { file_id: 'big', file_size: 2000 }] }],
    ['screenshot with a caption', { photo: [{ file_id: 'big' }], caption: 'Error: payment failed' }],
    ['image file', { document: { file_id: 'doc1', mime_type: 'image/png' } }],
    ['video', { video: { file_id: 'x1' } }],
    ['pdf', { document: { file_id: 'p1', mime_type: 'application/pdf' } }],
    ['sticker', { sticker: { file_id: 's1' } }],
  ];
  for (const [name, extra] of otherCases) {
    for (const chat of [c.chat, unlinkedChat]) {
      const r = await send(message(chat, extra));
      assert.match(texts(r)[0], /qoraal<\/b> kaliya/, name);
      assert.match(texts(r)[0], /Sawirada \(screenshots\)/, name);
      assert.ok(!r.calls.some((x) => x.method === 'getFile' || x.method === 'download'), `${name}: not downloaded`);
      assert.equal(r.ai.length, 0, `${name}: not sent to the AI`);
    }
  }
});

test('a text question goes to the AI with the customer\'s latest orders; Somali only', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await linked();
  await db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
     VALUES ($1, $2, 'withdraw', 'evc_plus', 'pending', 1000, 1, 1000, -1000)`, [`EXSB${seed}${n++}`, c.id]);
  const r = await send(message(c.chat, { text: 'Bixintaydii meeshee mareysa?' }));
  assert.equal(r.ai.length, 1);
  assert.equal(typeof r.ai[0].body.messages[0].content, 'string', 'text only, no image block');
  assert.equal(r.ai[0].headers['x-api-key'], 'test-not-a-real-key');
  assert.match(r.ai[0].body.system, /Write EVERY answer in Somali/);
  assert.match(r.ai[0].body.system, /Never answer in English, Arabic or any other language/);
  assert.match(r.ai[0].body.system, /Never ask for, accept or repeat a PIN/);
  assert.match(r.ai[0].body.system, /only receive text/);
  assert.match(r.ai[0].body.system, /latest orders/);
  assert.match(r.ai[0].body.system, /withdrawal, EVC Plus, \$10\.00, status pending/);
  assert.match(texts(r)[0], /Sawirkan wuxuu muujinayaa/);
});

test('the AI is limited: 20 answers an hour a chat; not linked: no AI at all', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await linked();
  for (let i = 0; i < 20; i++) await send(message(c.chat, { text: `su'aal ${i}` }));
  const r = await send(message(c.chat, { text: 'mid kale' }));
  assert.match(texts(r)[0], /Su’aalo badan/);
  assert.equal(r.ai.length, 0);
  const stranger = nextChat();
  const s = await send(message(stranger, { text: 'ma i caawin kartaa?' }));
  assert.equal(s.ai.length, 0);
  const p = await send(message(stranger, { photo: [{ file_id: 'p9' }] }));
  assert.equal(p.ai.length, 0);
  assert.ok(!p.calls.some((x) => x.method === 'getFile'));
});

test('Haraagayga: the linked customer\'s balance in Somali, read only; not linked: nothing', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await linked();
  const menuResult = await send(message(c.chat, { text: '/menu' }));
  const buttons = menuResult.calls.find((x) => x.method === 'sendMessage').body.reply_markup.inline_keyboard.flat();
  assert.ok(buttons.some((b) => b.callback_data === 'balance' && b.text.includes('Haraagayga')));

  await db.query(`UPDATE wallets SET available_cents = 12345, pending_cents = 250 WHERE customer_id = $1`, [c.id]);
  const before = (await db.query(`SELECT available_cents, pending_cents FROM wallets WHERE customer_id = $1`, [c.id])).rows[0];
  const r = await send(callback(c.chat, 'balance'));
  const text = texts(r)[0];
  assert.match(text, /Haraagayga/);
  assert.match(text, /Haraaga la isticmaali karo: <b>\$123\.45<\/b>/);
  assert.match(text, /Lacagta la sugayo: \$2\.50/);
  assert.equal(r.ai.length, 0);
  assert.deepEqual((await db.query(`SELECT available_cents, pending_cents FROM wallets WHERE customer_id = $1`, [c.id])).rows[0], before, 'read only');

  // A chat that is not linked gets no balance, and no number.
  const stranger = nextChat();
  await send(message(stranger, { text: '/start' }));
  const s = await send(callback(stranger, 'balance'));
  assert.match(texts(s)[0], /geli <b>Wallet ID<\/b>/);
  assert.ok(!/\$/.test(texts(s)[0]), 'no amount shown');
  // Only the bot can read it.
  const cu = await login(c.phone);
  const { error } = await cu.rpc('support_balance', { p_chat: c.chat });
  assert.ok(error, 'refused to a customer');
});

test('orders: the latest are listed in Somali; a deposit that is not completed is not shown', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await linked();
  const add = (direction, status, cents) => db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
     VALUES ($1, $2, $3, 'evc_plus', $4, $5, 1, $5, 0) RETURNING order_code`, [`EXSO${seed}${n++}`, c.id, direction, status, cents]);
  const done = (await add('deposit', 'completed', 700)).rows[0].order_code;
  const waiting = (await add('deposit', 'pending', 900)).rows[0].order_code;
  const wd = (await add('withdraw', 'failed', 500)).rows[0].order_code;
  const r = await send(callback(c.chat, 'orders'));
  const text = texts(r).join('\n');
  assert.ok(text.includes(done) && text.includes(wd));
  assert.ok(!text.includes(waiting), 'a waiting deposit is not listed');
  assert.match(text, /Waa dhammaystiray/);
  assert.match(text, /Waa fashilmay/);
  const dep = await send(callback(c.chat, 'deposit'));
  assert.ok(texts(dep).join('\n').includes(done));
  assert.ok(!texts(dep).join('\n').includes(wd));
});

test('La xiriir Admin: a direct Telegram chat with @Badalexchangeadmin; nothing is stored, no ticket exists', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await linked();
  const count = async () => ({
    events: Number((await db.query(`SELECT count(*) AS n FROM support_events WHERE chat_id = $1`, [c.chat])).rows[0].n),
    chats: JSON.stringify((await db.query(`SELECT * FROM support_chats WHERE chat_id = $1`, [c.chat])).rows),
  });
  // The menu's own button is the link: one tap opens the admin's chat.
  const menuResult = await send(message(c.chat, { text: '/menu' }));
  const buttons = menuResult.calls.find((x) => x.method === 'sendMessage').body.reply_markup.inline_keyboard.flat();
  const admin = buttons.find((b) => b.text.includes('La xiriir Admin'));
  assert.equal(admin.url, 'https://t.me/Badalexchangeadmin');
  assert.equal(admin.callback_data, undefined, 'a link, not a bot step');

  // A menu sent earlier still has the old button: it gives the same link, and stores nothing.
  const before = await count();
  const r = await send(callback(c.chat, 'admin'));
  assert.match(texts(r)[0], /La xiriir Admin/);
  assert.match(texts(r)[0], /@Badalexchangeadmin/);
  assert.equal(r.calls.find((x) => x.method === 'sendMessage').body.reply_markup.inline_keyboard[0][0].url, 'https://t.me/Badalexchangeadmin');
  assert.deepEqual(await count(), before, 'nothing was stored');
  assert.equal(r.ai.length, 0);

  // What the customer writes next is not kept as a complaint: it is an ordinary question.
  const next = await send(message(c.chat, { text: 'Lacagtaydii dhigasho ah ma soo gelin' }));
  assert.equal(next.ai.length, 1);
  const { rows: [t1] } = await db.query(`SELECT to_regclass('public.support_tickets') AS t`);
  assert.equal(t1.t, null, 'there is no ticket table');
  const { rows: fns } = await db.query(
    `SELECT proname FROM pg_proc WHERE proname IN ('support_create_ticket', 'manage_support_tickets', 'manage_close_support_ticket')`);
  assert.deepEqual(fns, [], 'there are no ticket functions');
  const { rows: text } = await db.query(
    `SELECT count(*)::int AS n FROM support_chats WHERE to_jsonb(support_chats)::text LIKE '%dhigasho ah ma soo gelin%'`);
  assert.equal(text[0].n, 0, 'no message text is stored');
});

test('the database functions are for the bot only', async (t) => {
  const customerRow = await customer();
  const cu = await login(customerRow.phone);
  for (const [fn, args] of [
    ['support_session', { p_chat: 1 }],
    ['support_orders', { p_chat: 1 }],
    ['support_ai_allowed', { p_chat: 1 }],
    ['support_admin_chat', {}],
    ['support_admin_link', { p_chat: 1 }],
    ['support_approval_request', { p_chat: 1, p_account: 'BX00000000' }],
  ]) {
    const { error } = await cu.rpc(fn, args);
    assert.ok(error, `${fn} is refused to a customer`);
  }
  const { error: e2 } = await cu.from('support_chats').select('*');
  assert.ok(e2, 'the chats are not readable');
});

test('no voice, audio or image code exists in the bot', async () => {
  const { readFileSync } = await import('node:fs');
  const code = readFileSync(new globalThis.URL('../functions/support-bot/index.ts', import.meta.url), 'utf8');
  for (const bad of ['support_create_ticket', '#BADAL', 'awaiting_ticket', 'sendVoice', 'sendAudio', 'sendVideoNote', 'sendPhoto', 'speech', 'transcri', 'whisper', 'text-to-speech', 'getFile', 'base64']) {
    assert.ok(!code.includes(bad), `${bad} must not appear`);
  }
});

test('withdrawal approval from the Customer App: /start fasax_<Customer ID> reaches the administrator; nothing but a count is stored', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await customer();
  const code = `BX${c.id.replace(/-/g, '').slice(0, 8).toUpperCase()}`;
  const adminChat = nextChat();
  // The administrator's Telegram account starts the bot once.
  const linkedAdmin = await send({ update_id: updateId++, message: { message_id: updateId, chat: { id: adminChat, type: 'private' }, from: { id: adminChat, username: 'Badalexchangeadmin' }, text: '/start' } });
  assert.match(texts(linkedAdmin).join('\n'), /Waa lagu xaqiijiyay maamule/);
  assert.equal(Number((await db.query(`SELECT chat_id FROM support_admin`)).rows[0].chat_id), adminChat);

  // Somebody else with /start is not the administrator.
  const other = nextChat();
  await send(message(other, { text: '/start' }));
  assert.equal(Number((await db.query(`SELECT chat_id FROM support_admin`)).rows[0].chat_id), adminChat);

  // The customer taps Telegram in the app.
  const chat = nextChat();
  const was = (await db.query(`SELECT value FROM app_settings WHERE key = 'withdrawal_verification'`)).rows[0]?.value;
  await db.query(`INSERT INTO app_settings (key, value) VALUES ('withdrawal_verification', 'on') ON CONFLICT (key) DO UPDATE SET value = 'on'`);
  t.after(() => db.query(`UPDATE app_settings SET value = $1 WHERE key = 'withdrawal_verification'`, [was ?? 'on']));
  const r = await send({ update_id: updateId++, message: { message_id: updateId, chat: { id: chat, type: 'private' }, from: { id: chat, username: 'macaamiil1' }, text: `/start fasax_${code}` } });
  assert.match(texts(r).find((x) => /gaarsiiyay maamulka/.test(x)) ?? '', /gaarsiiyay maamulka/);
  const toAdmin = r.calls.find((x) => x.method === 'sendMessage' && x.body.chat_id === adminChat);
  assert.ok(toAdmin, 'the administrator got the request');
  assert.match(toAdmin.body.text, /Codsi fasax bixin/);
  assert.ok(toAdmin.body.text.includes(code));
  assert.ok(toAdmin.body.text.includes(`+${c.phone}`));
  assert.ok(toAdmin.body.text.includes('@macaamiil1'));
  assert.doesNotMatch(toAdmin.body.text, /pin|password/i);

  // An unknown ID: nothing reaches the administrator.
  const bad = await send(message(nextChat(), { text: '/start fasax_BX00000000' }));
  assert.match(texts(bad).join('\n'), /lama helin/);
  assert.equal(bad.calls.filter((x) => x.body?.chat_id === adminChat).length, 0);

  // Five an hour a chat.
  const spam = nextChat();
  for (let i = 0; i < 5; i++) await send(message(spam, { text: `/start fasax_${code}` }));
  const limited = await send(message(spam, { text: `/start fasax_${code}` }));
  assert.match(texts(limited).join('\n'), /Codsiyo badan/);
});

let verificationWas; // restored when the file is done

/** An administrator's chat linked to the bot, and a customer's request waiting with its two buttons. */
async function waitingRequest() {
  const adminChat = nextChat();
  await send({ update_id: updateId++, message: { message_id: updateId, chat: { id: adminChat, type: 'private' }, from: { id: adminChat, username: 'Badalexchangeadmin' }, text: '/start' } });
  const c = await customer();
  const code = `BX${c.id.replace(/-/g, '').slice(0, 8).toUpperCase()}`;
  const chat = nextChat();
  if (verificationWas === undefined) verificationWas = (await db.query(`SELECT value FROM app_settings WHERE key = 'withdrawal_verification'`)).rows[0]?.value ?? null;
  await db.query(`INSERT INTO app_settings (key, value) VALUES ('withdrawal_verification', 'on') ON CONFLICT (key) DO UPDATE SET value = 'on'`);
  await db.query(`DELETE FROM withdrawal_approvals WHERE customer_id = $1`, [c.id]);
  const r = await send({ update_id: updateId++, message: { message_id: updateId, chat: { id: chat, type: 'private' }, from: { id: chat, username: 'macaamiil2' }, text: `/start fasax_${code}` } });
  const toAdmin = r.calls.find((x) => x.method === 'sendMessage' && x.body.chat_id === adminChat);
  assert.ok(toAdmin, 'the administrator got the request');
  const buttons = toAdmin.body.reply_markup.inline_keyboard.flat();
  assert.equal(buttons.length, 2, 'two buttons: Approve and Reject');
  return { c, chat, adminChat, approve: buttons[0].callback_data, reject: buttons[1].callback_data };
}
const press = (who, data) => send({ update_id: updateId++, callback_query: { id: `cb${updateId}`, data, from: { id: who }, message: { message_id: 1, text: 'Codsi fasax bixin', chat: { id: who, type: 'private' } } } });
const dbRequest = async (customerId) => (await db.query(`SELECT * FROM support_approval_requests WHERE customer_id = $1 ORDER BY created_at DESC LIMIT 1`, [customerId])).rows[0];
const approvalStatus = async (customerId) => (await db.query(`SELECT status FROM withdrawal_approvals WHERE customer_id = $1`, [customerId])).rows[0]?.status;

test('Approve in Telegram: the account is approved, the customer is told, the admin\'s Telegram ID and the time are kept', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const w = await waitingRequest();
  assert.equal((await dbRequest(w.c.id)).status, 'pending');
  const r = await press(w.adminChat, w.approve);
  assert.equal(await approvalStatus(w.c.id), 'approved');
  const row = await dbRequest(w.c.id);
  assert.equal(row.status, 'approved');
  assert.equal(Number(row.decided_by_tg), w.adminChat);
  assert.ok(row.decided_at, 'the time is recorded');
  const told = r.calls.find((x) => x.method === 'sendMessage' && x.body.chat_id === w.chat);
  assert.match(told.body.text, /Akoonkaaga waa la fasaxay/);
  assert.ok(r.calls.find((x) => x.method === 'editMessageText'), 'the admin message shows the outcome');
  assert.deepEqual(r.calls.find((x) => x.method === 'editMessageText').body.reply_markup.inline_keyboard, [], 'the buttons are gone');
  // The customer can withdraw now (as the Agent App's approval does).
  const cu = await login(w.c.phone);
  const { data } = await cu.rpc('customer_withdrawal_access');
  assert.equal(data.allowed, true);
});

test('Reject in Telegram: the account stays blocked from withdrawing, the customer is told', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const w = await waitingRequest();
  const r = await press(w.adminChat, w.reject);
  assert.equal(await approvalStatus(w.c.id), 'rejected');
  assert.equal((await dbRequest(w.c.id)).status, 'rejected');
  const told = r.calls.find((x) => x.method === 'sendMessage' && x.body.chat_id === w.chat);
  assert.match(told.body.text, /lama aqbalin/);
  const cu = await login(w.c.phone);
  const { data } = await cu.rpc('customer_withdrawal_access');
  assert.equal(data.allowed, false);
});

test('a request is decided once: a second press (either button) changes nothing and tells nobody', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const w = await waitingRequest();
  await press(w.adminChat, w.approve);
  const before = await dbRequest(w.c.id);
  for (const data of [w.approve, w.reject]) {
    const again = await press(w.adminChat, data);
    assert.equal(again.calls.filter((x) => x.method === 'sendMessage').length, 0, 'the customer is not told again');
    assert.ok(again.calls.find((x) => x.method === 'answerCallbackQuery' && /horey/.test(x.body.text ?? '')));
  }
  const after = await dbRequest(w.c.id);
  assert.equal(after.status, 'approved');
  assert.equal(String(after.decided_at), String(before.decided_at));
  assert.equal(await approvalStatus(w.c.id), 'approved');
});

test('only the linked administrator can decide: anybody else is refused and nothing changes', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const w = await waitingRequest();
  const stranger = nextChat();
  for (const data of [w.approve, w.reject]) {
    const r = await press(stranger, data);
    assert.equal(r.calls.filter((x) => x.method === 'sendMessage').length, 0);
    assert.ok(r.calls.find((x) => x.method === 'answerCallbackQuery' && /ogol/.test(x.body.text ?? '')));
  }
  assert.equal((await dbRequest(w.c.id)).status, 'pending');
  assert.notEqual(await approvalStatus(w.c.id), 'approved');
  // The customer pressing the button under their own request is a stranger too.
  await press(w.chat, w.approve);
  assert.equal((await dbRequest(w.c.id)).status, 'pending');
  // Nor can anybody call the decision from the database.
  const cu = await login(w.c.phone);
  const { error } = await cu.rpc('support_approval_decide', { p_request: (await dbRequest(w.c.id)).id, p_admin_tg: w.adminChat, p_admin_name: 'x', p_decision: 'approve', p_chat: w.adminChat });
  assert.ok(error, 'refused to a customer');
});

test('asking twice sends the administrator one request, not two', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const w = await waitingRequest();
  const code = `BX${w.c.id.replace(/-/g, '').slice(0, 8).toUpperCase()}`;
  const again = await send({ update_id: updateId++, message: { message_id: updateId, chat: { id: w.chat, type: 'private' }, from: { id: w.chat }, text: `/start fasax_${code}` } });
  assert.equal(again.calls.filter((x) => x.body?.chat_id === w.adminChat).length, 0);
  assert.match(texts(again).join('\n'), /sug jawaabtiisa/);
  assert.equal(Number((await db.query(`SELECT count(*) AS n FROM support_approval_requests WHERE customer_id = $1`, [w.c.id])).rows[0].n), 1);
});

test('a group of administrators: /linkgroup by the administrator; requests go to the group; only group administrators decide', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const group = -(1000000000 + seed);
  const inGroup = (from, text) => send({ update_id: updateId++, message: { message_id: updateId, chat: { id: group, type: 'supergroup' }, from, text } });

  // A stranger can not make a group the place the requests go to.
  const stranger = nextChat();
  const refused = await inGroup({ id: stranger, username: 'someone' }, '/linkgroup');
  assert.match(texts(refused).join('\n'), /Kaliya maamulaha/);
  assert.notEqual(Number((await db.query(`SELECT chat_id FROM support_admin`)).rows[0]?.chat_id ?? 0), group);

  // Sent as the group itself (anonymous administrator): told to turn that off, nothing is linked.
  const anon = await send({ update_id: updateId++, message: { message_id: updateId, chat: { id: group, type: 'supergroup' }, from: { id: 1087968824, username: 'GroupAnonymousBot', is_bot: true }, sender_chat: { id: group, type: 'supergroup' }, text: '/linkgroup@Badalaisupportbot' } });
  assert.match(texts(anon).join('\n'), /Remain anonymous/);
  assert.notEqual(Number((await db.query(`SELECT chat_id FROM support_admin`)).rows[0]?.chat_id ?? 0), group);

  // The administrator's own account can.
  const adminUser = nextChat();
  const ok = await inGroup({ id: adminUser, username: 'Badalexchangeadmin' }, '/linkgroup@Badalaisupportbot');
  assert.match(texts(ok).join('\n'), /Kooxdan waa la xaqiijiyay/);
  assert.equal(Number((await db.query(`SELECT chat_id FROM support_admin`)).rows[0].chat_id), group);

  // A customer's request goes to the group, with the two buttons.
  const c = await customer();
  const code = `BX${c.id.replace(/-/g, '').slice(0, 8).toUpperCase()}`;
  const was = (await db.query(`SELECT value FROM app_settings WHERE key = 'withdrawal_verification'`)).rows[0]?.value;
  if (verificationWas === undefined) verificationWas = was ?? null;
  await db.query(`INSERT INTO app_settings (key, value) VALUES ('withdrawal_verification', 'on') ON CONFLICT (key) DO UPDATE SET value = 'on'`);
  await db.query(`DELETE FROM withdrawal_approvals WHERE customer_id = $1`, [c.id]);
  const chat = nextChat();
  const r = await send({ update_id: updateId++, message: { message_id: updateId, chat: { id: chat, type: 'private' }, from: { id: chat }, text: `/start fasax_${code}` } });
  const toGroup = r.calls.find((x) => x.method === 'sendMessage' && x.body.chat_id === group);
  assert.ok(toGroup, 'the group got the request');
  const [approve] = toGroup.body.reply_markup.inline_keyboard.flat().map((b) => b.callback_data);

  const pressInGroup = (userId) => send({ update_id: updateId++, callback_query: { id: `cb${updateId}`, data: approve, from: { id: userId, username: `u${userId}` }, message: { message_id: 7, text: 'Codsi fasax bixin', chat: { id: group, type: 'supergroup' } } } });
  // An ordinary member of the group can not decide.
  const member = nextChat();
  tg.members.set(member, 'member');
  const no = await pressInGroup(member);
  assert.ok(no.calls.find((x) => x.method === 'answerCallbackQuery' && /ogol/.test(x.body.text ?? '')));
  assert.equal((await dbRequest(c.id)).status, 'pending');
  // A group administrator can.
  const boss = nextChat();
  tg.members.set(boss, 'administrator');
  const yes = await pressInGroup(boss);
  assert.equal((await dbRequest(c.id)).status, 'approved');
  assert.equal(Number((await dbRequest(c.id)).decided_by_tg), boss);
  assert.match(yes.calls.find((x) => x.method === 'sendMessage' && x.body.chat_id === chat).body.text, /Akoonkaaga waa la fasaxay/);
  // Pressed in some other chat, even by an administrator there: refused.
  const w2 = await waitingRequest();
  const elsewhere = nextChat();
  tg.members.set(elsewhere, 'administrator');
  const other = await send({ update_id: updateId++, callback_query: { id: `cb${updateId}`, data: w2.approve, from: { id: elsewhere }, message: { message_id: 7, text: 'x', chat: { id: -elsewhere, type: 'supergroup' } } } });
  assert.ok(other.calls.find((x) => x.method === 'answerCallbackQuery' && /ogol/.test(x.body.text ?? '')));
  assert.equal((await dbRequest(w2.c.id)).status, 'pending');
});
