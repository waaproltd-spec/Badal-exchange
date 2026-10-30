// BADAL AI Support Bot (Telegram): customer support for BADAL Exchange.
//
// Text and images / screenshots ONLY, answers in Somali ONLY.
//   * Voice messages, audio files, video notes, videos and everything else that
//     is not text or an image are refused with a Somali message: nothing is
//     downloaded or processed, and the bot never sends voice.
//   * A screenshot (a Telegram photo, or an image sent as a file) is read by the
//     AI, which explains in Somali what it shows and what the customer can do --
//     whatever language the screenshot is in.
//   * The customer links their chat once: the Wallet ID, then their own Telegram
//     contact, whose number must be the registered one. The bot reads their
//     orders and makes tickets for the admin; it can't create an order, move
//     money or change an account (see migrations/*_support_bot.sql).
//
// Telegram calls this function as the bot's webhook:
//   https://<project>.supabase.co/functions/v1/support-bot
//
// Secrets (set in Supabase; SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided):
//   SUPPORT_BOT_TOKEN           the bot's token from @BotFather (never put it in the code or the repo)
//   SUPPORT_BOT_WEBHOOK_SECRET  a long random string; Telegram sends it back with every update
//   ANTHROPIC_API_KEY           reads the screenshots and answers questions
//   [SUPPORT_AI_MODEL=claude-sonnet-5-5]
//   [SUPPORT_TELEGRAM_API_BASE, SUPPORT_AI_API_BASE]   (tests)
// Then register the webhook and the menu once (open it in a browser):
//   https://<project>.supabase.co/functions/v1/support-bot/setup?key=<SUPPORT_BOT_WEBHOOK_SECRET>
const TG_BASE = (Deno.env.get('SUPPORT_TELEGRAM_API_BASE') || 'https://api.telegram.org').replace(/\/$/, '');
const AI_BASE = (Deno.env.get('SUPPORT_AI_API_BASE') || 'https://api.anthropic.com').replace(/\/$/, '');
const MODEL = Deno.env.get('SUPPORT_AI_MODEL') || 'claude-sonnet-5-5';
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

// ------------------------------------------------------------------ Somali

