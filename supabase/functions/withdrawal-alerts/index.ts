// Withdrawal alerts on Telegram (migrations/*_withdrawal_alerts.sql). Woken
// every 30 seconds, and by each new withdrawal, by the database with the
// platform worker secret. A withdrawal not paid after 30 seconds is
// reminded once with why; Sahal needing a person is said at once.
//
// Every message to the admin chat is in Af-Soomaali (provider names such as
// EVC Plus, eDahab, ZAAD and Golis stay as they are).
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
const METHOD: Record<string, string> = {
  evc_plus: 'EVC Plus', golis: 'Golis (Sahal)', telesom: 'ZAAD', edahab: 'eDahab',
  onexbet: '1XBET', melbet: 'MELBET', betwinner: 'BetWinner', winwin: 'WinWin', '888starz': '888STARZ',
  dbbet: 'DBbet', betjam: 'BetJam', betongame: 'BetOnGame', luckypari: 'LuckyPari', goldpari: 'Goldpari', betandyou: 'Betandyou',
};
const STATE_SO: Record<string, string> = {
  pending: 'sugaysa', processing: 'socda', completed: 'dhammaaday', failed: 'fashilmay', cancelled: 'la joojiyay', expired: 'dhacay',
};

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

const STUCK: Record<string, string> = {
  withdrawal_unresolved: 'weli lama bixin (fiiri digniinta hore si aad u aragto sababta); waa la hayaa, lama dirayo mar kale lamana celinayo ilaa natiijo la helo',
  deposit_processing: 'dhigashada weli waa socotaa',
  expiry_not_running: 'dhigasho aan la bixin waa inuu dhacay: hubi shaqooyinka server-ka',
  platform_deposit_open: 'dhigasho goob-ciyaareed ayaa saacado furan: la xiriir kaashiyaha',
};

/** Waqtiga Soomaaliya (UTC+3). */
const when = (iso: unknown) => {
  const d = new Date(String(iso ?? ''));
  if (Number.isNaN(d.getTime())) return '—';
  return `${d.toLocaleString('en-GB', { timeZone: 'Africa/Mogadishu', hour12: false })} (waqtiga Soomaaliya)`;
};

/** Sababta khaladka, af-Soomaali: by code; the system's own text is only quoted. */
const WHY: Record<string, string> = {
  WITHDRAWAL_PROVIDER_BALANCE: 'Haraaga Sahal kuma filna lacagtan, sidaa darteed lacag-bixinta waa la joojiyay. Macmiilka lacag lagama jarin, dalab lama sameynin.',
  WITHDRAWAL_KYC_REQUIRED: 'Macmiilka KYC ma dhammaystirin oo xadka lacag-bixinta ee aan la xaqiijin wuu dhaafay.',
  WITHDRAWAL_DAILY_LIMIT: 'Macmiilku wuxuu gaadhay xadka maalinlaha ah ee lacag-bixinta.',
  WITHDRAWAL_MONTHLY_LIMIT: 'Macmiilku wuxuu gaadhay xadka bil kasta ee lacag-bixinta.',
  WITHDRAWAL_VERIFICATION_REQUIRED: 'Akoonka weli looma oggolaan lacag-bixinta marka ugu horreysa.',
  INSUFFICIENT_BALANCE: 'Haraaga boorsada macmiilka kuma filna.',
  DUPLICATE_WITHDRAWAL: 'Codsi lacag-bixin oo isku mid ah ayaa horey u socday.',
  NETWORK: 'Xiriirka internetka ama server-ka wuu go\'ay (waqtigii baa dhamaaday).',
  NETWORK_ERROR: 'Xiriirka internetka ama server-ka wuu go\'ay (waqtigii baa dhamaaday).',
  ERROR: 'Cilad aan la garanayn ayaa dhacday app-ka dhexdiisa.',
  ORDER_FAILED: 'Dalabka waa fashilmay; lacagta lama dhiibin ama waa la celiyay.',
  ORDER_UNVERIFIED: 'Lacagta lama xaqiijin karin (jawaab aan cadayn ayaa la helay); waxba lama kordhin, dib looma dirin.',
};
const whyText = (code: unknown, raw: unknown) => {
  const known = WHY[String(code ?? '')];
  const detail = String(raw ?? '').trim();
  const base = known ?? 'Cilad la xiriirta lacag-bixinta/dhigashada; fiiri koodka hoose.';
  return `${esc(base)}${detail ? `\nQoraalka asalka ah ee nidaamka: <code>${esc(detail)}</code>` : ''}`;
};

type Order = {
  orderId: string; orderCode: string; method: string; status: string; payout: string; amount: string;
  phone: string | null; customerName: string | null; customerPhone: string | null; reference: string | null;
  reason: string | null; review: boolean; messageId?: number; createdAt?: string;
  delay?: { code: string; note: string | null; seconds: number } | null;
};

