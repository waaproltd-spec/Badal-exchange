// The AI Developer Bot end to end (functions/dev-bot/index.ts) against stand-ins for Telegram, GitHub and Claude, with the
// real database functions: who may talk to it, a task from a plain message, the approval for sensitive work, the queue,
// the agent's signed report, the PR's test result, and the deployment gate (green tests -> backup -> second approval).
// The function runs in a child process (a Deno shim); no network, no real token.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { createHmac, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 6 });
const seed = Number(Date.now().toString().slice(-7));
const OWNER = 7_200_000_000 + seed;
const STRANGER = OWNER + 1;
const PORTS = { tg: 49131, gh: 49132, ai: 49133, rest: 49134, bot: 49135 };
const WEBHOOK_SECRET = 'test-devbot-webhook-secret';
const REPORT_SECRET = 'test-devbot-report-secret';

// ---------------------------------------------------------------- stand-ins
const tgCalls = [];
const ghCalls = [];
const ai = { reply: null, down: false };
const gh = { sha: 'a1b2c3d4e5f6a7b8c9d0', run: null, jobs: [], backupRun: null };

const listen = (server, port) => new Promise((r) => server.listen(port, '127.0.0.1', r));
const readBody = async (req) => { const c = []; for await (const x of req) c.push(x); return Buffer.concat(c).toString(); };

const telegram = http.createServer(async (req, res) => {
  const body = JSON.parse((await readBody(req)) || '{}');
  tgCalls.push({ method: req.url.split('/').pop(), body });
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true, result: { message_id: 1 } }));
});
const github = http.createServer(async (req, res) => {
  const body = (await readBody(req)) || '{}';
  const url = new URL(req.url, 'http://x');
  ghCalls.push({ method: req.method, path: url.pathname, query: url.search, body: JSON.parse(body) });
  const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(obj === null ? '' : JSON.stringify(obj)); };
  if (req.method === 'POST' && url.pathname.endsWith('/dispatches')) return send(204, null);
  if (url.pathname.includes('/commits/')) return send(200, { sha: gh.sha });
  if (url.pathname.endsWith('/workflows/supabase-test.yml/runs')) return send(200, { workflow_runs: gh.run ? [gh.run] : [] });
  if (url.pathname.endsWith('/workflows/backup.yml/runs')) return send(200, { workflow_runs: gh.backupRun ? [gh.backupRun] : [] });
  if (/\/actions\/runs\/\d+\/jobs$/.test(url.pathname)) return send(200, { jobs: [{ steps: gh.jobs }] });
  if (/\/pulls\/\d+$/.test(url.pathname)) return send(200, { head: { sha: gh.sha } });
  return send(404, { message: 'not found' });
});
const claude = http.createServer(async (req, res) => {
  await readBody(req);
  if (ai.down) { res.writeHead(500); return res.end('{}'); }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ content: [{ type: 'text', text: typeof ai.reply === 'string' ? ai.reply : JSON.stringify(ai.reply) }] }));
});
// PostgREST: POST /rest/v1/rpc/<function> with named arguments, as the Edge Function calls the database.
const rest = http.createServer(async (req, res) => {
  const fn = req.url.split('/').pop();
  const args = JSON.parse((await readBody(req)) || '{}');
  const keys = Object.keys(args);
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`);
    const q = await c.query(`SELECT public.${fn.replace(/[^a-z_]/g, '')}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) AS r`,
      keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k])));
    await c.query('COMMIT');
    const v = q.rows[0].r;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(v === '' || v === undefined ? '' : JSON.stringify(v));
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ message: e.message, hint: e.hint }));
  } finally {
    c.release();
  }
});

let bot;
before(async () => {
  await Promise.all([listen(telegram, PORTS.tg), listen(github, PORTS.gh), listen(claude, PORTS.ai), listen(rest, PORTS.rest)]);
  bot = spawn(process.execPath, ['--experimental-strip-types', '--no-warnings', fileURLToPath(new URL('./devbot_harness.mjs', import.meta.url))], {
    env: {
      ...process.env, HARNESS_PORT: String(PORTS.bot), SUPABASE_URL: `http://127.0.0.1:${PORTS.rest}`, SUPABASE_SERVICE_ROLE_KEY: 'sb_test_service_key',
      DEVBOT_TELEGRAM_TOKEN: '777777:TEST-devbot-not-a-real-token', DEVBOT_WEBHOOK_SECRET: WEBHOOK_SECRET, DEVBOT_REPORT_SECRET: REPORT_SECRET,
      DEVBOT_GITHUB_TOKEN: 'ghp_test_not_a_real_token', ANTHROPIC_API_KEY: 'test-not-a-real-key', DEVBOT_REPO: 'test-owner/test-repo', DEVBOT_BASE_BRANCH: 'main',
      DEVBOT_TELEGRAM_API_BASE: `http://127.0.0.1:${PORTS.tg}`, DEVBOT_GITHUB_API_BASE: `http://127.0.0.1:${PORTS.gh}`, DEVBOT_AI_API_BASE: `http://127.0.0.1:${PORTS.ai}`,
    },
  });
  await new Promise((resolve, reject) => {
    bot.stdout.on('data', (d) => String(d).includes('ready') && resolve());
    bot.stderr.on('data', (d) => process.env.DEVBOT_TEST_DEBUG && process.stderr.write(d));
    bot.on('exit', (code) => reject(new Error(`the bot process exited (${code})`)));
    setTimeout(() => reject(new Error('the bot did not start')), 15000);
  });
  await cleanup();
  // a platform administrator with a Telegram account linked, as the Agent App does it
  const admin = (await db.query(`SELECT id FROM users WHERE phone = '252610000001'`)).rows[0].id;
  await db.query(`DELETE FROM public.telegram_operators WHERE user_id = $1`, [admin]);
  await db.query(`INSERT INTO public.telegram_operators (telegram_user_id, user_id) VALUES ($1, $2)`, [OWNER, admin]);
});
after(async () => {
  bot?.removeAllListeners('exit');
  bot?.kill();
  await cleanup();
  await db.query(`DELETE FROM public.telegram_operators WHERE telegram_user_id = $1`, [OWNER]);
  await Promise.all([telegram, github, claude, rest].map((s) => new Promise((r) => s.close(r))));
  await db.end();
});
async function cleanup() {
  await db.query(`DELETE FROM public.dev_pending`);
  await db.query(`DELETE FROM public.dev_tasks`);
  await db.query(`DELETE FROM public.dev_bot_users`);
  await db.query(`DELETE FROM public.dev_audit WHERE actor IN ($1, $2)`, [OWNER, STRANGER]);
  await db.query(`DELETE FROM public.dev_memory WHERE kind IN ('feature', 'deploy', 'note')`);
}

