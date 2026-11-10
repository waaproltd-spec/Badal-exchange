// BADAL AI Developer Bot (Telegram): the owner sends a request, the bot plans it with Claude and a coding agent
// (GitHub Actions, .github/workflows/dev-agent.yml) does the work on a BRANCH and opens a PULL REQUEST.
//
// What it can NOT do, by design: merge, deploy by itself, change production data, read secrets. A production
// deployment (and anything that moves money, a migration or a security change) needs the owner's one-time approval
// button; a deployment is always preceded by a verified backup and by green Backend + Customer tests; every
// important action is in the audit log (public.dev_audit).
//
// Only Telegram accounts that are linked to a platform MANAGER (an administrator, or an agent with the manage_settings
// responsibility) and listed by the owner can talk to it
// (functions in supabase/migrations/*_dev_bot.sql). Somali and English: the bot answers in the language it is written in.
//
// Routes (Telegram calls the webhook; the rest are for the platform only):
//   POST /dev-bot            the Telegram webhook (X-Telegram-Bot-Api-Secret-Token)
//   POST /dev-bot/setup?key= registers the webhook and the command menu once
//   POST /dev-bot/report     the coding agent's progress and result (HMAC-SHA256 of the body, DEVBOT_REPORT_SECRET)
//   POST /dev-bot/tick       the database's timer (platform worker secret): stale tasks, the queue, CI results, backups
//
// Secrets (Supabase Edge Function secrets; SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided):
//   DEVBOT_TELEGRAM_TOKEN, DEVBOT_WEBHOOK_SECRET, DEVBOT_REPORT_SECRET, ANTHROPIC_API_KEY,
//   DEVBOT_GITHUB_TOKEN   a fine-grained token for this one repository: Actions (read and write), Contents (read),
//                         Pull requests (read), Metadata (read). It can not push code or merge.
//   [DEVBOT_REPO=owner/name, DEVBOT_BASE_BRANCH, DEVBOT_DEPLOY_REF, DEVBOT_AI_MODEL=claude-sonnet-5-5]
//   [DEVBOT_TELEGRAM_API_BASE, DEVBOT_GITHUB_API_BASE, DEVBOT_AI_API_BASE]   (tests)
const TG_BASE = (Deno.env.get('DEVBOT_TELEGRAM_API_BASE') || 'https://api.telegram.org').replace(/\/$/, '');
const GH_BASE = (Deno.env.get('DEVBOT_GITHUB_API_BASE') || 'https://api.github.com').replace(/\/$/, '');
const AI_BASE = (Deno.env.get('DEVBOT_AI_API_BASE') || 'https://api.anthropic.com').replace(/\/$/, '');
const MODEL = Deno.env.get('DEVBOT_AI_MODEL') || 'claude-sonnet-5-5';
const REPO = Deno.env.get('DEVBOT_REPO') || 'waaproltd-spec/Badal-exchange';
const BASE_BRANCH = () => Deno.env.get('DEVBOT_BASE_BRANCH') || 'main';
const DEPLOY_REF = () => Deno.env.get('DEVBOT_DEPLOY_REF') || BASE_BRANCH();

// ------------------------------------------------------------------ small helpers

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
export const esc = (s: unknown) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const clip = (s: unknown, n: number) => {
  const t = String(s ?? '');
  return t.length > n ? t.slice(0, n - 1) + '…' : t;
};

function token(): string {
  const t = Deno.env.get('DEVBOT_TELEGRAM_TOKEN');
  if (!t) throw new Error('DEVBOT_TELEGRAM_TOKEN not set');
  return t;
}

/** Error text without any of our secrets. */
function safe(err: unknown): string {
  let m = (err as Error)?.message ?? String(err);
  for (const k of ['DEVBOT_TELEGRAM_TOKEN', 'DEVBOT_WEBHOOK_SECRET', 'DEVBOT_REPORT_SECRET', 'ANTHROPIC_API_KEY', 'DEVBOT_GITHUB_TOKEN']) {
    const v = Deno.env.get(k);
    if (v) m = m.replaceAll(v, '•••');
  }
  return m;
}

function sameString(a: string | null, b: string | null | undefined): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)));
  return [...sig].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Somali or English, from the words of the message (Somali is the default). */
export function languageOf(text: string): 'so' | 'en' {
  const so = (text.toLowerCase().match(/\b(waa|waxaa|ku|ka|oo|iyo|fadlan|hadda|maxaa|sidee|samee|ii|u|aan|ma|ah|leh|adeeg|cusub|dar|hagaaji|tijaabi|dib|haa|maya|mahadsanid|bilow|shaqo)\b/g) ?? []).length;
  const en = (text.toLowerCase().match(/\b(the|and|please|add|fix|create|build|make|how|what|why|is|are|to|for|with|new|update|change|show|run|deploy|test)\b/g) ?? []).length;
  return en > so ? 'en' : 'so';
}

async function rpc(fn: string, args: Record<string, unknown> = {}) {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (!key.startsWith('sb_')) headers.Authorization = `Bearer ${key}`;
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`${fn}: ${data?.message ?? res.status}`);
  return data;
}

