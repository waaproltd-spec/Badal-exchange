// BADAL AI Support Bot (Telegram): customer support for BADAL Exchange.
//
// TEXT ONLY, answers in Somali ONLY.
//   * Voice messages, audio files, video notes, videos, photos, screenshots,
//     documents and everything else that is not text are refused with a Somali
//     message: nothing is downloaded or processed, and the bot never sends voice.
//   * The customer links their chat once: the Wallet ID, then their own Telegram
//     contact, whose number must be the registered one. The bot reads their
//     orders; it can't create an order, move money or change an account (see
//     migrations/*_support_bot.sql).
//   * "La xiriir Admin" opens a direct Telegram chat with the admin
//     (@Badalexchangeadmin). No tickets, no complaints and no message text are
//     stored anywhere.
//
// Telegram calls this function as the bot's webhook:
//   https://<project>.supabase.co/functions/v1/support-bot
//
// Secrets (set in Supabase; SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided):
//   SUPPORT_BOT_TOKEN           the bot's token from @BotFather (never put it in the code or the repo)
//   SUPPORT_BOT_WEBHOOK_SECRET  a long random string; Telegram sends it back with every update
//   ANTHROPIC_API_KEY           answers the customers' questions
//   [SUPPORT_AI_MODEL=claude-sonnet-5-5]
//   [SUPPORT_TELEGRAM_API_BASE, SUPPORT_AI_API_BASE]   (tests)
// Then register the webhook and the menu once (open it in a browser):
//   https://<project>.supabase.co/functions/v1/support-bot/setup?key=<SUPPORT_BOT_WEBHOOK_SECRET>
const TG_BASE = (Deno.env.get('SUPPORT_TELEGRAM_API_BASE') || 'https://api.telegram.org').replace(/\/$/, '');
const AI_BASE = (Deno.env.get('SUPPORT_AI_API_BASE') || 'https://api.anthropic.com').replace(/\/$/, '');
const MODEL = Deno.env.get('SUPPORT_AI_MODEL') || 'claude-sonnet-5-5';
/** The admin's own Telegram: "La xiriir Admin" opens a direct chat with it. Nothing the customer says is stored. */
const ADMIN_TG = (Deno.env.get('SUPPORT_ADMIN_TELEGRAM') || 'Badalexchangeadmin').replace(/^@/, '');

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
    '⬇️ <b>Dhigasho</b>\nKu dhig lacag Wallet-kaaga adigoo ka dooranaya App-ka <b>Dhigasho</b>, dooro habka, oo ka dir lacagta lambarkaaga diiwaangashan. Waxaa lagu daraa marka lacag-bixintaada la xaqiijiyo.\n\nHaddii dhigashadaadu dib u dhacday, qor su’aashaada ama taabo <b>La xiriir Admin</b>.',
  withdrawHelp:
    '⬆️ <b>Bixin</b>\nKa bixi lacagta Wallet-kaaga adigoo ka dooranaya App-ka <b>Bixin</b>, dooro habka, geli lambarka iyo lacagta. Lacagtu waxay u socotaa lambarka aad dooratay.\n\nHaddii bixintaadu dib u dhacday, qor su’aashaada ama taabo <b>La xiriir Admin</b>.',
  faq:
    '❓ <b>Su’aalaha inta badan la isweydiiyo</b>\n\n• <b>Dhigashadaydu ma muuqato?</b> Waxay soo muuqataa marka lacag-bixintaada la xaqiijiyo. Sug daqiiqado ama qor su’aashaada.\n• <b>Bixintaydu way dib u dhacday?</b> Waxaa laga yaabaa inay sugayso hubin. Sug 5 daqiiqo, kadib la xiriir Admin.\n• <b>Xaddiga bixinta?</b> Waxaad ka eeg kartaa Profile-kaaga App-ka.\n• <b>PIN ama password?</b> Ma weydiino, ha na siin weligaa.',
  contactAdmin: `🎧 <b>La xiriir Admin</b>
Taabo badhanka hoose si aad Telegram-ka ugula hadasho Admin-ka toos ah (@${ADMIN_TG}). Halkaas ku sharax cilada, oo isaga ayaa kaa caawin doona.`,
  me: (name: string, wallet: string) => `⚙️ <b>Xogtayda</b>\nMagaca: ${name || '—'}\nWallet ID: <b>${wallet || '—'}</b>`,
  unlinked: '✅ Akoonkaaga waa laga saaray bot-kan. Qor /start si aad mar kale ugu xirto.',
  voiceRefused: '🚫 Codka (voice) iyo faylasha cod ah lama aqbalo. Fadlan qor su’aashaada qoraal ahaan.',
  otherRefused: '🚫 Bot-kan wuxuu aqbalaa <b>qoraal</b> kaliya. Sawirada (screenshots), codka iyo faylasha kale lama aqbalo. Fadlan qor su’aashaada.',
  aiLimited: '⏳ Su’aalo badan baad dirtay. Fadlan mar kale isku day saacad kadib, ama taabo <b>La xiriir Admin</b>.',
  aiFailed: '⚠️ Hadda ma awoodo inaan su’aasha ka jawaabo. Fadlan mar kale isku day daqiiqado kadib, ama taabo <b>La xiriir Admin</b>.',
  status: { completed: 'Waa dhammaystiray', pending: 'Waa la sugayaa', processing: 'Waa la farsamaynayaa', failed: 'Waa fashilmay', cancelled: 'Waa la joojiyay', expired: 'Waa dhacay' } as Record<string, string>,
  buttons: {
    deposit: '⬇️ Dhigasho', withdraw: '⬆️ Bixin', orders: '📋 Dalabyadayda', history: '🕘 Taariikhda Macaamilka',
    faq: '❓ Su’aalaha Inta Badan La Isweydiiyo', admin: '🎧 La xiriir Admin', me: '⚙️ Xogtayda',
  },
};

