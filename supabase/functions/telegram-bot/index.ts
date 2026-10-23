// Telegram cashier bots for the CashdeskBot partner API: player search, the
// cash register's balance, player deposits and payouts, from a private chat
// with the bot. One bot per betting brand, each on its own cash register
// (BRANDS in ../_shared/cashdeskbot.ts); Telegram calls this function as
// their webhook:
//   @Badal888starzbot  .../functions/v1/telegram-bot
//   @Badal1xbetbot     .../functions/v1/telegram-bot/1xbet
//   @Badalwinwinbot    .../functions/v1/telegram-bot/winwin
//   @Badalbetwinnerbot .../functions/v1/telegram-bot/betwinner
//   @Badaldbbetbot     .../functions/v1/telegram-bot/dbbet
//   @Badalbetjambot    .../functions/v1/telegram-bot/betjam
//   @Badalbetongamebot .../functions/v1/telegram-bot/betongame
//
//   /link CODE            link this Telegram account (code from the Agent App:
//                         Account -> Admin features -> Telegram Bot)
//   /unlink               unlink it
//   /balance              cash register balance and limit
//   /player ID            player search
//   /deposit ID AMOUNT    top up a player (asks to confirm)
//   /payout ID CODE       pay out a player's withdrawal code (asks to confirm)
//
// Only managers (admins, and agents with 'manage_settings') can use it; the
// database checks that on every request, as the linked manager (see
// migrations/*_telegram_bot.sql), and records deposits and payouts in the
// audit log with the same idempotency as the cashdeskbot function.
//
// A Telegram account linked once works with every bot.
//
// Secrets (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase):
//   TELEGRAM_BOT_TOKEN (888starz), TELEGRAM_BOT_TOKEN_1XBET (1xBet), TELEGRAM_BOT_TOKEN_WINWIN (WinWin),
//   TELEGRAM_BOT_TOKEN_BETWINNER (Betwinner), TELEGRAM_BOT_TOKEN_DBBET (DBbet),
//   TELEGRAM_BOT_TOKEN_BETJAM (BetJam), TELEGRAM_BOT_TOKEN_BETONGAME (BetOnGame),
//   TELEGRAM_WEBHOOK_SECRET (shared), [TELEGRAM_BOT_LNG=en]
// plus each brand's CashdeskBot secrets (../_shared/cashdeskbot.ts). Then
// register each bot's webhook and command menu once:
//   curl -X POST -H "X-Telegram-Bot-Api-Secret-Token: $TELEGRAM_WEBHOOK_SECRET" \
//     https://<project>.supabase.co/functions/v1/telegram-bot[/1xbet|/winwin|/betwinner|/dbbet|/betjam|/betongame]/setup
import {
  ApiError,
  BRANDS,
  type Brand,
  cashdeskBalance,
  depositToPlayer,
  findPlayer,
  getCredentials,
  payoutToPlayer,
  type Player,
} from '../_shared/cashdeskbot.ts';

const LNG = Deno.env.get('TELEGRAM_BOT_LNG') || 'en';

/** One Telegram bot, serving one brand's cash register. */
interface Bot {
  brand: Brand;
  /** Path after /telegram-bot ('' for 888starz). */
  path: string;
  tokenEnv: string;
}

const BOTS: Bot[] = [
  { brand: BRANDS['888starz'], path: '', tokenEnv: 'TELEGRAM_BOT_TOKEN' },
  { brand: BRANDS['1xbet'], path: '/1xbet', tokenEnv: 'TELEGRAM_BOT_TOKEN_1XBET' },
  { brand: BRANDS.winwin, path: '/winwin', tokenEnv: 'TELEGRAM_BOT_TOKEN_WINWIN' },
  { brand: BRANDS.betwinner, path: '/betwinner', tokenEnv: 'TELEGRAM_BOT_TOKEN_BETWINNER' },
  { brand: BRANDS.dbbet, path: '/dbbet', tokenEnv: 'TELEGRAM_BOT_TOKEN_DBBET' },
  { brand: BRANDS.betjam, path: '/betjam', tokenEnv: 'TELEGRAM_BOT_TOKEN_BETJAM' },
  { brand: BRANDS.betongame, path: '/betongame', tokenEnv: 'TELEGRAM_BOT_TOKEN_BETONGAME' },
];