async function tg(method: string, body: Record<string, unknown>) {
  const res = await fetch(`${TG_BASE}/bot${token()}/${method}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok || data?.ok === false) throw new Error(`Telegram ${method}: ${data?.description ?? res.status}`);
  return data?.result;
}
const say = (chat: number, text: string, extra: Record<string, unknown> = {}) =>
  tg('sendMessage', { chat_id: chat, text: clip(text, 3900), parse_mode: 'HTML', disable_web_page_preview: true, ...extra });
const audit = (actor: number | null, action: string, target: string | null = null, ok = true, detail: Record<string, unknown> = {}) =>
  rpc('dev_audit_add', { p_actor: actor, p_action: action, p_target: target, p_ok: ok, p_detail: detail }).catch(() => null);

// ------------------------------------------------------------------ GitHub (a token that can only run workflows and read)

async function gh(path: string, init: RequestInit = {}) {
  const t = Deno.env.get('DEVBOT_GITHUB_TOKEN');
  if (!t) throw new Error('DEVBOT_GITHUB_TOKEN not set');
  const res = await fetch(`${GH_BASE}/repos/${REPO}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${t}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json', ...(init.headers ?? {}) },
    signal: AbortSignal.timeout(20_000),
  });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`GitHub ${path.split('?')[0]}: ${res.status} ${data?.message ?? ''}`);
  return data;
}
const dispatchWorkflow = (workflow: string, ref: string, inputs: Record<string, string>) =>
  gh(`/actions/workflows/${workflow}/dispatches`, { method: 'POST', body: JSON.stringify({ ref, inputs }) });

/** The Backend and Customer App steps of the newest test run of a commit: what the deployment gate reads. */
export type Ci = { state: 'none' | 'running' | 'done'; backend?: string; customer?: string; agent?: string; url?: string };
async function ciOf(sha: string): Promise<Ci> {
  const runs = await gh(`/actions/workflows/supabase-test.yml/runs?head_sha=${encodeURIComponent(sha)}&per_page=1`);
  const run = runs?.workflow_runs?.[0];
  if (!run) return { state: 'none' };
  const jobs = await gh(`/actions/runs/${run.id}/jobs`);
  const steps: any[] = (jobs?.jobs ?? []).flatMap((j: any) => j.steps ?? []);
  const of = (prefix: string) => steps.find((s) => String(s.name).startsWith(prefix))?.conclusion ?? (steps.some((s) => String(s.name).startsWith(prefix)) ? 'running' : undefined);
  return { state: run.status === 'completed' ? 'done' : 'running', backend: of('Backend'), customer: of('Customer App'), agent: of('Agent App'), url: run.html_url };
}
/** Backend and Customer must both have passed; the Agent App's two known end-to-end failures are the accepted baseline. */
export const ciGreen = (c: Ci) => c.state === 'done' && c.backend === 'success' && c.customer === 'success';

// ------------------------------------------------------------------ the AI engine (Claude)

async function ai(system: string, user: string, maxTokens = 900): Promise<string> {
  const key = Deno.env.get('ANTHROPIC_API_KEY');
  if (!key) throw new Error('ANTHROPIC_API_KEY not set');
  const res = await fetch(`${AI_BASE}/v1/messages`, {
    method: 'POST',
    headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: MODEL, max_tokens: maxTokens, system, messages: [{ role: 'user', content: user }] }),
    signal: AbortSignal.timeout(40_000),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`AI ${res.status}`);
  return String(data?.content?.[0]?.text ?? '');
}

export type Plan = { intent: 'task' | 'question' | 'chat'; title: string; clarify: string | null; risk: 'low' | 'medium' | 'high'; answer: string | null };

/** Anything that touches money, data, access or the release is HIGH: it waits for the owner's approval before the agent starts. */
const HIGH_RISK = /wallet|ledger|balance|deposit|withdraw|payout|payment|commission|fee|migration|database|schema|rls|policy|auth|login|password|secret|token|key|permission|delete|drop|truncate|deploy|production|backup|restore|server|webhook|cron/i;
export function riskOf(request: string, aiRisk: string | undefined): 'low' | 'medium' | 'high' {
  if (HIGH_RISK.test(request)) return 'high';
  return aiRisk === 'low' || aiRisk === 'high' ? aiRisk : 'medium';
}

export function parsePlan(text: string, fallbackTitle: string): Plan | null {
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return null;
  try {
    const j = JSON.parse(m[0]);
    const intent = ['task', 'question', 'chat'].includes(j.intent) ? j.intent : null;
    if (!intent) return null;
    return {
      intent, title: clip(String(j.title || fallbackTitle), 120), clarify: j.clarify ? clip(String(j.clarify), 600) : null,
      risk: ['low', 'medium', 'high'].includes(j.risk) ? j.risk : 'medium', answer: j.answer ? clip(String(j.answer), 1500) : null,
    };
  } catch {
    return null;
  }
}

const PLAN_SYSTEM = `You are the planner of the BADAL EXCHANGE AI Developer: the owner writes to you on Telegram in Somali or English.
BADAL EXCHANGE: Customer App and Agent App (Flutter), Supabase backend (Postgres functions, Edge Functions), payments (EVC Plus, eDahab, Sahal, CashdeskBot), wallets, Telegram bots.
Decide what the message is and answer with ONE JSON object only:
{"intent":"task"|"question"|"chat","title":"short task title","clarify":null or ONE question,"risk":"low"|"medium"|"high","answer":null or the answer}
- "task": the owner wants something built, changed, fixed, investigated or improved in the platform. Set "clarify" to ONE short question ONLY if a business decision or an essential requirement is missing; otherwise null (do not ask what you can find in the code).
- "question": a question you can answer from the project memory below or general knowledge; put the answer in "answer" (in the owner's language, short).
- "chat": a greeting or thanks; put a short reply in "answer".
Risk: "high" when it touches money, wallets, deposits, withdrawals, commissions, the database schema, security, secrets, deployment or production; "low" for text, design or documentation only; otherwise "medium".
Never include secrets. No text outside the JSON.`;

async function plan(text: string): Promise<Plan | null> {
  const memory = await rpc('dev_memory_context').catch(() => '');
  const out = await ai(`${PLAN_SYSTEM}\n\nProject memory:\n${clip(memory, 3500)}`, text.slice(0, 4000), 700);
  return parsePlan(out, clip(text.split('\n')[0], 80));
}

// ------------------------------------------------------------------ texts (Somali / English)