const T = {
  welcome:
    '👋 Ku soo dhawoow <b>BADAL AI Support Bot</b>.\n\nWaxaan ku caawinaa macaamiisha BADAL Exchange. Fadlan geli <b>Wallet ID</b>-gaaga (tusaale: BE295683) si aan kuu aqoonsado.',
  askContact:
    '✅ Wallet ID-gan waa la helay. Si aan u hubino inaad adigu tahay, fadlan taabo badhanka hoose oo la wadaag lambarkaaga Telegram-ka.',
  shareButton: '📱 La wadaag lambarkayga',
  wrongWallet: '❌ Wallet ID-gan lama helin. Fadlan hubi oo mar kale isku day.',
  walletLimited: '⛔ Isku-day badan baa la sameeyay. Fadlan mar kale isku day saacad kadib.',
  wrongContact: '❌ Lambarkan ma aha kan akoonkaaga ku diiwaangashan. Waan ku xaqiijin kari waynay.',
  contactNotOwn: '❌ Fadlan la wadaag lambarkaaga adiga u gaarka ah (badhanka hoose).',
  linked: (name: string) => `✅ Waad ku mahadsan tahay${name ? ', ' + name : ''}! Akoonkaaga waa la xaqiijiyay.\n\nFadlan dooro adeegga aad rabto:`,
  menuTitle: 'Fadlan dooro adeegga aad rabto:',
  needLink: 'Marka hore fadlan geli <b>Wallet ID</b>-gaaga si aan kuu aqoonsado. Qor /start.',
  noOrders: 'Wali macaamil lama helin.',
  ordersTitle: (kind: string) =>
    kind === 'deposit' ? '⬇️ <b>Dhigashooyinkaaga ugu dambeeyay</b>' : kind === 'withdraw' ? '⬆️ <b>Bixinaadyadaaga ugu dambeeyay</b>' : '📋 <b>Macaamilladaada ugu dambeeyay</b>',
  depositHelp:
    '⬇️ <b>Dhigasho</b>\nKu dhig lacag Wallet-kaaga adigoo ka dooranaya App-ka <b>Dhigasho</b>, dooro habka, oo ka dir lacagta lambarkaaga diiwaangashan. Waxaa lagu daraa marka lacag-bixintaada la xaqiijiyo.\n\nHaddii dhigashadaadu dib u dhacday, soo dir sawir (screenshot) ama taabo <b>La xiriir Admin</b>.',
  withdrawHelp:
    '⬆️ <b>Bixin</b>\nKa bixi lacagta Wallet-kaaga adigoo ka dooranaya App-ka <b>Bixin</b>, dooro habka, geli lambarka iyo lacagta. Lacagtu waxay u socotaa lambarka aad dooratay.\n\nHaddii bixintaadu dib u dhacday, soo dir sawir (screenshot) ama taabo <b>La xiriir Admin</b>.',
  faq:
    '❓ <b>Su’aalaha inta badan la isweydiiyo</b>\n\n• <b>Dhigashadaydu ma muuqato?</b> Waxay soo muuqataa marka lacag-bixintaada la xaqiijiyo. Sug daqiiqado ama soo dir sawir.\n• <b>Bixintaydu way dib u dhacday?</b> Waxaa laga yaabaa inay sugayso hubin. Sug 5 daqiiqo, kadib la xiriir Admin.\n• <b>Xaddiga bixinta?</b> Waxaad ka eeg kartaa Profile-kaaga App-ka.\n• <b>PIN ama password?</b> Ma weydiino, ha na siin weligaa.',
  askTicket: '🎧 Fadlan qor farriinta aad rabto inaan Admin-ka u gudbino (waxaad kale oo soo diri kartaa sawir kadib).',
  ticketMade: (code: string) => `✅ Farriintaada waa la gudbiyay.\n\nTikidhka: <b>${code}</b>\nAdmin-ku wuu kula soo xiriiri doonaa. Fadlan keydso lambarkan.`,
  ticketLimited: '⛔ Tikidh badan baa la sameeyay. Fadlan mar kale isku day saacad kadib.',
  me: (name: string, wallet: string) => `⚙️ <b>Xogtayda</b>\nMagaca: ${name || '—'}\nWallet ID: <b>${wallet || '—'}</b>`,
  unlinked: '✅ Akoonkaaga waa laga saaray bot-kan. Qor /start si aad mar kale ugu xirto.',
  voiceRefused: '🚫 Codka (voice) iyo faylasha cod ah lama aqbalo. Fadlan qor qoraal ama soo dir sawir (screenshot) oo muujinaya cilada.',
  otherRefused: '🚫 Bot-kan wuxuu aqbalaa <b>qoraal</b> iyo <b>sawir (screenshot)</b> kaliya. Fadlan mid ka mid ah u dir.',
  imageTooBig: '⚠️ Sawirku aad buu u weyn yahay. Fadlan soo dir sawir ka yar 5MB.',
  aiLimited: '⏳ Su’aalo badan baad dirtay. Fadlan mar kale isku day saacad kadib, ama taabo <b>La xiriir Admin</b>.',
  aiFailed: '⚠️ Hadda ma awoodo inaan sawirka/su’aasha falanqeeyo. Fadlan mar kale isku day daqiiqado kadib, ama taabo <b>La xiriir Admin</b>.',
  imageUnreadable: '⚠️ Sawirkan lama akhrin karo. Fadlan soo dir screenshot cad (PNG ama JPG).',
  status: { completed: 'Waa dhammaystiray', pending: 'Waa la sugayaa', processing: 'Waa la farsamaynayaa', failed: 'Waa fashilmay', cancelled: 'Waa la joojiyay', expired: 'Waa dhacay' } as Record<string, string>,
  buttons: {
    deposit: '⬇️ Dhigasho', withdraw: '⬆️ Bixin', orders: '📋 Dalabyadayda', history: '🕘 Taariikhda Macaamilka',
    faq: '❓ Su’aalaha Inta Badan La Isweydiiyo', admin: '🎧 La xiriir Admin', me: '⚙️ Xogtayda',
  },
};

const SYSTEM_PROMPT = `You are "BADAL AI Support Bot", the customer-support assistant of BADAL Exchange, a service where customers deposit and withdraw money with mobile money (EVC Plus, Golis, ZAAD, eDahab) and betting platforms (1XBET, MELBET, WinWin, DBbet, Betwinner, BetJam, BetOnGame, 888STARZ, LuckyPari, Goldpari, Betandyou).

LANGUAGE: Write EVERY answer in Somali (Af-Soomaali) only. Never answer in English, Arabic or any other language -- even when the customer's text or the screenshot is in English or Arabic: read it, then explain it in Somali. Keep names of companies, buttons and error codes as they are shown.

WHAT YOU DO: When the customer sends a screenshot, look at it, say in Somali what it shows (the error, the amount, the method, the status), explain the likely reason, and give 1-3 short steps they can take (retry in a few minutes, check the number and amount, check their balance, update the app). Answer their text questions about deposits, withdrawals, statuses and the app briefly and clearly.

RULES: Never ask for, accept or repeat a PIN, password, card number or one-time code; if a screenshot shows one, tell them to hide it and never send it again. You cannot move money, refund, credit, cancel, approve or change anything, and you must never say or promise that you did. Do not guess balances or order results: use only what the customer's orders below say. If the problem needs a person (money missing, a payment not credited after waiting, a wrong number, a dispute) tell them to press "La xiriir Admin" and give the details. Do not discuss other topics: politely say in Somali that you only help with BADAL Exchange. You do not use voice: if asked, say in Somali that you only work with text and screenshots. Keep answers short (at most about 8 lines), friendly and plain.`;

