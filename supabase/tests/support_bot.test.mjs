// BADAL AI Support Bot (functions/support-bot, migrations/*_support_bot.sql),
// against stand-in Telegram and AI servers: text only, Somali only, no voice,
// audio, photos or screenshots; the chat is linked by Wallet ID and the
// customer's own contact; orders are read, tickets are made.
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
const tg = { calls: [], files: new Map() };
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

  r = await send(message(chat, { text: 'BE000000' }));
  assert.match(texts(r)[0], /lama helin/);

  r = await send(message(chat, { text: c.wallet }));
  const ask = r.calls.find((x) => x.method === 'sendMessage');
  assert.match(ask.body.text, /la wadaag lambarkaaga Telegram/);
  assert.equal(ask.body.reply_markup.keyboard[0][0].request_contact, true);

  // Someone else's contact, or another number: refused.
  r = await send(message(chat, { contact: { phone_number: `+${c.phone}`, user_id: 1 } }));
  assert.match(texts(r)[0], /adiga u gaarka ah/);
  r = await send(message(chat, { contact: { phone_number: '+252619999999', user_id: chat } }));
  assert.match(texts(r)[0], /ma aha kan akoonkaaga/);
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

test('Admin ticket: the customer writes, gets a ticket code; management sees and closes it', async (t) => {
  if (!served) return t.skip('support-bot is not served');
  const c = await linked();
  let r = await send(callback(c.chat, 'admin'));
  assert.match(texts(r)[0], /qor farriinta/);
  assert.match(texts(r)[0], /@Badalexchangeadmin/);
  assert.equal(r.calls.find((x) => x.method === 'sendMessage').body.reply_markup.inline_keyboard[0][0].url, 'https://t.me/Badalexchangeadmin');
  r = await send(message(c.chat, { text: 'Lacagtaydii dhigasho ah ma soo gelin' }));
  const code = texts(r)[0].match(/#BADAL\d+/)[0];
  assert.match(texts(r)[0], /@Badalexchangeadmin/);
  assert.equal(r.calls.find((x) => x.method === 'sendMessage').body.reply_markup.inline_keyboard[0][0].url, 'https://t.me/Badalexchangeadmin');
  const { tickets } = { tickets: (await manager.rpc('manage_support_tickets', { p_status: 'open' })).data };
  const ticket = tickets.find((x) => x.code === code);
  assert.ok(ticket);
  assert.deepEqual([ticket.message, ticket.walletId, ticket.phone], ['Lacagtaydii dhigasho ah ma soo gelin', c.wallet, c.phone]);
  const closed = await manager.rpc('manage_close_support_ticket', { p_id: ticket.id });
  assert.equal(closed.data.status, 'closed');
  assert.ok(!(await manager.rpc('manage_support_tickets', { p_status: 'open' })).data.some((x) => x.code === code));
});

test('the database functions are for the bot only', async (t) => {
  const customerRow = await customer();
  const cu = await login(customerRow.phone);
  for (const [fn, args] of [
    ['support_session', { p_chat: 1 }],
    ['support_orders', { p_chat: 1 }],
    ['support_create_ticket', { p_chat: 1, p_message: 'x' }],
  ]) {
    const { error } = await cu.rpc(fn, args);
    assert.ok(error, `${fn} is refused to a customer`);
  }
  const { error } = await cu.rpc('manage_support_tickets', {});
  assert.ok(error, 'tickets are for management');
  const { error: e2 } = await cu.from('support_chats').select('*');
  assert.ok(e2, 'the chats are not readable');
});

test('no voice, audio or image code exists in the bot', async () => {
  const { readFileSync } = await import('node:fs');
  const code = readFileSync(new globalThis.URL('../functions/support-bot/index.ts', import.meta.url), 'utf8');
  for (const bad of ['sendVoice', 'sendAudio', 'sendVideoNote', 'sendPhoto', 'speech', 'transcri', 'whisper', 'text-to-speech', 'getFile', 'base64']) {
    assert.ok(!code.includes(bad), `${bad} must not appear`);
  }
});