type Lang = 'so' | 'en';
const T = {
  denied: (l: Lang) => l === 'so' ? '⛔ Fasax kuma lihid Developer Bot-kan. Maamulaha (Owner) ayaa kuu ogolaan kara.' : '⛔ You are not authorized to use this Developer Bot. Ask the owner.',
  welcomeOwner: (l: Lang, name: string) => l === 'so'
    ? `✅ Ku soo dhawoow <b>${esc(name)}</b>: adigaa ah <b>Owner-ka</b> BADAL EXCHANGE AI Developer.\n\nIi soo dir codsi caadi ah (tusaale: "Hagaaji ..." ama "Ku dar adeeg ...") ama qor /help.`
    : `✅ Welcome <b>${esc(name)}</b>: you are the <b>Owner</b> of the BADAL EXCHANGE AI Developer.\n\nSend me a normal request (for example "Fix ..." or "Add a service ...") or type /help.`,
  welcome: (l: Lang) => l === 'so' ? '👋 BADAL EXCHANGE AI Developer waa diyaar. Ii soo dir codsi ama qor /help.' : '👋 The BADAL EXCHANGE AI Developer is ready. Send a request or type /help.',
  help: (l: Lang) => l === 'so'
    ? `<b>BADAL EXCHANGE AI Developer</b>\nQor codsi caadi ah, ama:\n/status – xaaladda shaqada\n/projects – mashruucyada\n/tasks – shaqooyinka socda\n/task N – faahfaahin shaqo\n/cancel N – jooji shaqo\n/health – caafimaadka nidaamka\n/logs – diiwaanno\n/tests – natiijooyinka tijaabada\n/deploy – diyaari deployment (waxay u baahan tahay oggolaanshahaaga)\n/memory [erey] – xusuusta mashruuca\n/authorize ID, /revoke ID – (Owner) ogolow ama jooji qof\n/help – caawimaad`
    : `<b>BADAL EXCHANGE AI Developer</b>\nWrite a normal request, or:\n/status – task status\n/projects – projects\n/tasks – running tasks\n/task N – task details\n/cancel N – stop a task\n/health – system health\n/logs – logs\n/tests – test results\n/deploy – prepare a deployment (needs your approval)\n/memory [word] – project memory\n/authorize ID, /revoke ID – (Owner) allow or remove a person\n/help – help`,
  textOnly: (l: Lang) => l === 'so' ? 'Fadlan qor qoraal (text) kaliya.' : 'Please send text only.',
  aiDown: (l: Lang) => l === 'so' ? '⚠️ AI engine-ka hadda ma jawaabayo. Isticmaal <code>/task qoraalka codsigaaga</code> si aan u bilaabo si toos ah.' : '⚠️ The AI engine is not answering right now. Use <code>/task your request</code> to start it directly.',
  limited: (l: Lang) => l === 'so' ? '⚠️ Xaddiga 10 shaqo/24 saac waa la gaadhay. Isku day marka dambe.' : '⚠️ The limit of 10 tasks per 24 hours is reached. Try again later.',
  started: (l: Lang, n: number, title: string, risk: string) => l === 'so'
    ? `🚀 <b>Shaqo #${n} waa bilaabatay</b>\n${esc(title)}\nKhatarta: <b>${risk}</b>\nWaxaan baarayaa koodka, kadibna waan qorayaa, tijaabinayaa, oo PR ayaan furayaa. Waan ku ogeysiinayaa horumarka.`
    : `🚀 <b>Task #${n} started</b>\n${esc(title)}\nRisk: <b>${risk}</b>\nI will inspect the code, write it, test it and open a PR. I will keep you posted.`,
  queued: (l: Lang, n: number) => l === 'so' ? `🕒 Shaqo #${n} way sugaysaa: mid kale ayaa socda. Waxay bilaaban doontaa marka ay dhammaato.` : `🕒 Task #${n} is queued: another one is running. It starts when that one ends.`,
  approvalTask: (l: Lang, n: number, title: string) => l === 'so'
    ? `🔐 <b>Shaqo #${n} waxay taabanaysaa wax xasaasi ah</b> (lacag, database, amni ama deployment).\n${esc(title)}\n\nWaxaan bilaabi doonaa kaliya marka aad oggolaato. Wakiilku wuxuu furi doonaa <b>PR</b> keliya: ma dhex gelayo, ma deploy-gareynayo.`
    : `🔐 <b>Task #${n} touches something sensitive</b> (money, database, security or release).\n${esc(title)}\n\nI start only if you approve. The agent will open a <b>PR</b> only: it never merges or deploys.`,
  cancelled: (l: Lang, n: number) => l === 'so' ? `✖ Shaqo #${n} waa la joojiyay.` : `✖ Task #${n} was cancelled.`,
  btnYes: (l: Lang) => l === 'so' ? '✅ Haa, bilow' : '✅ Yes, start',
  btnNo: (l: Lang) => l === 'so' ? '✖ Maya' : '✖ No',
};

// ------------------------------------------------------------------ the queue: start the next task

async function startNext(): Promise<void> {
  const t = await rpc('dev_task_claim_next');
  if (!t) return;
  try {
    const context = await rpc('dev_memory_context').catch(() => '');
    await dispatchWorkflow('dev-agent.yml', BASE_BRANCH(), {
      task_id: t.id, number: String(t.number), title: clip(t.title, 150), request: clip(t.request, 7000), risk: t.risk, context: clip(context, 9000), base: BASE_BRANCH(),
    });
    await audit(t.requested_by, 'agent_dispatched', `#${t.number}`, true, { risk: t.risk });
    await say(t.chat_id, T.started('so', t.number, t.title, t.risk));
  } catch (err) {
    await rpc('dev_task_set', { p_id: t.id, p_status: 'failed', p_fields: { summary: `Could not start the agent: ${safe(err)}`.slice(0, 500) } });
    await audit(t.requested_by, 'agent_dispatch_failed', `#${t.number}`, false, { error: safe(err).slice(0, 200) });
    await say(t.chat_id, `❌ Shaqo #${t.number}: wakiilka lama bilaabi karin / the agent could not be started.\n<code>${esc(safe(err).slice(0, 300))}</code>`);
    await startNext();
  }
}