/** Why it still waits (migrations/*_withdrawal_speed.sql, withdrawal_delay). */
const DELAY: Record<string, string> = {
  provider_unavailable: 'Sahal wuu diidayaa ama ma jawaabayo; si toos ah ayuu u baxayaa marka Sahal shaqeeyo.',
  provider_balance: 'Haraaga Sahal wuu ka yar yahay lacagtan: Sahal lacag ku shub; kadib si toos ah ayuu u baxayaa.',
  confirming: 'Wareejinta waa la xaqiijinayaa. Lama dirayo mar kale: Sahal hubi kahor intaadan gacanta ku bixin.',
  manual: 'Wakiil ayaa loo baahan yahay: gacanta ku bixi ama diid (macmiilka waa la celinayaa).',
  waiting: 'Sahal ayaa sugaya safka.',
};
const delayText = (o: Order) =>
  o.delay ? `${DELAY[o.delay.code] ?? o.delay.code}${o.delay.note ? `\nSahal wuxuu yiri: ${esc(o.delay.note)}` : ''}` : '';

const SAHAL: Record<string, (s: any) => string> = {
  code: (s) => `🔐 <b>Sahal wuxuu u baahan yahay koodhka SMS-ka</b>\nFur Agent App → Sahal Sign-in oo ku qor koodhka loo diray taleefanka ganacsiga (10 daqiiqo).\nLacag-bixinada sugaya: ${s.waitingCount}`,
  code_overdue: (s) => `🚨 <b>Koodhka Sahal 2 daqiiqo lama gelin</b>\nSMS forwarder-ku ma gelin. Fur Agent App → Sahal Sign-in oo ku qor koodhka loo diray taleefanka ganacsiga (wuxuu shaqeeyaa 10 daqiiqo). Dhigashooyinka waa la akhriyayaa inta fadhiga hore shaqeynayo; lacag-bixinada Sahal way sugayaan.\nLacag-bixinada sugaya: ${s.waitingCount}`,
  stopped: (s) => `⛔ <b>Galitaanka Sahal wuu joogsaday</b>\n${esc(s.message ?? '')}\nFur Agent App → Sahal Sign-in → Mar kale gal.\nLacag-bixinada sugaya: ${s.waitingCount}`,
  refused: (s) => `⚠️ <b>Sahal wuxuu diiday wareejinta</b>\n${esc(s.message ?? '')}\nLacag-bixinada sugaya: ${s.waitingCount}`,
  unreachable: (s) => `📡 <b>Sahal lama gaadhi karo</b>\n${esc(s.message ?? '')}\nLacag-bixinada way sugayaan oo si toos ah ayay u baxayaan marka Sahal jawaabo.`,
  ok: () => '✅ <b>Sahal wuu shaqeynayaa mar kale</b>: lacag-bixinada sugaya waa la dirayaa.',
};

const shownStatus = (o: Order) => o.status + (o.review ? ':review' : '');