// ---------------------------------------------------------------- helpers
const post = (path, body, headers = {}) => fetch(`http://127.0.0.1:${PORTS.bot}${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });
const update = (from, text, extra = {}) => post('/dev-bot', { update_id: 1, message: { message_id: 1, chat: { id: from, type: 'private' }, from: { id: from, first_name: 'Test' }, text, ...extra } }, { 'x-telegram-bot-api-secret-token': WEBHOOK_SECRET });
const press = (from, data) => post('/dev-bot', { update_id: 2, callback_query: { id: 'cb1', from: { id: from }, data, message: { message_id: 5, chat: { id: from, type: 'private' } } } }, { 'x-telegram-bot-api-secret-token': WEBHOOK_SECRET });
const report = (obj, secret = REPORT_SECRET) => { const body = JSON.stringify(obj); return post('/dev-bot/report', body, { 'x-devbot-signature': `sha256=${createHmac('sha256', secret).update(body).digest('hex')}` }); };
const sent = (needle) => tgCalls.filter((c) => c.method === 'sendMessage' && String(c.body.text).includes(needle));
const dispatches = (wf) => ghCalls.filter((c) => c.method === 'POST' && c.path.endsWith(`/workflows/${wf}/dispatches`));
const task = async (n) => (await db.query(`SELECT * FROM public.dev_tasks WHERE number = $1`, [n])).rows[0];
const lastButtons = () => [...tgCalls].reverse().find((c) => c.body.reply_markup)?.body.reply_markup.inline_keyboard[0].map((b) => b.callback_data);
const workerSecret = async () => (await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`)).rows[0]?.decrypted_secret;
const reset = () => { tgCalls.length = 0; ghCalls.length = 0; };

// ---------------------------------------------------------------- the scenario (one flow, in order)
let first;
let second;