// ------------------------------------------------------------------ messages

const shortAt = (d: unknown) => (d ? new Date(String(d)).toISOString().slice(5, 16).replace('T', ' ') : '—');
const STATUS_ICON: Record<string, string> = { clarify: '❓', awaiting_approval: '🔐', queued: '🕒', running: '⚙️', review: '👀', done: '✅', failed: '❌', cancelled: '✖' };
const taskLine = (t: any) => `${STATUS_ICON[t.status] ?? '•'} #${t.number} ${esc(clip(t.title, 60))} <i>(${t.status}${t.pr_url ? `, <a href="${esc(t.pr_url)}">PR</a>` : ''})</i>`;

async function onText(chat: number, from: any, text: string, auth: any) {
  const lang = languageOf(text);
  const [rawCmd, ...rest] = text.trim().split(/\s+/);
  const cmd = rawCmd.toLowerCase().replace(/@.*$/, '');
  const arg = rest.join(' ').trim();

  switch (cmd) {
    case '/start': return void (await say(chat, T.welcome(lang)));
    case '/help': return void (await say(chat, T.help(lang)));

    case '/status': {
      const [s, list] = await Promise.all([rpc('dev_system_summary'), rpc('dev_task_list', { p_limit: 5, p_open_only: false })]);
      const lines = [`<b>Status</b>`, `⚙️ running ${s.running} · 🕒 queued ${s.queued}`,
        s.open.length ? `🩺 ${s.open.length} problem(s): ${s.open.slice(0, 3).map((i: any) => esc(clip(i.title, 40))).join('; ')}` : '🩺 system healthy',
        '', ...(list as any[]).map(taskLine)];
      return void (await say(chat, lines.join('\n')));
    }
    case '/tasks': {
      const list = await rpc('dev_task_list', { p_limit: 15, p_open_only: arg !== 'all' });
      return void (await say(chat, (list as any[]).length ? (list as any[]).map(taskLine).join('\n') : (lang === 'so' ? 'Shaqo furan ma jirto.' : 'No open tasks.')));
    }
    case '/task': {
      if (!arg) return void (await say(chat, lang === 'so' ? 'Isticmaal /task N (lambar) ama /task qoraalka codsiga.' : 'Use /task N (a number) or /task your request.'));
      if (/^\d{1,9}$/.test(arg)) {
        const t = await rpc('dev_task_get', { p_ref: arg });
        if (!t) return void (await say(chat, '—'));
        return void (await say(chat, [taskLine(t), `Risk: ${t.risk} · ${shortAt(t.created_at)}`, t.branch ? `Branch: <code>${esc(t.branch)}</code>` : '', t.summary ? `\n${esc(clip(t.summary, 1200))}` : '',
          '\n' + (t.events as any[]).slice(0, 6).map((e) => `• ${shortAt(e.at)} ${esc(clip(e.message, 100))}`).join('\n')].filter(Boolean).join('\n')));
      }
      return void (await createFromRequest(chat, from, arg, lang, null));
    }
    case '/cancel': {
      const t = await rpc('dev_task_get', { p_ref: arg });
      if (!t) return void (await say(chat, '—'));
      const r = await rpc('dev_task_set', { p_id: t.id, p_status: 'cancelled', p_fields: {} });
      await audit(from.id, 'task_cancel', `#${t.number}`, !r?.refused);
      return void (await say(chat, r?.refused ? (lang === 'so' ? `Shaqo #${t.number} lama joojin karo (${t.status}).` : `Task #${t.number} can not be cancelled (${t.status}).`) : T.cancelled(lang, t.number)));
    }
    case '/projects': {
      let ci = '';
      try {
        const sha = (await gh(`/commits/${encodeURIComponent(BASE_BRANCH())}`))?.sha;
        const c = sha ? await ciOf(sha) : { state: 'none' as const };
        ci = c.state === 'none' ? 'no test run yet' : `Backend ${c.backend ?? '—'}, Customer ${c.customer ?? '—'}, Agent ${c.agent ?? '—'}`;
      } catch (err) {
        ci = `GitHub: ${safe(err).slice(0, 80)}`;
      }
      return void (await say(chat, [`<b>BADAL EXCHANGE</b> <code>${esc(REPO)}</code> (base <code>${esc(BASE_BRANCH())}</code>)`,
        '📱 customer-app (Flutter)', '🧑‍💼 agent-app (Flutter): Dashboard, wallets, Sahal, bots', '🗄 supabase: migrations (Postgres), functions (Edge)',
        '💳 payments: EVC Plus, eDahab, Sahal feed + SMS 898, CashdeskBot', '🤖 bots: support, cashier, alerts, developer', `🧪 CI: ${esc(ci)}`].join('\n')));
    }
    case '/health': {
      const s = await rpc('dev_system_summary');
      const lines = ['<b>Health</b>', s.lastScan ? `last scan ${shortAt(s.lastScan.at)} · ${s.lastScan.checks} checks` : 'no scan yet',
        `DB: ${s.database.connections}/${s.database.max} connections · ${esc(s.database.size)}`,
        ...(s.open.length ? (s.open as any[]).slice(0, 8).map((i) => `${i.severity === 'critical' ? '🚨' : '⚠️'} ${esc(clip(i.title, 80))}${i.financial ? ' 💰' : ''}${i.developer ? ' 🧑‍💻' : ''}`) : ['✅ no open problems']),
        '', 'ℹ️ Production runs on Supabase (managed): CPU/RAM/disk/PM2/Caddy are Supabase\'s; the monitor watches everything above that.'];
      return void (await say(chat, lines.join('\n')));
    }
    case '/logs': {
      const l = await rpc('dev_logs', { p_limit: 12 });
      const out = ['<b>Logs</b>', ...(l.events as any[]).map((e) => `${shortAt(e.at)} #${e.task} ${esc(e.kind)}: ${esc(clip(e.message, 90))}`), '', '<b>Audit</b>',
        ...(l.audit as any[]).map((a) => `${shortAt(a.at)} ${a.ok ? '✓' : '✗'} ${esc(a.action)} ${esc(a.target)}`), '', '<b>Incidents</b>',
        ...(l.incidents as any[]).map((i) => `${shortAt(i.last_seen)} ${i.status} ${esc(i.key)}`)];
      return void (await say(chat, out.join('\n')));
    }
    case '/tests': {
      const runs = await gh(`/actions/workflows/supabase-test.yml/runs?per_page=4`);
      const lines = ['<b>Tests</b>'];
      for (const r of (runs?.workflow_runs ?? []) as any[]) {
        const c = await ciOf(r.head_sha).catch(() => ({ state: 'none' } as Ci));
        lines.push(`${r.status === 'completed' ? (c.backend === 'success' && c.customer === 'success' ? '✅' : '❌') : '⏳'} <code>${esc(String(r.head_sha).slice(0, 7))}</code> ${esc(clip(r.head_branch, 30))} · Backend ${c.backend ?? '—'} · Customer ${c.customer ?? '—'} · Agent ${c.agent ?? '—'}`);
      }
      lines.push('', 'Agent App: 2 known failing e2e tests (payments_e2e) are the accepted baseline.');
      return void (await say(chat, lines.join('\n')));
    }
    case '/memory': {
      const m = await rpc('dev_memory_search', { p_query: arg || null, p_limit: 8 });
      return void (await say(chat, (m as any[]).length ? (m as any[]).map((x) => `${x.pinned ? '📌' : '•'} <b>${esc(x.kind)}</b> ${esc(x.title)}\n${esc(clip(x.body, 220))}`).join('\n\n') : '—'));
    }
    case '/authorize':
    case '/revoke': {
      const id = Number(arg.split(/\s+/)[0]);
      if (!Number.isSafeInteger(id) || id <= 0) return void (await say(chat, lang === 'so' ? 'Isticmaal /authorize TELEGRAM_ID' : 'Use /authorize TELEGRAM_ID'));
      const r = await rpc('dev_user_set', { p_actor: from.id, p_tg: id, p_name: arg.split(/\s+/).slice(1).join(' ') || null, p_grant: cmd === '/authorize' });
      const msg: Record<string, string> = {
        ok: '✅ OK', not_owner: '⛔ Owner only', not_admin: lang === 'so' ? '⛔ Qofkaas waa inuu noqdaa maamule (admin ama agent leh manage_settings) Telegram-kiisa ku xiray Agent App.' : '⛔ That person must be a platform manager (an administrator, or an agent with the settings responsibility) with Telegram linked in the Agent App.', self: '—',
      };
      return void (await say(chat, msg[r] ?? r));
    }
    case '/deploy': return void (await deployPrepare(chat, from, auth, lang));
    default:
      break;
  }
  if (rawCmd.startsWith('/')) return void (await say(chat, T.help(lang)));
  return void (await onRequest(chat, from, text, lang));
}