function orderText(o: Order) {
  const head = {
    pending: '💸 <b>Lacag-bixin ayaa sugaysa</b>',
    processing: '⏳ <b>Lacag-bixinta waa la bixinayaa</b>',
    completed: '✅ <b>Lacag-bixinta waa la bixiyay</b>',
    failed: '❌ <b>Lacag-bixinta waa fashilantay</b>',
    cancelled: '❌ <b>Lacag-bixinta waa la joojiyay</b>',
    expired: '❌ <b>Lacag-bixintii waa dhacday</b>',
  }[o.status] ?? `<b>Lacag-bixin: ${esc(o.status)}</b>`;
  const state = {
    pending: 'Sugaysa', processing: 'La bixinayaa', completed: 'La bixiyay', failed: 'Fashilantay',
    cancelled: 'La joojiyay', expired: 'Dhacday',
  }[o.status] ?? o.status;
  const lines = [
    head,
    `Magaca macmiilka: ${esc(o.customerName ?? '—')}`,
    `Lambarka telefoonka: <code>${esc(o.customerPhone ?? '—')}</code>`,
    `Lambarka macaamilka: <code>${esc(o.orderCode)}</code>`,
    `Lacagta: <b>$${esc(o.payout)}</b>`,
    `Shirkadda lacagta: ${esc(METHOD[o.method] ?? o.method)}`,
    `Loo dirayo: <code>${esc(o.phone ?? '—')}</code>`,
    `Xaaladda macaamilka: ${esc(state)}`,
    `Waqtiga: ${esc(when(o.createdAt))}`,
  ];
  if (o.review) lines.push('⚠️ Waa la hayaa si loo hubiyo: hubi lacag-bixinta kahor wax kale.');
  if (o.status === 'completed') lines.push(`Tixraaca: <code>${esc(o.reference ?? '—')}</code>`);
  if (o.reason) lines.push(`Sababta saxda ah ee khaladka: ${whyText(o.status === 'failed' ? 'ORDER_FAILED' : null, o.reason)}`);
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
      text: 'Digniinaha lacag-bixinta ee Badal Exchange waa shaqeynayaan wada-hadalkan. Lacag-bixinada cusub halkan ayay ka muuqan doonaan.',
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
        text: `⚠️ ${o.orderCode}: natiijada lacag-bixinta ma cada. Hubi taariikhda boorsada kahor intaadan mar kale bixin.` });
    }
    await rpc('withdrawal_alerts_sent', { p_kind: 'changed', p_id: o.orderId, p_status: shownStatus(o) });
    sent++;
  }
  for (const o of (todo.remind ?? []) as Order[]) {
    await tg('sendMessage', { chat_id: chat, reply_to_message_id: o.messageId,
      parse_mode: 'HTML',
      text: `⏰ <b>${esc(o.orderCode)} lama bixin ${esc(o.delay?.seconds ?? 30)} ilbiriqsi kadib</b>: $${esc(o.payout)} loo dirayo <code>${esc(o.phone)}</code>.\n${delayText(o)}` });
    await rpc('withdrawal_alerts_sent', { p_kind: 'remind', p_id: o.orderId });
    sent++;
  }
  for (const t of todo.strays ?? []) {
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML',
      text: `⚠️ <b>Wareejin Sahal ah oo aan u dhigmin wax lacag-bixin ah</b>\n$${esc(t.amount)} loo diray <code>${esc(t.receiver)}</code>\n` +
        `Tixraaca Sahal: <code>${esc(t.transactionId)}</code>\nHubi lacagta iyo lambarka (ama lacag labaad oo la bixiyay).` });
    await rpc('withdrawal_alerts_sent', { p_kind: 'stray', p_id: t.id });
    sent++;
  }
  // Deposit / withdrawal errors and refused attempts (migrations/*_payment_safety.sql).
  // Only said: nothing is credited, paid, retried or changed here.
  const incidents: any[] = (await rpc('payment_incidents_todo')) ?? [];
  for (const i of incidents) {
    const icon = i.kind === 'blocked' ? '🚫' : '❌';
    const what = i.kind === 'blocked' ? 'La xannibay' : i.kind === 'unverified' ? 'Lama xaqiijin' : 'Fashilmay';
    const noMoney = i.direction === 'deposit'
      ? 'lacag lama kordhin boorsada macmiilka'
      : 'macmiilka lacag lagama jarin';
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML',
      text: `${icon} <b>${i.direction === 'deposit' ? 'Dhigasho' : 'Lacag-bixin'} — ${what}</b>\n` +
        `Magaca macmiilka: ${esc(i.customerName ?? '—')}\n` +
        `Lambarka telefoonka: <code>${esc(i.customerPhone ?? '—')}</code>\n` +
        `Lambarka macaamilka: <code>${esc(i.orderCode ?? 'dalab lama sameynin')}</code>\n` +
        `Lacagta: $${esc(i.amount ?? '—')}\n` +
        `Shirkadda lacagta: ${esc(METHOD[i.method] ?? i.method ?? '—')}\n` +
        `Xaaladda macaamilka: ${what} (${noMoney})\n` +
        `Waqtiga: ${esc(when(i.at))}\n` +
        `Sababta saxda ah ee khaladka: ${whyText(i.code, i.error)}\n` +
        `Koodhka khaladka: <code>${esc(i.code ?? '—')}</code>` });
    sent++;
  }
  if (incidents.length > 0) await rpc('payment_incidents_sent', { p_ids: incidents.map((i) => i.id) });
  if (todo.sahal) {
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML', text: (SAHAL[todo.sahal.kind] ?? SAHAL.refused)(todo.sahal) });
    await rpc('withdrawal_alerts_sahal_sent', { p_key: todo.sahal.key ?? null });
    sent++;
  }
  // Anything still unresolved far longer than it should be, for any order
  // (said once an hour). Only said: nothing is resent, refunded or changed.
  const stuck: any[] = (await rpc('stuck_orders_todo')) ?? [];
  if (stuck.length > 0) {
    const lines = stuck.map((o) =>
      `• <code>${esc(o.orderCode)}</code> ${o.direction === 'deposit' ? 'dhigasho' : 'lacag-bixin'} ${esc(METHOD[o.method] ?? o.method)} $${esc(o.amount)} ` +
      `${esc(STATE_SO[o.status] ?? o.status)} ${esc(o.hours)} saacadood: ${esc(STUCK[o.reason] ?? STUCK.withdrawal_unresolved)}`);
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML',
      text: `⏳ <b>Weli lama xalliyin</b> (digniintan waxba ma beddelayso: lacag dib looma dirayo, lamana celinayo)\n${lines.join('\n')}` });
    await rpc('stuck_orders_sent', { p_ids: stuck.map((o) => o.orderId) });
    sent++;
  }
  const s = todo.summary;
  if (s) {
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML',
      text: `📊 <b>Lacag-bixinada ${esc(s.day)}</b>\nWaqtiga: ${when(new Date().toISOString())}\nLa bixiyay: ${s.paidCount} ($${esc(s.paidTotal)})\n` +
        `Fashilmay/la joojiyay: ${s.failedCount}\nWeli sugaya: ${s.waitingCount} ($${esc(s.waitingTotal)})` });
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
