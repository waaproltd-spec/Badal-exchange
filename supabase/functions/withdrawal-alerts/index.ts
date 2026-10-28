// Withdrawal alerts on Telegram (migrations/*_withdrawal_alerts.sql). Woken
// every 30 seconds, and by each new withdrawal, by the database with the
// platform worker secret. A withdrawal not paid after 30 seconds is
// reminded once with why; Sahal needing a person is said at once.
//
// Alerts only: reads withdrawals and Sahal transfers, sends/edits messages.
// Nothing here sends money or changes an order, and no PIN, password or
// login is ever put in a message.
//
// Linking: the first chat that sends /start to the bot receives the alerts.
// Any other chat (a customer, a stranger) gets no answer at all, and every
// other message is ignored: the bot never talks to anyone but the agent's
// linked chat. A manager can unlink it
// (manage_withdrawal_alerts) so the next /start links.
//
// Secret: TELEGRAM_N8N_BOT_TOKEN [, TELEGRAM_API_BASE (tests)]
const METHOD: Record<string, string> = { evc_plus: 'EVC Plus', golis: 'Golis (Sahal)', telesom: 'ZAAD', edahab: 'eDahab' };

async function rpc(fn: string, args: Record<string, unknown> = {}) {
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
  if (!res.ok) throw new Error(`${fn}: ${data?.message ?? res.status}`);
  return data;
}