/** An ordinary message: answer a question, ask the one missing thing, or create a task. */
async function onRequest(chat: number, from: any, text: string, lang: Lang) {
  const open = await rpc('dev_task_open_clarify', { p_chat: chat });
  let p: Plan | null;
  try {
    p = await plan(open ? `${open.request}\n\nAnswer from the owner: ${text}` : text);
  } catch (err) {
    console.error('dev-bot plan', safe(err));
    return void (await say(chat, T.aiDown(lang)));
  }
  if (!p) return void (await say(chat, T.aiDown(lang)));
  if (p.intent !== 'task') return void (await say(chat, esc(p.answer ?? (lang === 'so' ? 'Waan ku caawin karaa: ii sheeg waxa la sameeyo.' : 'Tell me what to build or fix.'))));
  if (open) {
    const risk = riskOf(`${open.request} ${text}`, p.risk);
    const status = p.clarify ? 'clarify' : risk === 'high' ? 'awaiting_approval' : 'queued';
    const t = await rpc('dev_task_refine', { p_id: open.id, p_more: text, p_title: p.title, p_risk: risk, p_status: status });
    if (!t) return void (await createFromRequest(chat, from, text, lang, p));
    return void (await afterCreate(chat, from, t, p.clarify, lang));
  }
  return void (await createFromRequest(chat, from, text, lang, p));
}

async function createFromRequest(chat: number, from: any, text: string, lang: Lang, p: Plan | null) {
  const risk = riskOf(text, p?.risk);
  const status = p?.clarify ? 'clarify' : risk === 'high' ? 'awaiting_approval' : 'queued';
  const t = await rpc('dev_task_create', { p_actor: from.id, p_chat: chat, p_title: p?.title ?? clip(text.split('\n')[0], 100), p_request: text, p_risk: risk, p_status: status });
  if (t.limited) return void (await say(chat, T.limited(lang)));
  await audit(from.id, 'task_created', `#${t.number}`, true, { risk, status });
  return void (await afterCreate(chat, from, t, p?.clarify ?? null, lang));
}

async function afterCreate(chat: number, from: any, t: any, clarify: string | null, lang: Lang) {
  if (t.status === 'clarify') return void (await say(chat, `❓ <b>#${t.number}</b> ${esc(clarify ?? '')}`));
  if (t.status === 'awaiting_approval') {
    const id = await rpc('dev_pending_create', { p_kind: 'task', p_actor: from.id, p_payload: { taskId: t.id, number: t.number } });
    return void (await say(chat, T.approvalTask(lang, t.number, t.title), {
      reply_markup: { inline_keyboard: [[{ text: T.btnYes(lang), callback_data: `tk:${id}:ok` }, { text: T.btnNo(lang), callback_data: `tk:${id}:no` }]] },
    }));
  }
  const running = (await rpc('dev_system_summary')).running;
  await startNext();
  if (running > 0) await say(chat, T.queued(lang, t.number));
}