// ----------------------------------------------------------------- plumbing

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const esc = (s: unknown) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function token(): string {
  const t = Deno.env.get('SUPPORT_BOT_TOKEN');
  if (!t) throw new Error('SUPPORT_BOT_TOKEN not set');
  return t;
}
/** Error text without the bot token or the AI key. */
function safe(err: unknown): string {
  let m = (err as Error)?.message ?? String(err);
  for (const secret of [Deno.env.get('SUPPORT_BOT_TOKEN'), Deno.env.get('ANTHROPIC_API_KEY'), Deno.env.get('SUPPORT_BOT_WEBHOOK_SECRET')]) {
    if (secret) m = m.replaceAll(secret, '•••');
  }
  return m;
}

async function tg(method: string, body: Record<string, unknown>) {
  const res = await fetch(`${TG_BASE}/bot${token()}/${method}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok || data?.ok === false) throw new Error(`Telegram ${method}: ${data?.description ?? res.status}`);
  return data?.result;
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (!key.startsWith('sb_')) headers.Authorization = `Bearer ${key}`;
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`${fn}: ${data?.message ?? res.status}`);
  return data;
}

const say = (chat: number, text: string, extra: Record<string, unknown> = {}) =>
  tg('sendMessage', { chat_id: chat, text, parse_mode: 'HTML', disable_web_page_preview: true, ...extra });

const menu = () => ({
  inline_keyboard: [
    [{ text: T.buttons.deposit, callback_data: 'deposit' }, { text: T.buttons.withdraw, callback_data: 'withdraw' }],
    [{ text: T.buttons.orders, callback_data: 'orders' }, { text: T.buttons.history, callback_data: 'history' }],
    [{ text: T.buttons.faq, callback_data: 'faq' }],
    [{ text: T.buttons.admin, callback_data: 'admin' }, { text: T.buttons.me, callback_data: 'me' }],
  ],
});

const when = (iso: string) => new Date(iso).toLocaleString('en-GB', { timeZone: 'Africa/Mogadishu', hour12: false });

function ordersText(kind: string, orders: any[]): string {
  if (!orders.length) return T.noOrders;
  const lines = orders.map((o) =>
    `${o.direction === 'deposit' ? '⬇️' : '⬆️'} <b>${esc(o.code)}</b>\n${esc(o.method)} · $${esc(o.amount)}\nXaaladda: ${esc(T.status[o.status] ?? o.status)}\nTaariikhda: ${esc(when(o.createdAt))}`);
  return `${T.ordersTitle(kind)}\n\n${lines.join('\n\n')}`;
}

/** What the AI may know about the customer: only their latest orders. */
function orderContext(orders: any[]): string {
  if (!orders.length) return 'The customer has no orders yet.';
  return 'The customer\'s latest orders (newest first):\n' + orders.map((o) =>
    `- ${o.code}: ${o.direction === 'deposit' ? 'deposit' : 'withdrawal'}, ${o.method}, $${o.amount}, status ${o.status}${o.reason ? ` (${String(o.reason).slice(0, 120)})` : ''}, ${when(o.createdAt)}`).join('\n');
}

// ----------------------------------------------------------------------- AI

async function askAi(content: unknown[], context: string): Promise<string | null> {
  const key = Deno.env.get('ANTHROPIC_API_KEY');
  if (!key) return null;
  const res = await fetch(`${AI_BASE}/v1/messages`, {
    method: 'POST',
    headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: MODEL, max_tokens: 700, system: `${SYSTEM_PROMPT}\n\n${context}`, messages: [{ role: 'user', content }] }),
    signal: AbortSignal.timeout(45_000),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`AI ${res.status}: ${data?.error?.message ?? ''}`);
  const text = String(data?.content?.find((c: any) => c.type === 'text')?.text ?? '').trim();
  return text || null;
}

/** Downloads a Telegram image: bytes as base64 and its type, or why not. */
async function downloadImage(fileId: string): Promise<{ data: string; type: string } | 'big' | null> {
  const file = await tg('getFile', { file_id: fileId });
  if (!file?.file_path) return null;
  if (typeof file.file_size === 'number' && file.file_size > MAX_IMAGE_BYTES) return 'big';
  const res = await fetch(`${TG_BASE}/file/bot${token()}/${file.file_path}`, { signal: AbortSignal.timeout(30_000) });
  if (!res.ok) return null;
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.length > MAX_IMAGE_BYTES) return 'big';
  const path = String(file.file_path).toLowerCase();
  const type = path.endsWith('.png') ? 'image/png' : path.endsWith('.webp') ? 'image/webp' : path.endsWith('.gif') ? 'image/gif' : 'image/jpeg';
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return { data: btoa(bin), type };
}

// ----------------------------------------------------------------- handlers

const IMAGE_DOC = /^image\/(jpeg|png|webp|gif)$/;

async function showOrders(chat: number, kind: string) {
  const orders = (await rpc('support_orders', { p_chat: chat, p_kind: kind, p_limit: kind === 'all' ? 5 : 10 })) ?? [];
  await say(chat, ordersText(kind, orders), { reply_markup: menu() });
}

async function onCallback(cb: any) {
  const chat: number = cb.message?.chat?.id;
  if (!chat) return;
  await tg('answerCallbackQuery', { callback_query_id: cb.id }).catch(() => {});
  const s = await rpc('support_session', { p_chat: chat });
  if (!s.linked) return void (await say(chat, T.needLink));
  switch (cb.data) {
    case 'deposit': await say(chat, T.depositHelp); return showOrders(chat, 'deposit');
    case 'withdraw': await say(chat, T.withdrawHelp); return showOrders(chat, 'withdraw');
    case 'orders': return showOrders(chat, 'all');
    case 'history': return showOrders(chat, 'all');
    case 'faq': return void (await say(chat, T.faq, { reply_markup: menu() }));
    case 'me': return void (await say(chat, T.me(esc(s.name), esc(s.walletId)), { reply_markup: menu() }));
    case 'admin':
      await rpc('support_set_state', { p_chat: chat, p_state: 'awaiting_ticket' });
      return void (await say(chat, T.askTicket));
  }
}

async function onMessage(m: any, from: any) {
  const chat: number = m.chat?.id;
  if (!chat || m.chat?.type !== 'private') return; // private chats only

  // Voice, audio, video and everything that is not text or an image: refused, never downloaded.
  const isImageDoc = m.document && IMAGE_DOC.test(String(m.document.mime_type ?? ''));
  if (m.voice || m.audio || m.video_note || m.video || (m.document && !isImageDoc)) {
    const voice = Boolean(m.voice || m.audio || m.video_note || (m.document && /^audio\//.test(String(m.document.mime_type ?? ''))));
    return void (await say(chat, voice ? T.voiceRefused : T.otherRefused));
  }

  const s = await rpc('support_session', { p_chat: chat });
  const text: string = typeof m.text === 'string' ? m.text.trim() : '';

  if (text === '/start') {
    if (s.linked) return void (await say(chat, T.menuTitle, { reply_markup: menu() }));
    await rpc('support_set_state', { p_chat: chat, p_state: 'awaiting_wallet' });
    return void (await say(chat, T.welcome));
  }
  if (text === '/unlink') {
    await rpc('support_unlink', { p_chat: chat });
    return void (await say(chat, T.unlinked, { reply_markup: { remove_keyboard: true } }));
  }
  if (text === '/menu' && s.linked) return void (await say(chat, T.menuTitle, { reply_markup: menu() }));

  // ---- not linked: the Wallet ID, then the customer's own contact
  if (!s.linked) {
    if (s.state === 'awaiting_contact') {
      if (m.contact) {
        // Only the sender's own contact counts.
        if (m.contact.user_id !== from?.id) return void (await say(chat, T.contactNotOwn));
        const r = await rpc('support_verify_contact', { p_chat: chat, p_phone: String(m.contact.phone_number ?? '') });
        if (!r.ok) return void (await say(chat, T.wrongContact, { reply_markup: { remove_keyboard: true } }));
        await say(chat, '✅', { reply_markup: { remove_keyboard: true } });
        return void (await say(chat, T.linked(esc(r.name)), { reply_markup: menu() }));
      }
      if (text) { // maybe a different Wallet ID: start again
        if (/^[A-Za-z0-9]{4,20}$/.test(text)) return linkWallet(chat, text);
        return void (await say(chat, T.askContact, { reply_markup: shareKeyboard() }));
      }
      return void (await say(chat, T.askContact, { reply_markup: shareKeyboard() }));
    }
    if (text && /^[A-Za-z0-9]{4,20}$/.test(text)) return linkWallet(chat, text);
    return void (await say(chat, T.welcome));
  }

  // ---- linked
  if (s.state === 'awaiting_ticket' && text && !m.photo) {
    const r = await rpc('support_create_ticket', { p_chat: chat, p_message: text });
    if (!r.ok) return void (await say(chat, r.limited ? T.ticketLimited : T.needLink, { reply_markup: menu() }));
    return void (await say(chat, T.ticketMade(esc(r.code)), { reply_markup: menu() }));
  }

  const photo = Array.isArray(m.photo) && m.photo.length ? m.photo[m.photo.length - 1] : null;
  const imageId: string | undefined = photo?.file_id ?? (isImageDoc ? m.document.file_id : undefined);
  const caption: string = String(m.caption ?? '').trim();
  const question = imageId ? caption : text;
  if (!imageId && !question) return void (await say(chat, T.otherRefused));

  if (!(await rpc('support_ai_allowed', { p_chat: chat }))) return void (await say(chat, T.aiLimited, { reply_markup: menu() }));
  await tg('sendChatAction', { chat_id: chat, action: 'typing' }).catch(() => {});

  const content: unknown[] = [];
  if (imageId) {
    const img = await downloadImage(imageId);
    if (img === 'big') return void (await say(chat, T.imageTooBig));
    if (!img) return void (await say(chat, T.imageUnreadable));
    content.push({ type: 'image', source: { type: 'base64', media_type: img.type, data: img.data } });
  }
  content.push({
    type: 'text',
    text: imageId
      ? `Customer's screenshot${question ? ' with this note: "' + question.slice(0, 500) + '"' : ''}. Explain in Somali only what it shows and what to do.`
      : question.slice(0, 1500),
  });
  const orders = (await rpc('support_orders', { p_chat: chat, p_kind: 'all', p_limit: 5 })) ?? [];
  let answer: string | null = null;
  try {
    answer = await askAi(content, orderContext(orders));
  } catch (err) {
    console.error('support-bot ai', safe(err));
  }
  await say(chat, answer ? esc(answer) : T.aiFailed, { reply_markup: menu() });
}

