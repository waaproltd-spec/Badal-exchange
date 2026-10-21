// Telegram cashier bot for the CashdeskBot partner API: player search, the
// cash register's balance, player deposits and payouts, from a private chat
// with the bot. Telegram calls this function as its webhook.
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
// Secrets (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase):
//   supabase secrets set TELEGRAM_BOT_TOKEN=... TELEGRAM_WEBHOOK_SECRET=... [TELEGRAM_BOT_LNG=en]
// plus the CASHDESKBOT_* secrets (../_shared/cashdeskbot.ts). Then register
// the webhook and the command menu once:
//   curl -X POST -H "X-Telegram-Bot-Api-Secret-Token: $TELEGRAM_WEBHOOK_SECRET" \
//     https://<project>.supabase.co/functions/v1/telegram-bot/setup
import {
  ApiError,
  cashdeskBalance,
  depositToPlayer,
  findPlayer,
  getCredentials,
  payoutToPlayer,
  type Player,
} from '../_shared/cashdeskbot.ts';

const LNG = Deno.env.get('TELEGRAM_BOT_LNG') || 'en';

const COMMANDS = [
  { command: 'balance', description: 'Cash register balance' },
  { command: 'player', description: 'Find a player: /player ID' },
  { command: 'deposit', description: 'Top up a player: /deposit ID AMOUNT' },
  { command: 'payout', description: 'Pay out a code: /payout ID CODE' },
  { command: 'help', description: 'Commands' },
  { command: 'unlink', description: 'Unlink this Telegram account' },
];

const HELP = [
  '<b>888starz cashier: commands</b>',
  '/balance: cash register balance and limit',
  '/player ID: find a player',
  '/deposit ID AMOUNT: top up a player',
  '/payout ID CODE: pay out a player\'s withdrawal code',
  '/unlink: unlink this Telegram account',
  '',
  'Deposits and payouts ask you to confirm first.',
].join('\n');

const NOT_LINKED = [
  'This is the 888starz cashier bot. Your Telegram account is not linked yet.',
  '',
  'In the Agent App open <b>Account → Admin features → Telegram Bot</b>, get a link code, then send it here as',
  '<code>/link CODE</code>',
].join('\n');

const escape = (s: unknown) =>
  String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ---------------------------------------------------------------------------
// Telegram Bot API
// ---------------------------------------------------------------------------