// ------------------------------------------------------------------ deployment: checks, backup, approvals

async function deployPrepare(chat: number, from: any, auth: any, lang: Lang) {
  if (auth.role !== 'owner') return void (await say(chat, lang === 'so' ? '⛔ Owner-ka oo keliya ayaa deploy-gareyn kara.' : '⛔ Only the owner can deploy.'));
  const ref = DEPLOY_REF();
  const sha = (await gh(`/commits/${encodeURIComponent(ref)}`))?.sha as string | undefined;
  if (!sha) return void (await say(chat, '⚠️ GitHub: no commit.'));
  const ci = await ciOf(sha);
  const health = await rpc('dev_system_summary');
  const critical = (health.open as any[]).filter((i) => i.severity === 'critical');
  const lines = [`🚀 <b>Deploy</b> <code>${esc(ref)}</code> @ <code>${sha.slice(0, 7)}</code>`,
    `Tests: Backend ${ci.backend ?? '—'} · Customer ${ci.customer ?? '—'} · Agent ${ci.agent ?? '—'}${ci.url ? ` (<a href="${esc(ci.url)}">run</a>)` : ''}`,
    critical.length ? `🚨 ${critical.length} critical problem(s) are open now: ${esc(critical.map((i) => clip(i.title, 40)).join('; '))}` : '🩺 no critical problem open'];
  if (!ciGreen(ci)) {
    lines.push('', ci.state === 'running' ? '⏳ Tests are still running: not ready.' : '⛔ Backend and Customer tests must both be green for this commit: not ready.');
    return void (await say(chat, lines.join('\n')));
  }
  const id = await rpc('dev_pending_create', { p_kind: 'deploy', p_actor: from.id, p_payload: { sha, ref } });
  lines.push('', lang === 'so' ? 'Marka aad oggolaato: marka hore <b>backup</b> ayaa la sameeyaa oo la hubiyaa, kadibna waxaan ku weydiinayaa mar kale.' : 'When you approve: a <b>backup</b> is made and verified first, then I ask you once more.');
  await say(chat, lines.join('\n'), { reply_markup: { inline_keyboard: [[{ text: '✅ Backup → Deploy', callback_data: `dp:${id}:ok` }, { text: T.btnNo(lang), callback_data: `dp:${id}:no` }]] } });
}

async function onCallback(q: any) {
  const chat = q.message?.chat?.id as number;
  const from = q.from;
  const ack = (text: string) => tg('answerCallbackQuery', { callback_query_id: q.id, text: clip(text, 180) }).catch(() => null);
  const auth = await rpc('dev_auth', { p_tg: from.id });
  if (!auth.authorized) { await audit(from.id, 'callback_denied', null, false); return void (await ack('⛔')); }
  const [kindCode, id, choice] = String(q.data ?? '').split(':');
  const editText = (text: string) => tg('editMessageText', { chat_id: chat, message_id: q.message.message_id, text: clip(text, 3900), parse_mode: 'HTML' }).catch(() => null);
  if (!id || !['tk', 'dp', 'dg', 'dn'].includes(kindCode)) return;
  if (choice === 'no') { await ack('✖'); return void (await editText('✖ Cancelled')); }
  if (choice !== 'ok') return;

  const taken = await rpc('dev_pending_take', { p_id: id, p_actor: from.id });
  if (taken.refused) { await ack(taken.refused === 'not_owner' ? '⛔ Owner only' : 'Already handled or expired'); return; }
  const payload = taken.payload as any;

  if (taken.kind === 'task') {
    const r = await rpc('dev_task_set', { p_id: payload.taskId, p_status: 'queued', p_fields: {} });
    await ack('✅');
    await editText(`✅ #${payload.number} approved: queued.`);
    if (!r?.refused) await startNext();
    return;
  }
  if (taken.kind === 'deploy' || taken.kind === 'deploy_nobackup') {
    if (taken.kind === 'deploy') {
      // Step 1: a backup (with its restore test) first.
      const since = new Date().toISOString();
      await dispatchWorkflow('backup.yml', DEPLOY_REF(), {});
      const track = await rpc('dev_pending_create', { p_kind: 'backup', p_actor: from.id, p_payload: { since, sha: payload.sha, ref: payload.ref, chat } });
      await rpc('dev_pending_take', { p_id: track, p_actor: from.id });
      await audit(from.id, 'backup_started', payload.sha, true, { ref: payload.ref });
      await ack('✅');
      return void (await editText('💾 Backup + restore test started. I will ask you again when it passed.'));
    }
    return void (await finishDeploy(chat, from.id, payload, ack, editText, true));
  }
  if (taken.kind === 'deploy_go') return void (await finishDeploy(chat, from.id, payload, ack, editText, false));
}

/** The last approval: runs the deployment workflow for the commit that was checked (never a newer one). */
async function finishDeploy(chat: number, actor: number, payload: any, ack: (t: string) => Promise<unknown>, editText: (t: string) => Promise<unknown>, withoutBackup: boolean) {
  const head = (await gh(`/commits/${encodeURIComponent(payload.ref)}`))?.sha as string;
  if (head !== payload.sha) {
    await ack('⚠️');
    return void (await editText(`⚠️ <code>${esc(payload.ref)}</code> moved (${esc(String(payload.sha).slice(0, 7))} → ${esc(String(head).slice(0, 7))}): run /deploy again.`));
  }
  await dispatchWorkflow('supabase-deploy.yml', payload.ref, { mode: 'deploy' });
  await audit(actor, withoutBackup ? 'deploy_without_backup' : 'deploy', payload.sha, true, { ref: payload.ref });
  await rpc('dev_memory_add', { p_kind: 'deploy', p_title: `Deploy ${String(payload.sha).slice(0, 7)}`, p_body: `Deployed ${payload.ref} @ ${payload.sha} at ${new Date().toISOString()}${withoutBackup ? ' WITHOUT a fresh backup (owner approved)' : ' after a verified backup'}.`, p_pinned: false, p_task: null });
  await ack('✅');
  await editText(`🚀 Deployment started for <code>${esc(String(payload.sha).slice(0, 7))}</code>. Check /health in a few minutes.`);
}