function telegram(token: string) {
  return async (method: string, body: Record<string, unknown>) => {
    const base = (Deno.env.get('TELEGRAM_API_BASE') || 'https://api.telegram.org').replace(/\/$/, '');
    const res = await fetch(`${base}/bot${token}/${method}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const data = await res.json().catch(() => ({}));
    // An edit with the same text is not a failure.
    if (!data.ok && !/message is not modified/i.test(data.description ?? '')) {
      throw new Error(`Telegram ${method}: ${data.description ?? res.status}`);
    }
    return data.result;
  };
}

const esc = (s: unknown) => String(s ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]!);

type Order = {
  orderId: string; orderCode: string; method: string; status: string; payout: string; amount: string;
  phone: string | null; customerName: string | null; customerPhone: string | null; reference: string | null;
  reason: string | null; review: boolean; messageId?: number;
  delay?: { code: string; note: string | null; seconds: number } | null;
};

/** Why it still waits (migrations/*_withdrawal_speed.sql, withdrawal_delay). */
const DELAY: Record<string, string> = {
  provider_unavailable: 'Sahal is refusing or not answering; it goes out by itself once Sahal works again.',
  provider_balance: 'Sahal balance is below this amount: top up Sahal; it then goes out by itself.',
  confirming: 'The transfer is being confirmed. It is never resent: check Sahal before paying by hand.',
  manual: 'Needs an agent: pay it by hand or reject it (the customer is refunded).',
  waiting: 'In the queue for Sahal.',
};
const delayText = (o: Order) =>
  o.delay ? `${DELAY[o.delay.code] ?? o.delay.code}${o.delay.note ? `\nSahal said: ${esc(o.delay.note)}` : ''}` : '';

const SAHAL: Record<string, (s: any) => string> = {
  code: (s) => `🔐 <b>Sahal needs its SMS code</b>\nOpen the Agent App → Sahal Sign-in and type the code sent to the merchant phone (10 minutes).\nWithdrawals waiting: ${s.waitingCount}`,
  stopped: (s) => `⛔ <b>Sahal sign-in stopped</b>\n${esc(s.message ?? '')}\nOpen the Agent App → Sahal Sign-in → Sign in again.\nWithdrawals waiting: ${s.waitingCount}`,
  refused: (s) => `⚠️ <b>Sahal refuses transfers</b>\n${esc(s.message ?? '')}\nWithdrawals waiting: ${s.waitingCount}`,
  unreachable: (s) => `📡 <b>Sahal cannot be reached</b>\n${esc(s.message ?? '')}\nWithdrawals wait and go out by themselves when it answers.`,
  ok: () => '✅ <b>Sahal works again</b>: waiting withdrawals are being sent.',
};

const shownStatus = (o: Order) => o.status + (o.review ? ':review' : '');

function orderText(o: Order) {
  const head = {
    pending: '💸 <b>Withdrawal waiting</b>',
    processing: '⏳ <b>Withdrawal being paid</b>',
    completed: '✅ <b>Withdrawal paid</b>',
    failed: '❌ <b>Withdrawal failed</b>',
    cancelled: '❌ <b>Withdrawal cancelled</b>',
    expired: '❌ <b>Withdrawal expired</b>',
  }[o.status] ?? `<b>Withdrawal ${esc(o.status)}</b>`;
  const lines = [
    head,
    `Code: <code>${esc(o.orderCode)}</code>`,
    `Send: <b>$${esc(o.payout)}</b> by ${esc(METHOD[o.method] ?? o.method)}`,
    `To: <code>${esc(o.phone)}</code>`,
    `Customer: ${esc(o.customerName ?? '—')} (${esc(o.customerPhone ?? '')})`,
  ];
  if (o.review) lines.push('⚠️ Held for review: check the payout before anything else.');
  if (o.status === 'completed') lines.push(`Reference: <code>${esc(o.reference ?? '—')}</code>`);
  if (o.reason) lines.push(`Reason: ${esc(o.reason)}`);
  return lines.join('\n');
}

async function run() {
  const token = Deno.env.get('TELEGRAM_N8N_BOT_TOKEN');
  if (!token) return { skipped: 'TELEGRAM_N8N_BOT_TOKEN not set' };
  const tg = telegram(token);

  // 1. /start from chats: link the first, refuse the others.
  const state = await rpc('withdrawal_alerts_state');
  let offset = Number(state?.offset ?? 0);
  const updates: any[] = await tg('getUpdates', { offset, timeout: 0, allowed_updates: ['message'] });
  for (const u of updates ?? []) {
    offset = Math.max(offset, Number(u.update_id) + 1);
    const msg = u.message;
    if (!msg?.chat?.id || !/^\/start\b/.test(String(msg.text ?? ''))) continue;
    const name = [msg.chat.title, msg.chat.username && `@${msg.chat.username}`, msg.chat.first_name].filter(Boolean).join(' ');
    const ok = await rpc('withdrawal_alerts_link', { p_chat_id: msg.chat.id, p_chat_name: name || String(msg.chat.id) });
    if (!ok) continue; // not the agent's chat: no answer
    await tg('sendMessage', {
      chat_id: msg.chat.id,
      text: 'Badal Exchange withdrawal alerts are on for this chat. New withdrawals will appear here.',
    });
  }
  await rpc('withdrawal_alerts_report', { p_offset: offset });

  // 2. What to send.
  const todo = await rpc('withdrawal_alerts_todo');
  const chat = todo?.chatId;
  if (!chat) return { linked: false };
  let sent = 0;
  for (const o of (todo.new ?? []) as Order[]) {
    const m = await tg('sendMessage', { chat_id: chat, text: orderText(o), parse_mode: 'HTML' });
    await rpc('withdrawal_alerts_sent', { p_kind: 'new', p_id: o.orderId, p_chat_id: chat, p_message_id: m.message_id, p_status: shownStatus(o) });
    sent++;
  }
  for (const o of (todo.changed ?? []) as Order[]) {
    await tg('editMessageText', { chat_id: chat, message_id: o.messageId, text: orderText(o), parse_mode: 'HTML' });
    if (o.review) {
      await tg('sendMessage', { chat_id: chat, reply_to_message_id: o.messageId,
        text: `⚠️ ${o.orderCode}: the payout result is unclear. Check the wallet history before paying again.` });
    }
    await rpc('withdrawal_alerts_sent', { p_kind: 'changed', p_id: o.orderId, p_status: shownStatus(o) });
    sent++;
  }
  for (const o of (todo.remind ?? []) as Order[]) {
    await tg('sendMessage', { chat_id: chat, reply_to_message_id: o.messageId,
      parse_mode: 'HTML',
      text: `⏰ <b>${esc(o.orderCode)} not paid after ${esc(o.delay?.seconds ?? 30)} s</b>: $${esc(o.payout)} to <code>${esc(o.phone)}</code>.\n${delayText(o)}` });
    await rpc('withdrawal_alerts_sent', { p_kind: 'remind', p_id: o.orderId });
    sent++;
  }
  for (const t of todo.strays ?? []) {
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML',
      text: `⚠️ <b>Sahal transfer matched no withdrawal</b>\n$${esc(t.amount)} to <code>${esc(t.receiver)}</code>\n` +
        `Sahal ref: <code>${esc(t.transactionId)}</code>\nCheck the amount and number (or a second payment).` });
    await rpc('withdrawal_alerts_sent', { p_kind: 'stray', p_id: t.id });
    sent++;
  }
  if (todo.sahal) {
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML', text: (SAHAL[todo.sahal.kind] ?? SAHAL.refused)(todo.sahal) });
    await rpc('withdrawal_alerts_sahal_sent', { p_key: todo.sahal.key ?? null });
    sent++;
  }
  const s = todo.summary;
  if (s) {
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML',
      text: `📊 <b>Withdrawals ${esc(s.day)}</b>\nPaid: ${s.paidCount} ($${esc(s.paidTotal)})\n` +
        `Failed/cancelled: ${s.failedCount}\nStill waiting: ${s.waitingCount} ($${esc(s.waitingTotal)})` });
    await rpc('withdrawal_alerts_sent', { p_kind: 'summary', p_id: null, p_day: s.day });
    sent++;
  }
  return { linked: true, sent };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Forbidden', { status: 403 });
  const secret = req.headers.get('x-worker-secret');
  if (!secret || (await rpc('platform_worker_check', { p_secret: secret }).catch(() => false)) !== true) {
    return new Response('Forbidden', { status: 403 });
  }
  try {
    return Response.json(await run());
  } catch (err) {
    // The bot token never appears in the message (Telegram errors don't echo it).
    const message = (err as Error).message.replaceAll(Deno.env.get('TELEGRAM_N8N_BOT_TOKEN') ?? '\u0000', '•••');
    await rpc('withdrawal_alerts_report', { p_offset: null, p_error: message }).catch(() => {});
    return Response.json({ error: message }, { status: 502 });
  }
});