test('the webhook refuses a wrong secret; a stranger gets a refusal, nothing else, and it is audited', async () => {
  assert.equal((await post('/dev-bot', { message: {} }, { 'x-telegram-bot-api-secret-token': 'nope' })).status, 403);
  assert.equal((await post('/dev-bot/report', '{}', { 'x-devbot-signature': 'sha256=00' })).status, 403);
  assert.equal((await fetch(`http://127.0.0.1:${PORTS.bot}/dev-bot/tick`, { method: 'POST', headers: { 'x-worker-secret': 'nope' } })).status, 403);
  reset();
  assert.equal((await update(STRANGER, '/start')).status, 200, 'Telegram always gets 200');
  assert.equal(sent('Fasax kuma lihid').length + sent('not authorized').length, 1);
  await update(STRANGER, 'Add a service that pays everyone');
  assert.equal(ghCalls.length, 0, 'nothing was started');
  assert.equal((await db.query(`SELECT count(*)::int AS n FROM public.dev_tasks`)).rows[0].n, 0);
  assert.ok((await db.query(`SELECT 1 FROM public.dev_audit WHERE actor = $1 AND action = 'denied' AND NOT ok`, [STRANGER])).rowCount >= 1);
});

test('the first /start of a linked platform administrator makes them the owner', async () => {
  reset();
  await update(OWNER, '/start');
  assert.equal(sent('Owner').length, 1);
  assert.equal((await db.query(`SELECT role FROM public.dev_bot_users WHERE telegram_id = $1`, [OWNER])).rows[0].role, 'owner');
  reset();
  await update(OWNER, '/help');
  assert.ok(sent('/deploy').length === 1, 'the command list');
});

test('an ordinary message becomes a task and the coding agent is started with it', async () => {
  reset();
  ai.reply = { intent: 'task', title: 'Dashboard banner colour', clarify: null, risk: 'low', answer: null };
  await update(OWNER, 'Please change the colour of the dashboard banner to green');
  first = (await db.query(`SELECT * FROM public.dev_tasks ORDER BY number LIMIT 1`)).rows[0];
  assert.ok(first, 'a task was created');
  assert.equal(first.status, 'running');
  assert.equal(first.risk, 'low');
  const d = dispatches('dev-agent.yml');
  assert.equal(d.length, 1, 'the workflow was dispatched once');
  assert.equal(d[0].body.ref, 'main');
  assert.equal(d[0].body.inputs.task_id, first.id);
  assert.match(d[0].body.inputs.request, /colour of the dashboard banner/);
  assert.ok(d[0].body.inputs.context.length > 20, 'the project memory goes with it');
  assert.equal(sent('started').length + sent('bilaabatay').length, 1);
});

test('sensitive work (money) waits for the owner: no agent until the button is pressed, and a stranger can not press it', async () => {
  reset();
  ai.reply = { intent: 'task', title: 'Faster withdrawals', clarify: null, risk: 'medium', answer: null };
  await update(OWNER, 'Improve the withdrawal speed for customers');
  second = (await db.query(`SELECT * FROM public.dev_tasks ORDER BY number DESC LIMIT 1`)).rows[0];
  assert.equal(second.status, 'awaiting_approval');
  assert.equal(second.risk, 'high', 'a word about money makes it high whatever the AI said');
  assert.equal(dispatches('dev-agent.yml').length, 0, 'not started');
  const [yes] = lastButtons();
  reset();
  await press(STRANGER, yes);
  assert.equal((await task(second.number)).status, 'awaiting_approval', 'a stranger can not approve');
  await press(OWNER, yes);
  assert.equal((await task(second.number)).status, 'queued', 'approved, but the first task still runs');
  assert.equal(dispatches('dev-agent.yml').length, 0, 'one agent at a time');
  reset();
  await press(OWNER, yes);
  assert.equal(dispatches('dev-agent.yml').length, 0, 'a second press does nothing');
});

test('the system speaks Somali: /status, /health, /projects, /logs, /tests', async () => {
  for (const [cmd, word] of [['/status', 'Xaaladda'], ['/health', 'Caafimaadka nidaamka'], ['/projects', 'Tijaabooyinka'], ['/logs', 'Diiwaanno'], ['/tests', 'Tijaabooyin']]) {
    reset();
    await update(OWNER, cmd);
    const out = tgCalls.filter((c) => c.method === 'sendMessage').map((c) => String(c.body.text)).join('\n');
    assert.ok(out.includes(word), `${cmd} answers in Somali ("${word}")`);
    assert.ok(!/(Health<|<b>Status|no open problems|connections)/.test(out), `${cmd} has no English labels`);
  }
});