// ------------------------------------------------------------------ the webhook

async function onMessage(m: any) {
  const chat: number = m.chat?.id;
  if (!chat || m.chat?.type !== 'private' || !m.from) return;
  const from = m.from;
  const auth = await rpc('dev_auth', { p_tg: from.id });
  const text = typeof m.text === 'string' ? m.text.trim() : '';
  const lang = languageOf(text || 'waa');

  if (!auth.authorized) {
    if (/^\/start(\s|$)/.test(text) && auth.ownerExists === false) {
      const name = [from.first_name, from.last_name].filter(Boolean).join(' ') || from.username || String(from.id);
      if (await rpc('dev_claim_owner', { p_tg: from.id, p_name: name })) return void (await say(chat, T.welcomeOwner(lang, name)));
    }
    await audit(from.id, 'denied', null, false, { reason: auth.reason });
    return void (await say(chat, T.denied(lang)));
  }
  if (!text) return void (await say(chat, T.textOnly(lang)));
  await onText(chat, from, text, auth);
}

// ------------------------------------------------------------------ report from the coding agent

type Report = { taskId: string; event: 'progress' | 'done' | 'failed' | 'noop'; message?: string; branch?: string; prUrl?: string; prNumber?: number; summary?: string; risk?: string; files?: string[]; tests?: string };

async function onReport(r: Report) {
  const t = await rpc('dev_task_get', { p_ref: String(r.taskId) });
  if (!t) return json({ ok: false, error: 'unknown task' }, 404);
  const chat = t.chat_id as number;
  const msg = clip(r.message ?? '', 500);
  // Only a running task takes reports: a result is accepted once, a late or repeated report changes nothing.
  if (t.status !== 'running') return json({ ok: false, error: `task is ${t.status}` }, 409);
  if (r.event === 'progress') {
    await rpc('dev_task_event', { p_id: t.id, p_kind: 'progress', p_message: msg || 'progress', p_detail: {} });
    if (r.branch) await rpc('dev_task_set', { p_id: t.id, p_status: 'running', p_fields: { branch: r.branch } });
    if (msg) await say(chat, `⚙️ #${t.number} ${esc(msg)}`);
    return json({ ok: true });
  }
  if (r.event === 'done') {
    const files = (r.files ?? []).slice(0, 60);
    const risk = r.risk === 'high' ? 'high' : t.risk;
    const set = await rpc('dev_task_set', { p_id: t.id, p_status: 'review', p_fields: { branch: r.branch, prUrl: r.prUrl, prNumber: r.prNumber, summary: r.summary, risk, result: { files, tests: r.tests } } });
    if (set?.refused) return json({ ok: false, error: 'task is not running' }, 409);
    await rpc('dev_task_event', { p_id: t.id, p_kind: 'done', p_message: `PR ${r.prUrl ?? ''}`, p_detail: { files: files.length } });
    await rpc('dev_memory_add', { p_kind: 'feature', p_title: clip(`#${t.number} ${t.title}`, 190), p_body: `${clip(r.summary ?? '', 1500)}\nPR: ${r.prUrl ?? ''}\nFiles: ${files.slice(0, 15).join(', ')}`, p_pinned: false, p_task: t.id });
    await say(chat, [`✅ <b>Task #${t.number}: PR is ready</b>`, esc(t.title), r.prUrl ? `<a href="${esc(r.prUrl)}">${esc(r.prUrl)}</a>` : '', `Risk: <b>${risk}</b> · ${files.length} file(s)`,
      r.tests ? `Agent checks: ${esc(clip(r.tests, 300))}` : '', r.summary ? `\n${esc(clip(r.summary, 1200))}` : '',
      '\n⏳ The full test run (Backend, Customer, Agent) is running on the PR: I will tell you the result. Nothing is merged or deployed: you review and approve.'].filter(Boolean).join('\n'));
  } else {
    await rpc('dev_task_set', { p_id: t.id, p_status: 'failed', p_fields: { summary: clip(r.summary ?? r.message ?? 'failed', 1500) } });
    await rpc('dev_task_event', { p_id: t.id, p_kind: r.event, p_message: msg || r.event });
    await rpc('dev_memory_add', { p_kind: 'note', p_title: clip(`#${t.number} did not finish: ${t.title}`, 190), p_body: clip(r.summary ?? r.message ?? '', 1500), p_pinned: false, p_task: t.id });
    await say(chat, `${r.event === 'noop' ? 'ℹ️' : '❌'} <b>Task #${t.number}</b> ${r.event === 'noop' ? 'made no change' : 'failed'}\n${esc(clip(r.summary ?? r.message ?? '', 1200))}`);
  }
  await startNext();
  return json({ ok: true });
}

// ------------------------------------------------------------------ the tick