const SYSTEM_PROMPT = `You are "BADAL AI Support Bot", the customer-support assistant of BADAL Exchange, a service where customers deposit and withdraw money with mobile money (EVC Plus, Golis, ZAAD, eDahab) and betting platforms (1XBET, MELBET, WinWin, DBbet, Betwinner, BetJam, BetOnGame, 888STARZ, LuckyPari, Goldpari, Betandyou).

LANGUAGE: Write EVERY answer in Somali (Af-Soomaali) only. Never answer in English, Arabic or any other language -- even when the customer writes to you in English or Arabic: read it, then answer in Somali. Keep names of companies, buttons and error codes as they are written.

WHAT YOU DO: Answer the customer's text questions about deposits, withdrawals, statuses and the app briefly and clearly, and give 1-3 short steps they can take (retry in a few minutes, check the number and amount, check their balance, update the app).

RULES: You only receive text: if the customer says they sent a screenshot, image or voice message, tell them in Somali that this bot works with text only and ask them to write the problem. Never ask for, accept or repeat a PIN, password, card number or one-time code; if the customer writes one, tell them never to send it. You cannot move money, refund, credit, cancel, approve or change anything, and you must never say or promise that you did. Do not guess balances or order results: use only what the customer's orders below say. If the problem needs a person (money missing, a payment not credited after waiting, a wrong number, a dispute) tell them to press "La xiriir Admin" and give the details. Do not discuss other topics: politely say in Somali that you only help with BADAL Exchange. Keep answers short (at most about 8 lines), friendly and plain.`;

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

/** A button that opens the admin's own Telegram chat. */
const adminLink = () => ({ inline_keyboard: [[{ text: '💬 La hadal Admin-ka (Telegram)', url: `https://t.me/${ADMIN_TG}` }]] });

const menu = () => ({
  inline_keyboard: [
    [{ text: T.buttons.deposit, callback_data: 'deposit' }, { text: T.buttons.withdraw, callback_data: 'withdraw' }],
    [{ text: T.buttons.orders, callback_data: 'orders' }, { text: T.buttons.history, callback_data: 'history' }],
    [{ text: T.buttons.faq, callback_data: 'faq' }],
    [{ text: T.buttons.admin, url: `https://t.me/${ADMIN_TG}` }, { text: T.buttons.me, callback_data: 'me' }],
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

async function askAi(question: string, context: string): Promise<string | null> {
  const key = Deno.env.get('ANTHROPIC_API_KEY');
  if (!key) return null;
  const res = await fetch(`${AI_BASE}/v1/messages`, {
    method: 'POST',
    headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: MODEL, max_tokens: 700, system: `${SYSTEM_PROMPT}\n\n${context}`, messages: [{ role: 'user', content: question }] }),
    signal: AbortSignal.timeout(45_000),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`AI ${res.status}: ${data?.error?.message ?? ''}`);
  const text = String(data?.content?.find((c: any) => c.type === 'text')?.text ?? '').trim();
  return text || null;
}

// ----------------------------------------------------------------- handlers

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
    case 'admin': // (menus sent earlier still have this button)
      return void (await say(chat, T.contactAdmin, { reply_markup: adminLink() }));
  }
}

async function onMessage(m: any, from: any) {
  const chat: number = m.chat?.id;
  if (!chat || m.chat?.type !== 'private') return; // private chats only

  // Text only: voice, audio, photos, screenshots, videos, documents and everything else is refused, never downloaded.
  if (typeof m.text !== 'string' && !m.contact) {
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
  if (!text) return void (await say(chat, T.otherRefused));

  if (!(await rpc('support_ai_allowed', { p_chat: chat }))) return void (await say(chat, T.aiLimited, { reply_markup: menu() }));
  await tg('sendChatAction', { chat_id: chat, action: 'typing' }).catch(() => {});

  const orders = (await rpc('support_orders', { p_chat: chat, p_kind: 'all', p_limit: 5 })) ?? [];
  let answer: string | null = null;
  try {
    answer = await askAi(text.slice(0, 1500), orderContext(orders));
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
    // Says why, so the one-time setup can be fixed (nothing here reveals the secret).
    if (!expected) return new Response('Forbidden: the secret SUPPORT_BOT_WEBHOOK_SECRET is not set in Supabase', { status: 403 });
    if (given !== expected) return new Response('Forbidden: the key in the address does not match SUPPORT_BOT_WEBHOOK_SECRET', { status: 403 });
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