test('a question is answered from memory; no task is made', async () => {
  reset();
  const before = (await db.query(`SELECT count(*)::int AS n FROM public.dev_tasks`)).rows[0].n;
  ai.reply = { intent: 'question', title: '', clarify: null, risk: 'low', answer: 'Production runs on Supabase.' };
  await update(OWNER, 'What does production run on?');
  assert.equal(sent('Supabase').length, 1);
  assert.equal((await db.query(`SELECT count(*)::int AS n FROM public.dev_tasks`)).rows[0].n, before);
});

test('when the AI engine is down the owner is told how to go on (/task)', async () => {
  reset();
  ai.down = true;
  await update(OWNER, 'Add a new service');
  ai.down = false;
  assert.equal(sent('/task').length, 1);
});

test("the agent's report must be signed; a signed 'done' makes the task reviewable, remembers it and starts the next one", async () => {
  reset();
  const pr = { taskId: first.id, event: 'done', branch: `devbot/${first.number}-x`, prUrl: 'https://github.com/test-owner/test-repo/pull/9', prNumber: 9, summary: 'Changed the banner colour.', risk: 'low', files: ['agent-app/lib/a.dart'], tests: 'Tests: flutter analyze ok' };
  assert.equal((await report(pr, 'wrong-secret')).status, 403, 'a wrong signature is refused');
  assert.equal((await task(first.number)).status, 'running');
  assert.equal((await report(pr)).status, 200);
  const t = await task(first.number);
  assert.equal(t.status, 'review');
  assert.equal(t.pr_number, 9);
  assert.equal(sent('pull/9').length, 1, 'the owner gets the PR link');
  assert.ok((await db.query(`SELECT 1 FROM public.dev_memory WHERE kind = 'feature' AND title LIKE $1`, [`#${first.number} %`])).rowCount === 1, 'the feature is remembered');
  assert.equal((await task(second.number)).status, 'running', 'the next task started');
  assert.equal(dispatches('dev-agent.yml').length, 1);
  assert.equal((await report(pr)).status, 409, 'a result can be reported once');
  assert.equal((await report({ taskId: second.id, event: 'failed', message: 'x', summary: 'it did not work' })).status, 200);
  assert.equal((await task(second.number)).status, 'failed');
  assert.equal(sent('fashilmay').length, 1);
});

test('the tick tells the owner the PR\'s test result once', async () => {
  const secret = await workerSecret();
  if (!secret) return;
  reset();
  gh.run = { id: 1, status: 'completed', html_url: 'https://github.com/x/actions/runs/1' };
  gh.jobs = [{ name: 'Backend tests (Auth, RPC, RLS, Realtime)', conclusion: 'success' }, { name: 'Customer App against Supabase', conclusion: 'success' }, { name: 'Agent App against Supabase', conclusion: 'failure' }];
  const tick = () => fetch(`http://127.0.0.1:${PORTS.bot}/dev-bot/tick`, { method: 'POST', headers: { 'x-worker-secret': secret } });
  assert.equal((await tick()).status, 200);
  assert.equal(sent('tijaabooyin: Backend success').length, 1);
  reset();
  await tick();
  assert.equal(sent('tijaabooyin: Backend').length, 0, 'told once');
});