async function tick() {
  const out: Record<string, unknown> = {};
  const stale = (await rpc('dev_task_expire_stale')) as any[];
  for (const s of stale) await say(s.chat_id, `⏱ <b>Task #${s.number}</b> stopped: no news from the agent for 90 minutes.\n${esc(s.title)}`).catch(() => null);
  out.stale = stale.length;
  await startNext();

  // The PR's tests: told once, when they finished.
  const reviews = (await rpc('dev_task_list', { p_limit: 20, p_open_only: true }) as any[]).filter((t) => t.status === 'review' && t.pr_number);
  for (const t of reviews) {
    try {
      const full = await rpc('dev_task_get', { p_ref: String(t.number) });
      if (full.ci_reported) continue;
      const pr = await gh(`/pulls/${t.pr_number}`);
      const c = await ciOf(pr.head.sha);
      if (c.state !== 'done') continue;
      await rpc('dev_task_set', { p_id: t.id, p_status: 'review', p_fields: { ciReported: true } });
      await say(t.chat_id, `${ciGreen(c) ? '✅' : '❌'} <b>Task #${t.number}</b> tests: Backend ${c.backend ?? '—'} · Customer ${c.customer ?? '—'} · Agent ${c.agent ?? '—'}${c.url ? ` (<a href="${esc(c.url)}">run</a>)` : ''}\n${ciGreen(c) ? 'Review the PR and merge it if you are happy; then /deploy.' : 'The PR is not ready: I can fix it if you tell me what to do (/task N).'}`);
    } catch (err) {
      console.error('dev-bot ci', safe(err));
    }
  }

  // A backup that was started for a deployment.
  for (const b of (await rpc('dev_backup_pending')) as any[]) {
    try {
      const runs = await gh(`/actions/workflows/backup.yml/runs?event=workflow_dispatch&per_page=3`);
      const run = (runs?.workflow_runs ?? []).find((r: any) => new Date(r.created_at) >= new Date(new Date(b.payload.since).getTime() - 30_000));
      if (!run || run.status !== 'completed') continue;
      await rpc('dev_pending_mark', { p_id: b.id, p_patch: { done: true, result: run.conclusion } });
      if (run.conclusion === 'success') {
        const id = await rpc('dev_pending_create', { p_kind: 'deploy_go', p_actor: b.actor, p_payload: { sha: b.payload.sha, ref: b.payload.ref } });
        await say(b.payload.chat, `💾 ✅ Backup and restore test passed (<a href="${esc(run.html_url)}">run</a>).\nDeploy <code>${esc(String(b.payload.sha).slice(0, 7))}</code> now?`,
          { reply_markup: { inline_keyboard: [[{ text: '🚀 Deploy now', callback_data: `dp:${id}:ok` }, { text: '✖ No', callback_data: `dp:${id}:no` }]] } });
      } else {
        const id = await rpc('dev_pending_create', { p_kind: 'deploy_nobackup', p_actor: b.actor, p_payload: { sha: b.payload.sha, ref: b.payload.ref } });
        await say(b.payload.chat, `💾 ❌ The backup did not pass (${esc(run.conclusion)}, <a href="${esc(run.html_url)}">run</a>). I will NOT deploy on my own.\nIf you accept the risk you can deploy without a fresh backup:`,
          { reply_markup: { inline_keyboard: [[{ text: '⚠️ Deploy without backup', callback_data: `dn:${id}:ok` }, { text: '✖ No', callback_data: `dn:${id}:no` }]] } });
      }
    } catch (err) {
      console.error('dev-bot backup', safe(err));
    }
  }
  return out;
}

// ------------------------------------------------------------------ server

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/\/$/, '');
  const secret = Deno.env.get('DEVBOT_WEBHOOK_SECRET');

  if (path.endsWith('/setup')) {
    if (!secret || !sameString(url.searchParams.get('key') ?? req.headers.get('x-telegram-bot-api-secret-token'), secret)) return new Response('Forbidden', { status: 403 });
    try {
      await tg('setWebhook', { url: `${Deno.env.get('SUPABASE_URL')}/functions/v1/dev-bot`, secret_token: secret, allowed_updates: ['message', 'callback_query'], drop_pending_updates: true });
      await tg('setMyCommands', { commands: [
        { command: 'start', description: 'Bilow / Start' }, { command: 'status', description: 'Xaaladda shaqada / Task status' }, { command: 'projects', description: 'Mashruucyada / Projects' },
        { command: 'tasks', description: 'Shaqooyinka / Tasks' }, { command: 'health', description: 'Caafimaadka / Health' }, { command: 'logs', description: 'Diiwaanno / Logs' },
        { command: 'tests', description: 'Tijaabooyin / Tests' }, { command: 'deploy', description: 'Deployment' }, { command: 'help', description: 'Caawimaad / Help' }] });
      return json({ ok: true, message: 'Webhook was set. Send /start to the bot.' });
    } catch (err) {
      return json({ ok: false, error: safe(err) }, 500);
    }
  }

  if (path.endsWith('/report')) {
    const body = await req.text();
    const reportSecret = Deno.env.get('DEVBOT_REPORT_SECRET');
    const given = (req.headers.get('x-devbot-signature') ?? '').replace(/^sha256=/, '');
    if (req.method !== 'POST' || !reportSecret || !sameString(given, await hmacHex(reportSecret, body))) return new Response('Forbidden', { status: 403 });
    try {
      return await onReport(JSON.parse(body));
    } catch (err) {
      console.error('dev-bot report', safe(err));
      return json({ ok: false, error: safe(err) }, 500);
    }
  }

  if (path.endsWith('/tick')) {
    const worker = req.headers.get('x-worker-secret');
    if (req.method !== 'POST' || !worker || (await rpc('platform_worker_check', { p_secret: worker }).catch(() => false)) !== true) return new Response('Forbidden', { status: 403 });
    try {
      return json({ ok: true, ...(await tick()) });
    } catch (err) {
      console.error('dev-bot tick', safe(err));
      return json({ ok: false, error: safe(err) }, 500);
    }
  }

  if (req.method !== 'POST' || !sameString(req.headers.get('x-telegram-bot-api-secret-token'), secret)) return new Response('Forbidden', { status: 403 });
  try {
    const update = await req.json();
    if (update.callback_query) await onCallback(update.callback_query);
    else if (update.message) await onMessage(update.message);
  } catch (err) {
    console.error('dev-bot', safe(err));
  }
  return json({ ok: true }); // Telegram must always get 200, or it resends the update
});
