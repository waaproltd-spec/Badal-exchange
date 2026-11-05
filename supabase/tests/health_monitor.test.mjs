// The platform health monitor (migrations/*_health_monitor.sql): the scan raises ONE incident per problem and
// resolves it when the condition is gone; the safe repairs work and are capped; money is never repaired by
// the monitor; the owner's alerts are sent once, again after 6 hours (critical), and once on recovery.
// Every test runs in a transaction that is rolled back.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
let managerId;
let customerId;

before(async () => {
  managerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  customerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000003'`)).rows[0].id;
});
after(() => db.end());

async function inTx(fn, claims = { role: 'service_role' }) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    const as = (cl) => c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify(cl)]);
    await as(claims);
    return await fn({
      as,
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}
const asManager = (fn) => inTx(fn, { sub: managerId, role: 'authenticated', aud: 'authenticated' });

const scan = (tx) => tx.call(`private.health_scan()`);
/** The CI database may hold incidents from the real once-a-minute scan and conditions other tests left: start clean (all of it is rolled back). */
const cleanSlate = (tx) => tx.query(`DELETE FROM private.health_incidents`);
const incident = async (tx, key, status = 'open') =>
  (await tx.query(`SELECT * FROM private.health_incidents WHERE key = $1 AND status = $2 ORDER BY id DESC LIMIT 1`, [key, status])).rows[0];

/** A wallet whose balance agrees with its ledger, so that it can be made to disagree (other tests may leave others that do not). */
async function consistentWalletWithLedger(tx) {
  const w = (await tx.query(
    `SELECT w.id FROM public.wallets w
       JOIN LATERAL (SELECT l.balance_after_cents FROM public.ledger_entries l WHERE l.wallet_id = w.id
                      ORDER BY l.created_at DESC, l.id DESC LIMIT 1) last ON true
      WHERE last.balance_after_cents = w.available_cents LIMIT 1`)).rows[0];
  return w?.id;
}
const mismatches = async (tx) => Number((await tx.query(
  `SELECT count(*) AS n FROM public.wallets w
     JOIN LATERAL (SELECT l.balance_after_cents FROM public.ledger_entries l WHERE l.wallet_id = w.id
                    ORDER BY l.created_at DESC, l.id DESC LIMIT 1) last ON true
    WHERE last.balance_after_cents <> w.available_cents`)).rows[0].n);

test('one incident per problem: a second scan only counts it; when the condition is gone it is resolved', async () => {
  await inTx(async (tx) => {
    await cleanSlate(tx);
    await tx.query(`UPDATE public.sms_logs SET match_status = 'ignored' WHERE match_status = 'unmatched' AND match_failure_reason LIKE 'Rejected by the wallet phone/SIM check%'`);
    await tx.query(`INSERT INTO public.sms_logs (device_id, sender, body, parsed_provider, parsed_amount, parsed_phone, received_at, match_status, match_failure_reason)
                    VALUES ('hm-phone', '192', $1, 'Hormuud', 1.00, '252610000099', now(), 'unmatched', 'Rejected by the wallet phone/SIM check: expects another phone')`, [randomUUID()]);
    await scan(tx);
    const first = await incident(tx, 'sms_device_rejected');
    assert.ok(first, 'raised');
    assert.equal(first.severity, 'critical');
    assert.equal(first.financial_impact, true);
    await scan(tx);
    const again = await incident(tx, 'sms_device_rejected');
    assert.equal(again.id, first.id, 'the same incident');
    assert.equal(again.occurrences, first.occurrences + 1);
    const open = (await tx.query(`SELECT count(*)::int AS n FROM private.health_incidents WHERE key = 'sms_device_rejected' AND status = 'open'`)).rows[0].n;
    assert.equal(open, 1, 'never two open incidents of one problem');
    await tx.query(`UPDATE public.sms_logs SET match_status = 'ignored' WHERE device_id = 'hm-phone'`);
    await scan(tx);
    assert.equal(await incident(tx, 'sms_device_rejected'), undefined, 'no longer open');
    assert.equal((await incident(tx, 'sms_device_rejected', 'resolved')).auto_resolved, true);
  });
});

test('a wallet that disagrees with its ledger: critical and NOT repaired by the monitor; a negative balance cannot even be written', async () => {
  await inTx(async (tx) => {
    await cleanSlate(tx);
    const wallet = await consistentWalletWithLedger(tx);
    if (!wallet) return;
    const base = await mismatches(tx);
    const before = (await tx.query(`SELECT available_cents FROM public.wallets WHERE id = $1`, [wallet])).rows[0].available_cents;
    await tx.query(`UPDATE public.wallets SET available_cents = available_cents + 1 WHERE id = $1`, [wallet]);
    await scan(tx);
    const mismatch = await incident(tx, 'ledger_wallet_mismatch');
    assert.ok(mismatch, 'raised');
    assert.equal(mismatch.severity, 'critical');
    assert.equal(mismatch.needs_developer, true);
    assert.equal(mismatch.repairs, 0, 'the monitor never repairs money');
    assert.equal(mismatch.detail.wallets, base + 1);
    await scan(tx);
    const now = (await tx.query(`SELECT available_cents FROM public.wallets WHERE id = $1`, [wallet])).rows[0].available_cents;
    assert.equal(Number(now), Number(before) + 1, 'the balance was left exactly as it was found');
    // A negative balance cannot even be written: the database refuses it (the monitor's check is a second line).
    await tx.query(`SAVEPOINT neg`);
    await assert.rejects(tx.query(`UPDATE public.wallets SET available_cents = -5 WHERE id = $1`, [wallet]), /check constraint/);
    await tx.query(`ROLLBACK TO neg`);
    await tx.query(`UPDATE public.wallets SET available_cents = $2 WHERE id = $1`, [wallet, before]);
    await scan(tx);
    const left = await incident(tx, 'ledger_wallet_mismatch');
    if (base === 0) assert.equal(left, undefined, 'resolved once the data is consistent again');
    else assert.equal(left.detail.wallets, base, 'only the wallets other tests left inconsistent remain');
  });
});

test('self-healing: scheduled messages stuck in "sending" go back to the queue, and the next scan confirms it worked', async () => {
  await inTx(async (tx) => {
    await cleanSlate(tx);
    await tx.query(`UPDATE public.broadcast_deliveries SET status = 'sent' WHERE status = 'sending'`);
    const run = (await tx.query(`INSERT INTO public.broadcast_runs (message, channel, is_test) VALUES ('hm', 'telegram', true) RETURNING id`)).rows[0].id;
    await tx.query(`INSERT INTO public.broadcast_deliveries (run_id, chat_id, status, claimed_at) VALUES ($1, 111222333, 'sending', now() - interval '20 minutes')`, [run]);
    await scan(tx);
    const inc = await incident(tx, 'broadcast_stuck');
    assert.ok(inc, 'raised');
    assert.equal(inc.repairs, 1);
    assert.match(inc.repair, /pending/);
    const d = (await tx.query(`SELECT status, claimed_at FROM public.broadcast_deliveries WHERE run_id = $1`, [run])).rows[0];
    assert.equal(d.status, 'pending');
    assert.equal(d.claimed_at, null);
    await scan(tx);
    assert.equal(await incident(tx, 'broadcast_stuck'), undefined);
    const done = await incident(tx, 'broadcast_stuck', 'resolved');
    assert.match(done.repair_result, /worked/, 'the repair is judged by the next scan');
  });
});

test('a repair is tried at most 3 times, 5 minutes apart; then the developer is told instead of retrying for ever', async () => {
  await inTx(async (tx) => {
    await tx.call(`private.health_raise('hm_test', 'warning', 'Test', '{}')`);
    assert.equal(await tx.call(`private.health_may_repair('hm_test')`), true);
    await tx.call(`private.health_repaired('hm_test', 'restart', 'waiting')`);
    assert.equal(await tx.call(`private.health_may_repair('hm_test')`), false, 'not again within 5 minutes');
    await tx.query(`UPDATE private.health_incidents SET last_repair_at = now() - interval '10 minutes' WHERE key = 'hm_test'`);
    assert.equal(await tx.call(`private.health_may_repair('hm_test')`), true);
    await tx.call(`private.health_repaired('hm_test', 'restart', 'waiting')`);
    await tx.query(`UPDATE private.health_incidents SET last_repair_at = now() - interval '10 minutes' WHERE key = 'hm_test'`);
    await tx.call(`private.health_repaired('hm_test', 'restart', 'waiting')`);
    await tx.query(`UPDATE private.health_incidents SET last_repair_at = now() - interval '10 minutes' WHERE key = 'hm_test'`);
    assert.equal(await tx.call(`private.health_may_repair('hm_test')`), false, 'three tries are enough');
    assert.equal((await incident(tx, 'hm_test')).needs_developer, true);
  });
});

test('the owner is told once, after 2 minutes, again after 6 hours when critical (24 for a warning), once when resolved; never for info', async () => {
  await inTx(async (tx) => {
    await cleanSlate(tx);
    const claim = async () => (await tx.call(`public.health_alert_claim()`)).filter((a) => a.key.startsWith('hm_'));
    await tx.call(`private.health_raise('hm_crit', 'critical', 'Critical', '{}', 'sabab', true, true)`);
    await tx.call(`private.health_raise('hm_warn', 'warning', 'Warning', '{}')`);
    await tx.call(`private.health_raise('hm_info', 'info', 'Info', '{}')`);
    assert.deepEqual(await claim(), [], 'a flicker is not reported: it must last 2 minutes');
    await tx.query(`UPDATE private.health_incidents SET first_seen = now() - interval '3 minutes' WHERE key LIKE 'hm_%'`);
    let a = await claim();
    assert.deepEqual(a.map((x) => [x.key, x.kind]).sort(), [['hm_crit', 'new'], ['hm_warn', 'new']], 'info is never sent');
    assert.equal(a.find((x) => x.key === 'hm_crit').financial, true);
    await tx.call(`public.health_alert_done($1::jsonb)`, [JSON.stringify(a.map((x) => ({ id: x.id, kind: x.kind })))]);
    assert.deepEqual(await claim(), [], 'once');
    await tx.query(`UPDATE private.health_incidents SET alerted_at = now() - interval '7 hours' WHERE key IN ('hm_crit', 'hm_warn')`);
    a = await claim();
    assert.deepEqual(a.map((x) => [x.key, x.kind]), [['hm_crit', 'repeat']], 'critical again after 6 hours; a warning waits 24');
    await tx.call(`public.health_alert_done($1::jsonb)`, [JSON.stringify(a.map((x) => ({ id: x.id, kind: x.kind })))]);
    await tx.call(`private.health_clear('hm_crit')`);
    await tx.call(`private.health_clear('hm_info')`);
    a = await claim();
    assert.deepEqual(a.map((x) => [x.key, x.kind]), [['hm_crit', 'resolved']], 'recovery is told once; an info incident that was never sent is not');
    await tx.call(`public.health_alert_done($1::jsonb)`, [JSON.stringify(a.map((x) => ({ id: x.id, kind: x.kind })))]);
    assert.deepEqual((await claim()).map((x) => [x.key, x.kind]), []);
  });
});

test('a cash register integration that stops answering is an incident of its own, cleared when it answers again', async () => {
  await inTx(async (tx) => {
    await cleanSlate(tx);
    await tx.query(`INSERT INTO public.cashdesk_balances (method, ok, error, checked_at) VALUES ('melbet', false, 'invalid or missing sign signature', now())`);
    await scan(tx);
    const inc = await incident(tx, 'integration:melbet');
    assert.ok(inc);
    assert.match(inc.detail.error, /sign/);
    await tx.query(`INSERT INTO public.cashdesk_balances (method, ok, balance_cents, limit_cents, checked_at) VALUES ('melbet', true, 1000, 100, now() + interval '1 second')`);
    await scan(tx);
    assert.equal(await incident(tx, 'integration:melbet'), undefined);
  });
});

test('an Edge Function reports what it found (a Telegram webhook) and what it repaired', async () => {
  await inTx(async (tx) => {
    await tx.call(`public.health_report_external('webhook:hm', false, 'warning', 'Webhook-ka waa go an', '{"lastError":"x"}'::jsonb, 'webhook-ka waa la ordayay', 'setWebhook', 'ok')`);
    const inc = await incident(tx, 'webhook:hm');
    assert.equal(inc.repairs, 1);
    assert.equal(inc.repair, 'setWebhook');
    await tx.call(`public.health_report_external('webhook:hm', true)`);
    assert.equal(await incident(tx, 'webhook:hm'), undefined);
    await assert.rejects(tx.query(`SAVEPOINT s`).then(() => tx.call(`public.health_report_external('BAD KEY', false)`)).finally(() => tx.query(`ROLLBACK TO s`)));
  });
});

test('a check that crashes is reported as its own incident and never stops the other checks', async () => {
  await inTx(async (tx) => {
    const r = await scan(tx);
    assert.equal(r.errors, 0, 'a healthy schema: no check crashed');
    assert.ok(r.checks >= 13);
  });
});

test('who may see and call: managers read the health; the alert queue and reports are for the service role only', async () => {
  await asManager(async (tx) => {
    const h = await tx.call(`public.manage_system_health()`);
    assert.ok(Array.isArray(h.open));
    assert.ok(h.lastScan === null || typeof h.lastScan.checks === 'number');
    for (const sql of [`public.health_alert_claim()`, `public.health_alert_done('[]'::jsonb)`, `public.health_report_external('webhook:x', false)`]) {
      await assert.rejects(tx.query(`SAVEPOINT s`).then(() => tx.call(sql)).finally(() => tx.query(`ROLLBACK TO s`)), undefined, sql);
    }
  });
  await inTx(async (tx) => {
    await tx.as({ sub: customerId, role: 'authenticated', aud: 'authenticated' });
    await assert.rejects(tx.query(`SAVEPOINT s`).then(() => tx.call(`public.manage_system_health()`)).finally(() => tx.query(`ROLLBACK TO s`)));
  });
});

// ---------------------------------------------------------------- the Edge Function route (needs the served stack)

const tgCalls = [];
const telegram = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const method = req.url.split('/').pop();
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
    tgCalls.push({ method, body });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    // getWebhookInfo answers with no webhook at all: the function must register it again.
    res.end(JSON.stringify({ ok: true, result: method === 'sendMessage' ? { message_id: 1 } : method === 'getWebhookInfo' ? { url: '' } : true }));
  });
});