const COMMANDS = [
  { command: 'balance', description: 'Cash register balance' },
  { command: 'player', description: 'Find a player: /player ID' },
  { command: 'deposit', description: 'Top up a player: /deposit ID AMOUNT' },
  { command: 'payout', description: 'Pay out a code: /payout ID CODE' },
  { command: 'help', description: 'Commands' },
  { command: 'unlink', description: 'Unlink this Telegram account' },
];

const help = (bot: Bot) => [
  `<b>${bot.brand.label} cashier: commands</b>`,
  '/balance: cash register balance and limit',
  '/player ID: find a player',
  '/deposit ID AMOUNT: top up a player',
  '/payout ID CODE: pay out a player\'s withdrawal code',
  '/unlink: unlink this Telegram account',
  '',
  'Deposits and payouts ask you to confirm first.',
].join('\n');

const notLinked = (bot: Bot) => [
  `This is the ${bot.brand.label} cashier bot. Your Telegram account is not linked yet.`,
  '',
  'In the Agent App open <b>Account → Admin features → Telegram Bot</b>, get a link code, then send it here as',
  '<code>/link CODE</code>',
].join('\n');

const escape = (s: unknown) =>
  String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ---------------------------------------------------------------------------
// Telegram Bot API
// ---------------------------------------------------------------------------