test('/deploy: not ready until Backend and Customer are green; then a backup first, a second approval after it, owner only, the commit that was checked', async () => {
  const secret = await workerSecret();
  if (!secret) return;
  const tick = () => fetch(`http://127.0.0.1:${PORTS.bot}/dev-bot/tick`, { method: 'POST', headers: { 'x-worker-secret': secret } });
  // red: no button
  gh.run = { id: 2, status: 'completed', html_url: 'https://github.com/x/actions/runs/2' };
  gh.jobs = [{ name: 'Backend tests (Auth, RPC, RLS, Realtime)', conclusion: 'failure' }, { name: 'Customer App against Supabase', conclusion: 'success' }];
  reset();
  await update(OWNER, '/deploy');
  assert.equal(sent('ma diyaar ahan').length, 1);
  assert.equal(lastButtons(), undefined, 'no button while a test is red');
  // green
  gh.jobs = [{ name: 'Backend tests (Auth, RPC, RLS, Realtime)', conclusion: 'success' }, { name: 'Customer App against Supabase', conclusion: 'success' }, { name: 'Agent App against Supabase', conclusion: 'failure' }];
  reset();
  await update(OWNER, '/deploy');
  const [go] = lastButtons();
  assert.match(go, /^dp:/);
  assert.equal(dispatches('supabase-deploy.yml').length, 0, 'nothing is deployed by asking');
  // a developer who is not the owner can not approve (a listed developer would need an admin account: a stranger stands in)
  reset();
  await press(STRANGER, go);
  assert.equal(ghCalls.length, 0);
  // step 1: the backup starts, not the deployment
  reset();
  await press(OWNER, go);
  assert.equal(dispatches('backup.yml').length, 1);
  assert.equal(dispatches('supabase-deploy.yml').length, 0, 'not yet');
  reset();
  await press(OWNER, go);
  assert.equal(dispatches('backup.yml').length, 0, 'a second press does nothing');
  // the backup finishes: the second approval is offered
  gh.backupRun = { id: 7, status: 'completed', conclusion: 'success', created_at: new Date(Date.now() + 5000).toISOString(), html_url: 'https://github.com/x/actions/runs/7' };
  reset();
  await tick();
  assert.equal(sent('Backup iyo tijaabada soo celinta waa guuleysteen').length, 1);
  const [final] = lastButtons();
  // the branch moved meanwhile: the checked commit is not deployed
  const checked = gh.sha;
  gh.sha = 'ffffffffffffffffffff';
  reset();
  await press(OWNER, final);
  assert.equal(dispatches('supabase-deploy.yml').length, 0, 'a newer commit is never deployed by an old approval');
  gh.sha = checked;
  // (the button was used: a new /deploy starts the flow again)
  reset();
  await update(OWNER, '/deploy');
  const [again] = lastButtons();
  await press(OWNER, again);
  reset();
  await tick();
  const [final2] = lastButtons();
  reset();
  await press(OWNER, final2);
  const d = dispatches('supabase-deploy.yml');
  assert.equal(d.length, 1, 'now it is deployed, once');
  assert.deepEqual(d[0].body.inputs, { mode: 'deploy' });
  assert.equal(d[0].body.ref, 'main');
  const audit = (await db.query(`SELECT action FROM public.dev_audit WHERE actor = $1`, [OWNER])).rows.map((r) => r.action);
  for (const a of ['backup_started', 'deploy', 'approval_deploy', 'approval_deploy_go']) assert.ok(audit.includes(a), `audited: ${a}`);
  assert.ok((await db.query(`SELECT 1 FROM public.dev_memory WHERE kind = 'deploy'`)).rowCount >= 1, 'the deployment is in the memory');
});

test('a failed backup never deploys by itself: the owner may accept the risk explicitly', async () => {
  const secret = await workerSecret();
  if (!secret) return;
  gh.run = { id: 3, status: 'completed', html_url: 'https://github.com/x/actions/runs/3' };
  gh.jobs = [{ name: 'Backend tests (Auth, RPC, RLS, Realtime)', conclusion: 'success' }, { name: 'Customer App against Supabase', conclusion: 'success' }];
  reset();
  await update(OWNER, '/deploy');
  const [go] = lastButtons();
  await press(OWNER, go);
  gh.backupRun = { id: 8, status: 'completed', conclusion: 'failure', created_at: new Date(Date.now() + 5000).toISOString(), html_url: 'https://github.com/x/actions/runs/8' };
  reset();
  await fetch(`http://127.0.0.1:${PORTS.bot}/dev-bot/tick`, { method: 'POST', headers: { 'x-worker-secret': secret } });
  assert.equal(sent('ma gudbin').length, 1);
  assert.equal(dispatches('supabase-deploy.yml').length, 0, 'not deployed on its own');
  const [risk] = lastButtons();
  assert.match(risk, /^dn:/);
  reset();
  await press(OWNER, risk);
  assert.equal(dispatches('supabase-deploy.yml').length, 1);
  assert.ok((await db.query(`SELECT 1 FROM public.dev_audit WHERE actor = $1 AND action = 'deploy_without_backup'`, [OWNER])).rowCount >= 1);
});