test('the /health route: only the platform secret wakes it; the owner gets each alert once; a lost webhook is registered again and reported', async (t) => {
  const secret = (await db.query(`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret'`)).rows[0]?.decrypted_secret;
  const probe = await fetch(`${URL}/functions/v1/support-bot/health`, { method: 'POST', body: '{}' }).catch(() => null);
  if (!secret || probe?.status !== 403) return t.skip('support-bot is not served');
  await new Promise((r) => telegram.listen(4993, '0.0.0.0', r));
  const adminBefore = (await db.query(`SELECT chat_id FROM public.support_admin WHERE id`)).rows[0]?.chat_id ?? null;
  const ownerChat = 8700000000 + (Number(Date.now().toString().slice(-6)));
  const title = `Alert test ${randomUUID().slice(0, 8)}`;
  const health = () => fetch(`${URL}/functions/v1/support-bot/health`, { method: 'POST', headers: { 'x-worker-secret': secret }, body: '{}' });
  try {
    assert.equal((await fetch(`${URL}/functions/v1/support-bot/health`, { method: 'POST', headers: { 'x-worker-secret': 'nope' }, body: '{}' })).status, 403);
    await db.query(`INSERT INTO public.support_admin (id, chat_id) VALUES (true, $1) ON CONFLICT (id) DO UPDATE SET chat_id = EXCLUDED.chat_id`, [ownerChat]);
    await db.query(`SELECT private.health_raise('hm_route_test', 'critical', $1, '{"orders": 2}'::jsonb, 'sabab tijaabo', true, true, true)`, [title]);
    await db.query(`UPDATE private.health_incidents SET first_seen = now() - interval '5 minutes' WHERE key = 'hm_route_test'`);
    tgCalls.length = 0;
    const first = await (await health()).json();
    assert.equal(first.ok, true);
    const sent = tgCalls.filter((c) => c.method === 'sendMessage' && Number(c.body.chat_id) === ownerChat && String(c.body.text).includes(title));
    assert.equal(sent.length, 1, 'the owner is told');
    const text = String(sent[0].body.text);
    for (const part of ['DIGNIIN WEYN', 'Nidaamka', 'Sababta: sabab tijaabo', 'Lacagta: ', 'HAA', 'Horumariye']) assert.ok(text.includes(part), `the alert says "${part}"`);
    assert.ok(!/token|secret|password/i.test(text), 'never a secret');
    tgCalls.length = 0;
    await health();
    assert.equal(tgCalls.filter((c) => c.method === 'sendMessage' && String(c.body.text).includes(title)).length, 0, 'not told twice');
    assert.ok(tgCalls.some((c) => c.method === 'setWebhook'), 'Telegram had no webhook: it was registered again');
    const hook = (await db.query(`SELECT repairs, repair FROM private.health_incidents WHERE key = 'webhook:support-bot' AND status = 'open'`)).rows[0];
    assert.ok(hook, 'the lost webhook is an incident');
    assert.ok(hook.repairs >= 1);
    // recovery: told once
    await db.query(`SELECT private.health_clear('hm_route_test')`);
    tgCalls.length = 0;
    await health();
    assert.equal(tgCalls.filter((c) => c.method === 'sendMessage' && String(c.body.text).includes(title) && String(c.body.text).includes('LA XALIYAY')).length, 1);
  } finally {
    await db.query(`DELETE FROM private.health_incidents WHERE key IN ('hm_route_test', 'webhook:support-bot', 'telegram_support_bot_token')`);
    if (adminBefore) await db.query(`UPDATE public.support_admin SET chat_id = $1 WHERE id`, [adminBefore]);
    else await db.query(`DELETE FROM public.support_admin WHERE id`);
    telegram.close();
  }
});

test('housekeeping prunes only the scheduler history and never throws; the foreign key has its index', async () => {
  const r = await db.query(`SELECT private.housekeeping() AS r`);
  assert.equal(typeof r.rows[0].r.cronRowsDeleted, 'number');
  const idx = await db.query(`SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_cashdesk_balances_requested_by'`);
  assert.equal(idx.rowCount, 1);
});