const shareKeyboard = () => ({
  keyboard: [[{ text: T.shareButton, request_contact: true }]], resize_keyboard: true, one_time_keyboard: true,
});

async function linkWallet(chat: number, wallet: string) {
  const r = await rpc('support_start_link', { p_chat: chat, p_wallet: wallet });
  if (!r.ok) return void (await say(chat, r.limited ? T.walletLimited : T.wrongWallet));
  await say(chat, T.askContact, { reply_markup: shareKeyboard() });
}

// ------------------------------------------------------------------- server

Deno.serve(async (req) => {
  const expected = Deno.env.get('SUPPORT_BOT_WEBHOOK_SECRET');
  const url = new URL(req.url);
  const path = url.pathname.replace(/\/$/, '');

  // One-time setup: registers the webhook and the menu. From a phone browser:
  //   https://<project>.supabase.co/functions/v1/support-bot/setup?key=<SUPPORT_BOT_WEBHOOK_SECRET>
  // (the bot token stays in the secrets; nothing but the webhook secret is typed).
  if (path.endsWith('/setup')) {
    const given = req.headers.get('x-telegram-bot-api-secret-token') ?? url.searchParams.get('key');
    if (!expected || given !== expected) return new Response('Forbidden', { status: 403 });
    try {
      const hook = `${Deno.env.get('SUPABASE_URL')}/functions/v1/support-bot`;
      await tg('setWebhook', { url: hook, secret_token: expected, allowed_updates: ['message', 'callback_query'], drop_pending_updates: true });
      await tg('setMyCommands', { commands: [{ command: 'start', description: 'Bilow / Menu' }, { command: 'menu', description: 'Menu-ga' }, { command: 'unlink', description: 'Ka saar akoonka' }] });
      return json({ ok: true, message: 'Webhook was set. Send /start to the bot.' });
    } catch (err) {
      console.error('support-bot setup', safe(err));
      return json({ ok: false, error: safe(err) }, 500);
    }
  }

  if (req.method !== 'POST') return new Response('Forbidden', { status: 403 });
  if (!expected || req.headers.get('x-telegram-bot-api-secret-token') !== expected) return new Response('Forbidden', { status: 403 });
  try {
    const update = await req.json();
    if (update.callback_query) await onCallback(update.callback_query);
    else if (update.message) await onMessage(update.message, update.message.from);
  } catch (err) {
    console.error('support-bot', safe(err));
  }
  return json({ ok: true }); // Telegram must always get 200, or it resends the update
});