async function telegram(method: string, body: Record<string, unknown>) {
  const res = await fetch(`${Deno.env.get('TELEGRAM_API_URL') || 'https://api.telegram.org'}/bot${Deno.env.get('TELEGRAM_BOT_TOKEN')}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!data?.ok) console.error(`telegram ${method} failed`, res.status, data?.description);
  return data;
}

const send = (chatId: number, text: string, extra: Record<string, unknown> = {}) =>
  telegram('sendMessage', { chat_id: chatId, text, parse_mode: 'HTML', disable_web_page_preview: true, ...extra });

const edit = (chatId: number, messageId: number, text: string) =>
  telegram('editMessageText', { chat_id: chatId, message_id: messageId, text, parse_mode: 'HTML' });

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

const notFound = (id: string) => `❌ No 888starz player with ID ${escape(id)}.`;

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

async function onCommand(chatId: number, from: From, text: string) {
  const [rawCommand, ...args] = text.trim().split(/\s+/);
  const command = rawCommand.toLowerCase().replace(/@.*$/, '');

  // `/start CODE` is what a t.me/<bot>?start=CODE link sends.
  if (command === '/link' || (command === '/start' && args[0])) {
    if (!args[0]) return send(chatId, 'Send the code from the Agent App: <code>/link CODE</code>');
    const me = await rpc('telegram_link', {
      p_telegram_user_id: from.id,
      p_telegram_username: from.username ?? null,
      p_code: args[0],
    });
    return send(chatId, `Linked to <b>${escape(me.name)}</b> (${escape(me.role)}).\n\n${HELP}`);
  }
  if (command === '/unlink') {
    await rpc('telegram_unlink', { p_telegram_user_id: from.id });
    return send(chatId, 'This Telegram account is no longer linked.');
  }

  // Everything else needs a linked manager.
  let me;
  try {
    me = await rpc('telegram_whoami', { p_telegram_user_id: from.id });
  } catch (err) {
    if (err instanceof ApiError && err.code === 'TELEGRAM_NOT_LINKED') {
      return send(chatId, `${NOT_LINKED}\n\nYour Telegram ID: <code>${from.id}</code>`);
    }
    throw err;
  }

  switch (command) {
    case '/start':
    case '/help':
      return send(chatId, `Hi ${escape(me.name)}.\n\n${HELP}`);

    case '/balance': {
      const b = await cashdeskBalance(getCredentials(), new Date());
      return send(chatId, `<b>Cash register</b>\nBalance: <b>${escape(b.balance ?? '—')}</b>\nLimit: ${escape(b.limit ?? '—')}`);
    }

    case '/player':
    case '/user': {
      const [id] = args;
      if (!id || !PLAYER_ID.test(id)) return send(chatId, 'Usage: <code>/player ID</code>');
      const player = await findPlayer(getCredentials(), id);
      return send(chatId, player.found ? playerLine(player, id) : notFound(id));
    }

    case '/deposit': {
      const [id, amount] = args;
      if (!id || !PLAYER_ID.test(id) || !amount || !AMOUNT.test(amount) || !(Number(amount) > 0)) {
        return send(chatId, 'Usage: <code>/deposit ID AMOUNT</code>, for example <code>/deposit 76 100</code>');
      }
      const player = await findPlayer(getCredentials(), id);
      if (!player.found) return send(chatId, notFound(id));
      const summa = Number(amount);
      const pendingId = await rpc('telegram_prepare', {
        p_telegram_user_id: from.id,
        p_action: 'deposit',
        p_payload: { userId: id, lng: LNG, summa },
      });
      return send(chatId, `<b>Deposit ${escape(summa)}</b>\n${playerLine(player, id)}\n\nConfirm?`, confirmButtons(pendingId));
    }

    case '/payout': {
      const [id, code] = args;
      if (!id || !PLAYER_ID.test(id) || !code || !PAYOUT_CODE.test(code)) {
        return send(chatId, 'Usage: <code>/payout ID CODE</code>');
      }
      const player = await findPlayer(getCredentials(), id);
      if (!player.found) return send(chatId, notFound(id));
      const pendingId = await rpc('telegram_prepare', {
        p_telegram_user_id: from.id,
        p_action: 'payout',
        p_payload: { userId: id, lng: LNG, code },
      });
      return send(chatId, `<b>Payout</b>, code <code>${escape(code)}</code>\n${playerLine(player, id)}\n\nConfirm?`, confirmButtons(pendingId));
    }

    default:
      return send(chatId, HELP);
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

async function onButton(chatId: number, messageId: number, from: From, data: string) {
  const [choice, pendingId] = data.split(':');
  if (!pendingId) return;
  if (choice === 'no') {
    await rpc('telegram_cancel', { p_telegram_user_id: from.id, p_pending_id: pendingId });
    return edit(chatId, messageId, 'Cancelled.');
  }
  if (choice !== 'ok') return;

  const started = await rpc('telegram_begin', { p_telegram_user_id: from.id, p_pending_id: pendingId });
  const { action, payload } = started as { action: 'deposit' | 'payout'; payload: Record<string, any> };
  if (started.replay !== null) return edit(chatId, messageId, resultText(action, payload, started.replay));
  await edit(chatId, messageId, 'Processing…');

  let response;
  try {
    const c = getCredentials();
    response = action === 'deposit'
      ? await depositToPlayer(c, payload.userId, payload.lng, payload.summa)
      : await payoutToPlayer(c, payload.userId, payload.lng, payload.code);
  } catch (err) {
    if (err instanceof ApiError && err.status !== 502) {
      // CashdeskBot never accepted it: free the key.
      await rpc('telegram_abort', { p_telegram_user_id: from.id, p_pending_id: pendingId }).catch(() => {});
      return edit(chatId, messageId, `❌ ${escape(err.message)}`);
    }
    // It may or may not have gone through, so the key stays taken and the
    // same request can't be confirmed again.
    console.error(err);
    return edit(
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
    p_audit: action === 'deposit' ? { lng: payload.lng, summa: payload.summa } : response,
    p_response: response,
  });
  return edit(chatId, messageId, resultText(action, payload, response));
}

function errorText(err: unknown) {
  if (err instanceof ApiError) {
    if (err.code === 'TELEGRAM_NOT_LINKED') return NOT_LINKED;
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

async function setup() {
  const url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/telegram-bot`;
  const webhook = await telegram('setWebhook', {
    url,
    secret_token: Deno.env.get('TELEGRAM_WEBHOOK_SECRET'),
    allowed_updates: ['message', 'callback_query'],
    drop_pending_updates: true,
  });
  const commands = await telegram('setMyCommands', { commands: COMMANDS, scope: { type: 'all_private_chats' } });
  return { webhook, commands, url };
}

async function onUpdate(update: any) {
  if (update.callback_query) {
    const q = update.callback_query;
    const chatId = q.message?.chat?.id;
    await telegram('answerCallbackQuery', { callback_query_id: q.id });
    if (!chatId || q.message.chat.type !== 'private') return;
    try {
      await onButton(chatId, q.message.message_id, q.from, q.data ?? '');
    } catch (err) {
      if (!(err instanceof ApiError)) console.error(err);
      await edit(chatId, q.message.message_id, errorText(err));
    }
    return;
  }

  const m = update.message;
  if (!m?.text || !m.from || m.chat?.type !== 'private') return;
  const chatId = m.chat.id;
  try {
    if (m.text.startsWith('/')) await onCommand(chatId, m.from, m.text);
    else await send(chatId, HELP);
  } catch (err) {
    if (!(err instanceof ApiError)) console.error(err);
    await send(chatId, errorText(err));
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST' || !secretMatches(req.headers.get('X-Telegram-Bot-Api-Secret-Token'))) {
    return new Response('Forbidden', { status: 403 });
  }
  if (new URL(req.url).pathname.endsWith('/setup')) {
    return new Response(JSON.stringify(await setup()), { headers: { 'Content-Type': 'application/json' } });
  }
  const update = await req.json().catch(() => null);
  // Always 200: Telegram re-sends an update until it gets one, and a
  // re-sent command must not run twice.
  if (update) await onUpdate(update).catch((err) => console.error(err));
  return new Response('ok');
});