async function telegram(bot: Bot, method: string, body: Record<string, unknown>) {
  const token = Deno.env.get(bot.tokenEnv);
  if (!token) {
    console.error(`${bot.tokenEnv} is not set`);
    return null;
  }
  const res = await fetch(`${Deno.env.get('TELEGRAM_API_URL') || 'https://api.telegram.org'}/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!data?.ok) console.error(`telegram ${method} failed`, res.status, data?.description);
  return data;
}

const send = (bot: Bot, chatId: number, text: string, extra: Record<string, unknown> = {}) =>
  telegram(bot, 'sendMessage', { chat_id: chatId, text, parse_mode: 'HTML', disable_web_page_preview: true, ...extra });

const edit = (bot: Bot, chatId: number, messageId: number, text: string) =>
  telegram(bot, 'editMessageText', { chat_id: chatId, message_id: messageId, text, parse_mode: 'HTML' });

// ---------------------------------------------------------------------------
// Database (service role; every telegram_* function re-checks the manager)
// ---------------------------------------------------------------------------

async function rpc(fn: string, args: Record<string, unknown>) {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (!key.startsWith('sb_')) headers.Authorization = `Bearer ${key}`;
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(args),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const code: string | undefined = data?.code;
    const status = code?.startsWith('PT') ? Number(code.slice(2)) || 400 : 500;
    throw new ApiError(status, data?.hint || code || 'ERROR', data?.message || 'Request failed');
  }
  return data;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

const PLAYER_ID = /^\d{1,15}$/;
const AMOUNT = /^\d{1,12}(\.\d{1,2})?$/;
const PAYOUT_CODE = /^\S{1,64}$/;

interface From {
  id: number;
  username?: string;
}

const notFound = (bot: Bot, id: string) => `❌ No ${bot.brand.label} player with ID ${escape(id)}.`;

function playerLine(p: Player, id: string) {
  const name = p.name ? `<b>${escape(p.name)}</b>` : '<i>no name</i>';
  return `Player ${escape(id)}: ${name}${p.currencyId != null ? ` (currency ${escape(p.currencyId)})` : ''}`;
}

const confirmButtons = (pendingId: string) => ({
  reply_markup: {
    inline_keyboard: [[
      { text: '✅ Confirm', callback_data: `ok:${pendingId}` },
      { text: '✖ Cancel', callback_data: `no:${pendingId}` },
    ]],
  },
});

async function onCommand(bot: Bot, chatId: number, from: From, text: string) {
  const creds = () => getCredentials(bot.brand);
  const [rawCommand, ...args] = text.trim().split(/\s+/);
  const command = rawCommand.toLowerCase().replace(/@.*$/, '');

  // `/start CODE` is what a t.me/<bot>?start=CODE link sends.
  if (command === '/link' || (command === '/start' && args[0])) {
    if (!args[0]) return send(bot, chatId, 'Send the code from the Agent App: <code>/link CODE</code>');
    const me = await rpc('telegram_link', {
      p_telegram_user_id: from.id,
      p_telegram_username: from.username ?? null,
      p_code: args[0],
    });
    return send(bot, chatId, `Linked to <b>${escape(me.name)}</b> (${escape(me.role)}).\n\n${help(bot)}`);
  }
  if (command === '/unlink') {
    await rpc('telegram_unlink', { p_telegram_user_id: from.id });
    return send(bot, chatId, 'This Telegram account is no longer linked.');
  }

  // Everything else needs a linked manager.
  let me;
  try {
    me = await rpc('telegram_whoami', { p_telegram_user_id: from.id });
  } catch (err) {
    if (err instanceof ApiError && err.code === 'TELEGRAM_NOT_LINKED') {
      return send(bot, chatId, `${notLinked(bot)}\n\nYour Telegram ID: <code>${from.id}</code>`);
    }
    throw err;
  }

  switch (command) {
    case '/start':
    case '/help':
      return send(bot, chatId, `Hi ${escape(me.name)}.\n\n${help(bot)}`);

    case '/balance': {
      const b = await cashdeskBalance(creds(), new Date());
      return send(bot, chatId, `<b>Cash register</b>\nBalance: <b>${escape(b.balance ?? '—')}</b>\nLimit: ${escape(b.limit ?? '—')}`);
    }

    case '/player':
    case '/user': {
      const [id] = args;
      if (!id || !PLAYER_ID.test(id)) return send(bot, chatId, 'Usage: <code>/player ID</code>');
      const player = await findPlayer(creds(), id);
      return send(bot, chatId, player.found ? playerLine(player, id) : notFound(bot, id));
    }

    case '/deposit': {
      const [id, amount] = args;
      if (!id || !PLAYER_ID.test(id) || !amount || !AMOUNT.test(amount) || !(Number(amount) > 0)) {
        return send(bot, chatId, 'Usage: <code>/deposit ID AMOUNT</code>, for example <code>/deposit 76 100</code>');
      }
      const player = await findPlayer(creds(), id);
      if (!player.found) return send(bot, chatId, notFound(bot, id));
      const summa = Number(amount);
      const pendingId = await rpc('telegram_prepare', {
        p_telegram_user_id: from.id,
        p_action: 'deposit',
        p_payload: { brand: bot.brand.key, userId: id, lng: LNG, summa },
      });
      return send(bot, chatId, `<b>Deposit ${escape(summa)}</b>\n${playerLine(player, id)}\n\nConfirm?`, confirmButtons(pendingId));
    }

    case '/payout': {
      const [id, code] = args;
      if (!id || !PLAYER_ID.test(id) || !code || !PAYOUT_CODE.test(code)) {
        return send(bot, chatId, 'Usage: <code>/payout ID CODE</code>');
      }
      const player = await findPlayer(creds(), id);
      if (!player.found) return send(bot, chatId, notFound(bot, id));
      const pendingId = await rpc('telegram_prepare', {
        p_telegram_user_id: from.id,
        p_action: 'payout',
        p_payload: { brand: bot.brand.key, userId: id, lng: LNG, code },
      });
      return send(bot, chatId, `<b>Payout</b>, code <code>${escape(code)}</code>\n${playerLine(player, id)}\n\nConfirm?`, confirmButtons(pendingId));
    }

    default:
      return send(bot, chatId, help(bot));
  }
}

function resultText(action: string, payload: Record<string, any>, response: any) {
  const what = action === 'deposit' ? `Deposit of ${escape(payload.summa)}` : `Payout of code <code>${escape(payload.code)}</code>`;
  const failed = response?.success === false;
  const lines = [`${failed ? '❌' : '✅'} ${what} for player ${escape(payload.userId)} ${failed ? 'failed' : 'done'}.`];
  if (response?.summa != null) lines.push(`Amount: <b>${escape(response.summa)}</b>`);
  if (response?.message) lines.push(escape(response.message));
  return lines.join('\n');
}

async function onButton(bot: Bot, chatId: number, messageId: number, from: From, data: string) {
  const [choice, pendingId] = data.split(':');
  if (!pendingId) return;
  if (choice === 'no') {
    await rpc('telegram_cancel', { p_telegram_user_id: from.id, p_pending_id: pendingId });
    return edit(bot, chatId, messageId, 'Cancelled.');
  }
  if (choice !== 'ok') return;

  // Each pending action belongs to the bot that showed it.
  const started = await rpc('telegram_begin', { p_telegram_user_id: from.id, p_pending_id: pendingId });
  const { action, payload } = started as { action: 'deposit' | 'payout'; payload: Record<string, any> };
  if (started.replay !== null) return edit(bot, chatId, messageId, resultText(action, payload, started.replay));
  await edit(bot, chatId, messageId, 'Processing…');

  let response;
  try {
    const c = getCredentials(BRANDS[payload.brand ?? '888starz']);
    response = action === 'deposit'
      ? await depositToPlayer(c, payload.userId, payload.lng, payload.summa)
      : await payoutToPlayer(c, payload.userId, payload.lng, payload.code);
  } catch (err) {
    if (err instanceof ApiError && err.status !== 502) {
      // CashdeskBot never accepted it: free the key.
      await rpc('telegram_abort', { p_telegram_user_id: from.id, p_pending_id: pendingId }).catch(() => {});
      return edit(bot, chatId, messageId, `❌ ${escape(err.message)}`);
    }
    // It may or may not have gone through, so the key stays taken and the
    // same request can't be confirmed again.
    console.error(err);
    return edit(
      bot,
      chatId,
      messageId,
      `⚠️ CashdeskBot did not answer clearly (${escape((err as Error).message)}). ` +
        'Check the player and the cash register balance before trying again.',
    );
  }
  await rpc('telegram_finish', {
    p_telegram_user_id: from.id,
    p_pending_id: pendingId,
    p_action: action,
    p_user_id: payload.userId,
    p_audit: { brand: payload.brand ?? '888starz', ...(action === 'deposit' ? { lng: payload.lng, summa: payload.summa } : response) },
    p_response: response,
  });
  return edit(bot, chatId, messageId, resultText(action, payload, response));
}

function errorText(bot: Bot, err: unknown) {
  if (err instanceof ApiError) {
    if (err.code === 'TELEGRAM_NOT_LINKED') return notLinked(bot);
    return `❌ ${escape(err.message)}`;
  }
  return '❌ Something went wrong. Please try again.';
}

// ---------------------------------------------------------------------------
// Webhook
// ---------------------------------------------------------------------------

function secretMatches(given: string | null) {
  const expected = Deno.env.get('TELEGRAM_WEBHOOK_SECRET') ?? '';
  if (!expected || !given || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

async function setup(bot: Bot) {
  const url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/telegram-bot${bot.path}`;
  const webhook = await telegram(bot, 'setWebhook', {
    url,
    secret_token: Deno.env.get('TELEGRAM_WEBHOOK_SECRET'),
    allowed_updates: ['message', 'callback_query'],
    drop_pending_updates: true,
  });
  const commands = await telegram(bot, 'setMyCommands', { commands: COMMANDS, scope: { type: 'all_private_chats' } });
  return { webhook, commands, url };
}

async function onUpdate(bot: Bot, update: any) {
  if (update.callback_query) {
    const q = update.callback_query;
    const chatId = q.message?.chat?.id;
    await telegram(bot, 'answerCallbackQuery', { callback_query_id: q.id });
    if (!chatId || q.message.chat.type !== 'private') return;
    try {
      await onButton(bot, chatId, q.message.message_id, q.from, q.data ?? '');
    } catch (err) {
      if (!(err instanceof ApiError)) console.error(err);
      await edit(bot, chatId, q.message.message_id, errorText(bot, err));
    }
    return;
  }

  const m = update.message;
  if (!m?.text || !m.from || m.chat?.type !== 'private') return;
  const chatId = m.chat.id;
  try {
    if (m.text.startsWith('/')) await onCommand(bot, chatId, m.from, m.text);
    else await send(bot, chatId, help(bot));
  } catch (err) {
    if (!(err instanceof ApiError)) console.error(err);
    await send(bot, chatId, errorText(bot, err));
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST' || !secretMatches(req.headers.get('X-Telegram-Bot-Api-Secret-Token'))) {
    return new Response('Forbidden', { status: 403 });
  }
  // .../telegram-bot[/1xbet|/winwin|/betwinner|/dbbet|/betjam|/betongame][/setup]
  const parts = new URL(req.url).pathname.split('/').filter(Boolean);
  const rest = parts.slice(parts.indexOf('telegram-bot') + 1);
  const isSetup = rest[rest.length - 1] === 'setup';
  const path = rest.slice(0, isSetup ? -1 : undefined).map((p) => `/${p}`).join('');
  const bot = BOTS.find((b) => b.path === path);
  if (!bot) return new Response('Not found', { status: 404 });
  if (isSetup) {
    return new Response(JSON.stringify(await setup(bot)), { headers: { 'Content-Type': 'application/json' } });
  }
  const update = await req.json().catch(() => null);
  // Always 200: Telegram re-sends an update until it gets one, and a
  // re-sent command must not run twice.
  if (update) await onUpdate(bot, update).catch((err) => console.error(err));
  return new Response('ok');
});
