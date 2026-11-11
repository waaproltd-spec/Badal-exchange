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

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Telegram call with retry for temporary failures: 429 (it says how long to wait, at most 5 s here) and 5xx are retried
 *  twice; a network error is retried once, and only for calls that cannot send a message twice. */
function telegram(token: string) {
  return async (method: string, body: Record<string, unknown>) => {
    const base = (Deno.env.get('TELEGRAM_API_BASE') || 'https://api.telegram.org').replace(/\/$/, '');
    for (let attempt = 0; ; attempt++) {
      let res: Response;
      let data: any = {};
      try {
        res = await fetch(`${base}/bot${token}/${method}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(15_000),
        });
        data = await res.json().catch(() => ({}));
      } catch (err) {
        if (attempt < 1 && (method === 'getUpdates' || method === 'editMessageText')) { await sleep(800); continue; }
        throw err;
      }
      if (data.ok) return data.result;
      // An edit with the same text is not a failure.
      if (/message is not modified/i.test(data.description ?? '')) return data.result;
      const wait = Number(data.parameters?.retry_after ?? 0);
      if (res.status === 429 && wait > 0 && wait <= 5 && attempt < 2) { await sleep(wait * 1000 + 300); continue; }
      if (res.status >= 500 && attempt < 2) { await sleep(700 * (attempt + 1)); continue; }
      throw new Error(`Telegram ${method}: ${data.description ?? res.status}`);
    }
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
  phone: string | null; customerName: string | null; customerPhone: string | null; customerId?: string | null; reference: string | null;
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
    `Customer ID: <code>${esc(o.customerId ?? '—')}</code>`,
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


/** HH:mm in Mogadishu. */
const hm = (iso: unknown) => {
  const d = new Date(String(iso ?? ''));
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleTimeString('en-GB', { timeZone: 'Africa/Mogadishu', hour: '2-digit', minute: '2-digit', hour12: false });
};
const dmy = (day: string) => `${day.slice(8, 10)}/${day.slice(5, 7)}/${day.slice(0, 4)}`;
const usd = (v: unknown) => `$${esc(v ?? '0.00')}`;
const DIR: Record<string, string> = { deposit: 'dhigasho', withdraw: 'lacag-bixin' };

/** The daily report as Telegram messages (HTML, each under 3800 characters). Only figures from the database. */
function reportParts(day: string, d: any, saved = true): string[] {
  const live = d.live === true || !saved;
  const head =
    `📊 <b>WARBIXINTA MAALINTA — ${esc(dmy(day))}</b>\n` +
    `🕛 00:00 → 23:59:59 (waqtiga Soomaaliya)${live ? '\n⏳ <i>Maalintu wali ma dhammaan: tirooyinkan waa ilaa hadda.</i>' : ''}\n\n` +
    `💰 Dhigashooyin: <b>${d.deposits?.count ?? 0}</b> — ${usd(d.deposits?.total)}\n` +
    `💸 Bixinno: <b>${d.withdrawals?.count ?? 0}</b> — ${usd(d.withdrawals?.total)}\n` +
    `✅ Lacagta la siiyay macaamiisha (payouts): ${usd(d.payouts?.total)}\n` +
    `🔁 Macaamilada dhammaaday: <b>${d.transactions ?? 0}</b>\n` +
    `🟡 Sugaya: <b>${d.pending?.count ?? 0}</b> — ${usd(d.pending?.total)}\n` +
    `❌ Fashilmay: <b>${d.failed?.count ?? 0}</b> — ${usd(d.failed?.total)}` +
    (d.otherClosed ? ` (+ ${d.otherClosed} la joojiyay/dhacay)` : '') + `\n` +
    `🏆 Dakhliga wakiilada (commission): ${usd(d.earnings?.total)} (${d.earnings?.count ?? 0} macaamil)`;

  const top = (d.topCustomers ?? []) as any[];
  const people =
    `👑 <b>Top 5 macaamiil</b> (tirada lacagta)\n` +
    (top.length === 0 ? 'Macaamil dhammaystiray ma jiro.' : top.map((c, i) =>
      `${i + 1}. ${esc(c.name)} <code>${esc(c.customerId ?? '—')}</code> <code>${esc(c.phone ?? '—')}</code>\n    Dhigasho ${usd(c.deposits)} · Bixin ${usd(c.withdrawals)} · Wadar <b>${usd(c.volume)}</b> · ${c.count} macaamil`).join('\n')) +
    `\n\n🧑‍💼 <b>Wakiilada</b> (dakhli)\n` +
    ((d.agents ?? []).length === 0 ? 'Commission lama diiwaangelin.' : (d.agents as any[]).map((a, i) =>
      `${i + 1}. ${esc(a.name)}: ${usd(a.earned)} · ${a.orders} macaamil · ${usd(a.volume)}`).join('\n'));

  const e = d.errors ?? {};
  const lines: string[] = [];
  for (const o of (e.failedOrders ?? []) as any[]) {
    lines.push(`• <code>${esc(o.code)}</code> ${esc(DIR[o.direction] ?? o.direction)} ${esc(METHOD[o.method] ?? o.method)} ${usd(o.amount)} ${esc(hm(o.at))} — ${esc(o.reason ?? 'sabab lama helin')}`);
  }
  for (const i of (e.incidents?.list ?? []) as any[]) {
    lines.push(`• ${i.kind === 'blocked' ? '🚫' : '❌'} ${esc(DIR[i.direction] ?? i.direction)} ${esc(i.code ?? 'dalab la'+"'"+'la')} ${esc(METHOD[i.method] ?? i.method ?? '—')} ${i.amount ? usd(i.amount) : ''} ${esc(hm(i.at))} — ${esc(i.reason ?? '—')}`);
  }
  for (const h of (e.health ?? []) as any[]) {
    lines.push(`• ${h.severity === 'critical' ? '🚨' : '⚠️'} ${esc(h.title)} (${h.status === 'open' ? 'weli furan' : 'la xaliyay'}) ${esc(hm(h.at))}`);
  }
  for (const o of (e.stuck?.list ?? []) as any[]) {
    lines.push(`• ⏳ <code>${esc(o.code)}</code> ${esc(DIR[o.direction] ?? o.direction)} ${esc(METHOD[o.method] ?? o.method)} ${usd(o.amount)} ${esc(STATE_SO[o.status] ?? o.status)} ${esc(o.hours)} saac`);
  }
  if ((e.stuck?.count ?? 0) > (e.stuck?.list ?? []).length) lines.push(`… iyo ${(e.stuck.count) - (e.stuck.list ?? []).length} kale oo weli sugaya`);
  const counts =
    `Dalabyo fashilmay: ${d.failed?.count ?? 0} · isku-day la diiday/fashilmay: ${e.incidents?.count ?? 0} · ` +
    `lacag la'aan (haraaga shirkadda): ${e.insufficientBalance ?? 0} · weli lama xalliyin: ${e.stuck?.count ?? 0}`;
  const errors = `🚨 <b>Khaladaad iyo dhibaatooyin</b>\n${counts}` + (lines.length ? `\n${lines.join('\n')}` : '\n✅ Khalad muhiim ah ma jiro.');

  const out: string[] = [];
  let cur = '';
  for (const block of [head, people, errors]) {
    for (const piece of block.length <= 3800 ? [block] : block.split(/\n(?=• )/).reduce<string[]>((acc, l) => {
      if (acc.length && acc[acc.length - 1].length + l.length < 3800) acc[acc.length - 1] += '\n' + l; else acc.push(l);
      return acc;
    }, [])) {
      if (cur && cur.length + piece.length + 2 > 3800) { out.push(cur); cur = piece; } else cur = cur ? `${cur}\n\n${piece}` : piece;
    }
  }
  if (cur) out.push(cur);
  return out;
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
    if (!msg?.chat?.id) continue;
    const text = String(msg.text ?? '').trim();
    // /report [YYYY-MM-DD]: only in the linked chat; a saved report, or today so far.
    const rep = text.match(/^\/report(?:@\w+)?(?:\s+(\d{4}-\d{2}-\d{2}))?$/);
    if (rep) {
      if (state?.chatId == null || Number(state.chatId) !== Number(msg.chat.id)) continue; // not the agent's chat: no answer
      const r = await rpc('daily_report_get', { p_day: rep[1] ?? null });
      if (!r) {
        await tg('sendMessage', { chat_id: msg.chat.id, text: 'Taariikhdaas warbixin ma jirto.' });
      } else {
        for (const part of reportParts(String(r.day), r.data, r.saved === true)) {
          await tg('sendMessage', { chat_id: msg.chat.id, text: part, parse_mode: 'HTML', disable_web_page_preview: true });
        }
      }
      continue;
    }
    // /movehere said in a group by the person whose private chat receives the alerts: the alerts and the report move to the group.
    if (/^\/movehere(?:@\w+)?$/.test(text)) {
      if (msg.chat.type !== 'group' && msg.chat.type !== 'supergroup') continue;
      const moved = msg.from?.id != null && (await rpc('withdrawal_alerts_move', {
        p_from: msg.from.id, p_chat_id: msg.chat.id, p_chat_name: msg.chat.title || String(msg.chat.id) }));
      if (moved) {
        await tg('sendMessage', { chat_id: msg.chat.id,
          text: '✅ Digniinaha lacag-bixinta, dhigashooyinka, khaladaadka iyo warbixinta maalinlaha ah (subaxdii 08:00) hadda halkan ayay ka imaanayaan. Qor /report si aad u aragto maanta ilaa hadda.' });
      }
      continue;
    }
    if (!/^\/start\b/.test(text)) continue;
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
        `Customer ID: <code>${esc(i.customerId ?? '—')}</code>\n` +
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
  // Suspicious activity (migrations/*_security_hardening.sql): said once, in Somali.
  // Only said: nothing is blocked, refunded or changed here.
  const security: any[] = (await rpc('security_events_todo')) ?? [];
  for (const e of security) {
    await tg('sendMessage', { chat_id: chat, parse_mode: 'HTML',
      text: `🚨 <b>Digniin amni — ${esc(e.title)}</b>\n${esc(e.detail)}\nWaqtiga: ${esc(when(e.at))}` });
    sent++;
  }
  if (security.length > 0) await rpc('security_events_sent', { p_ids: security.map((e) => e.id) });
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
  // The daily report (closed at 00:00 Mogadishu, sent in the morning) and the real-time notices of the group
  // (migrations/*_group_daily_report.sql). Only said: nothing here sends money or changes an order.
  const g = await rpc('group_report_todo');
  if (g?.chatId) {
    if (g.report) {
      const day = String(g.report.day);
      const parts = reportParts(day, g.report.data);
      try {
        for (let i = Number(g.report.partsSent ?? 0); i < parts.length; i++) {
          await tg('sendMessage', { chat_id: g.chatId, text: parts[i], parse_mode: 'HTML', disable_web_page_preview: true });
          await rpc('daily_report_sent', { p_day: day, p_parts: i + 1, p_done: i + 1 === parts.length });
          sent++;
        }
      } catch (err) {
        await rpc('daily_report_sent', { p_day: day, p_parts: 0, p_done: false, p_error: (err as Error).message }).catch(() => {});
        throw err;
      }
    }
    for (const d of (g.deposits ?? []) as any[]) {
      await tg('sendMessage', { chat_id: g.chatId, parse_mode: 'HTML',
        text: `💰 <b>Dhigasho guuleystay</b>
Macmiilka: ${esc(d.customer)}\nCustomer ID: <code>${esc(d.customerId ?? '—')}</code> · <code>${esc(d.phone ?? '—')}</code>
Lacagta: <b>${usd(d.amount)}</b>
` +
          `Shirkadda: ${esc(METHOD[d.method] ?? d.method)}
Lambarka: <code>${esc(d.code)}</code>${d.reference ? `
Tixraaca: <code>${esc(d.reference)}</code>` : ''}
Waqtiga: ${esc(when(d.at))}` });
      await rpc('group_notified_mark', { p_kind: 'deposit', p_keys: [d.key] });
      sent++;
    }
    for (const f of (g.failed ?? []) as any[]) {
      await tg('sendMessage', { chat_id: g.chatId, parse_mode: 'HTML',
        text: `❌ <b>${f.direction === 'deposit' ? 'Dhigasho' : 'Lacag-bixin'} fashilmay</b>
Macmiilka: ${esc(f.customer)}\nCustomer ID: <code>${esc(f.customerId ?? '—')}</code> · <code>${esc(f.phone ?? '—')}</code>
Lacagta: ${usd(f.amount)}
` +
          `Shirkadda: ${esc(METHOD[f.method] ?? f.method)}
Lambarka: <code>${esc(f.code)}</code>
Waqtiga: ${esc(when(f.at))}
Sababta: ${esc(f.reason ?? 'sabab lama helin')}` });
      await rpc('group_notified_mark', { p_kind: 'failed', p_keys: [f.key] });
      sent++;
    }
    if (g.sahalLow) {
      await tg('sendMessage', { chat_id: g.chatId, parse_mode: 'HTML',
        text: `⚠️ <b>Haraaga Sahal waa hooseeyaa</b>
Haraaga: ${usd(g.sahalLow.balance)} · ugu yaraan loo baahan yahay: ${usd(g.sahalLow.min)}
Lacag-bixinada waa la hakin karaa ilaa la kordhiyo haraaga.` });
      await rpc('group_notified_mark', { p_kind: 'sahal_low', p_keys: [g.sahalLow.key] });
      sent++;
    }
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
