// The BADAL AGENT group's daily report (migrations/*_group_daily_report.sql): figures come from the real records,
// the day is 00:00 -> 23:59:59 in Africa/Mogadishu, a closed report is saved once and sent once, the real-time
// notices are remembered, and no order / wallet / ledger / commission row is changed by any of it.
// Every test runs in a transaction that is rolled back.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
let agentId;
let customerId;
before(async () => {
  agentId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  customerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000003'`)).rows[0].id;
});
after(() => db.end());

async function inTx(fn, claims = { role: 'service_role' }) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
    return await fn({
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

const DAY = '2021-03-15'; // a day with no real data: every figure below is the test's own
let seq = 0;
// 2021-03-15 00:00 Mogadishu = 2021-03-14 21:00 UTC
const at = (hhmm, day = DAY) => `${day} ${hhmm}:00+03`;
async function order(t, { dir = 'deposit', status = 'completed', amount = 100, net = null, when = at('10:00'), customer = customerId, method = 'evc_plus', reason = null, code = null }) {
  const cents = Math.round(amount * 100);
  const id = randomUUID();
  await t.query(
    `INSERT INTO public.orders (id, order_code, customer_id, direction, method, status, amount_cents, rate, fee_cents, net_cents, wallet_delta_cents,
       phone_number, winwin_id, created_at, updated_at, completed_at, failure_reason)
     VALUES ($1, $2, $3, $4::public.order_direction, $5::public.order_method, $6::public.order_status, $7, 1, 0, $8, 0, '61000000', 'W1', $9, $9,
       CASE WHEN $6 = 'completed' THEN $9::timestamptz END, $10)`,
    [id, code ?? `GR${++seq}${randomUUID().slice(0, 6).toUpperCase()}`, customer, dir, method, status, cents, Math.round((net ?? amount) * 100), when, reason]);
  return id;
}

test('the report counts the day from real records: deposits, withdrawals, payouts, transactions, pending, failed', () =>
  inTx(async (t) => {
    await order(t, { amount: 100 });
    await order(t, { amount: 50.5 });
    await order(t, { dir: 'withdraw', amount: 40, net: 39 });
    await order(t, { dir: 'withdraw', amount: 10, net: 9.5, when: at('23:59') });
    await order(t, { status: 'pending', amount: 7 });
    await order(t, { status: 'failed', amount: 12, reason: 'Sahal could not pay: low balance' });
    await order(t, { status: 'expired', amount: 3 });
    const r = await t.call(`private.report_build('${DAY}')`);
    assert.deepEqual(r.deposits, { count: 2, total: '150.50' });
    assert.deepEqual(r.withdrawals, { count: 2, total: '50.00' });
    assert.equal(r.payouts.total, '48.50');
    assert.equal(r.transactions, 4);
    assert.deepEqual(r.pending, { count: 1, total: '7.00' });
    assert.deepEqual(r.failed, { count: 1, total: '12.00' });
    assert.equal(r.otherClosed, 1);
    assert.equal(r.errors.insufficientBalance, 1);
    assert.equal(r.errors.failedOrders.length, 1);
    assert.match(r.errors.failedOrders[0].reason, /low balance/);
    assert.equal(r.live, false);
  }));

test('the day is 00:00 to 23:59:59 in Mogadishu: 23:59:59 belongs to the day, 00:00:00 to the next', () =>
  inTx(async (t) => {
    await order(t, { amount: 1, when: '2021-03-15 23:59:59+03' });
    await order(t, { amount: 2, when: '2021-03-16 00:00:00+03' });
    await order(t, { amount: 4, when: '2021-03-14 23:59:59+03' });
    const d15 = await t.call(`private.report_build('2021-03-15')`);
    const d16 = await t.call(`private.report_build('2021-03-16')`);
    assert.equal(d15.deposits.total, '1.00');
    assert.equal(d16.deposits.total, '2.00');
  }));

test('Top 5 customers by volume, with a masked phone and the deposits / withdrawals / count of each', () =>
  inTx(async (t) => {
    const ids = [];
    for (let i = 0; i < 6; i++) {
      const phone = `2526${String(Date.now()).slice(-5)}${i}${seq}`.slice(0, 12);
      const u = await t.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, $2, private.hash_password('x')) RETURNING id`, [phone, `Top ${i}`]);
      ids.push(u.rows[0].id);
    }
    for (let i = 0; i < 6; i++) await order(t, { customer: ids[i], amount: 10 * (i + 1) });          // volumes 10..60
    await order(t, { customer: ids[0], dir: 'withdraw', amount: 100, net: 99 });                       // customer 0 becomes the biggest
    const r = await t.call(`private.report_build('${DAY}')`);
    assert.equal(r.topCustomers.length, 5);
    assert.equal(r.topCustomers[0].name, 'Top 0');
    assert.equal(r.topCustomers[0].volume, '110.00');
    assert.equal(r.topCustomers[0].deposits, '10.00');
    assert.equal(r.topCustomers[0].withdrawals, '100.00');
    assert.equal(r.topCustomers[0].count, 2);
    assert.match(r.topCustomers[0].phone, /^\d\d••••\d\d$/);                                          // masked: never the full number
    assert.ok(!r.topCustomers.some((c) => c.name === 'Top 1'));                                       // the smallest is out
    assert.ok(!JSON.stringify(r).match(/password|pin/i));
  }));

test('agent earnings come from commission_entries of the day', () =>
  inTx(async (t) => {
    const o1 = await order(t, { amount: 100 });
    const o2 = await order(t, { amount: 200, when: at('11:00') });
    await t.query(`INSERT INTO public.commission_entries (order_id, agent_id, method, direction, amount_cents, rate_bp, bonus_bp, gross_micros, bonus_micros, net_micros, completed_at)
                   VALUES ($1, $2, 'evc_plus', 'deposit', 10000, 100, 0, 1000000, 0, 1000000, $3), ($4, $2, 'evc_plus', 'deposit', 20000, 100, 0, 2500000, 0, 2500000, $5)`,
      [o1, agentId, at('10:00'), o2, at('11:00')]);
    const r = await t.call(`private.report_build('${DAY}')`);
    assert.equal(r.earnings.count, 2);
    assert.equal(r.earnings.total, '3.50');
    assert.equal(r.agents.length, 1);
    assert.equal(r.agents[0].orders, 2);
  }));

test('closing saves the report once, is idempotent, and changes no order, wallet, ledger or commission row', () =>
  inTx(async (t) => {
    const count = async () => (await t.query(`SELECT (SELECT count(*) FROM public.orders) o, (SELECT count(*) FROM public.ledger_entries) l,
      (SELECT COALESCE(sum(available_cents), 0) FROM public.wallets) w, (SELECT count(*) FROM public.commission_entries) c,
      (SELECT COALESCE(sum(amount_cents), 0) FROM public.orders) a`)).rows[0];
    await t.query(`DELETE FROM public.daily_reports`);
    const before = await count();
    const n1 = await t.call(`private.daily_report_close()`);
    const rows1 = (await t.query(`SELECT day, closed_at FROM public.daily_reports`)).rows;
    const n2 = await t.call(`private.daily_report_close()`);
    const rows2 = (await t.query(`SELECT day, closed_at FROM public.daily_reports`)).rows;
    assert.equal(n1, 1);                                                    // first run: yesterday only
    assert.equal(rows1.length, 1);
    assert.equal(rows2.length, 1);                                          // not duplicated
    assert.deepEqual(rows2[0].closed_at, rows1[0].closed_at);               // not rebuilt
    assert.equal(n2, 0);                                                // nothing new to close
    assert.deepEqual(await count(), before);                                // financial records untouched
  }));

test('the morning send: only the linked chat, from 08:00, claimed once, in parts, marked sent, never twice', () =>
  inTx(async (t) => {
    await t.query(`DELETE FROM public.daily_reports`);
    await t.query(`UPDATE public.withdrawal_alert_chat SET chat_id = 777000111, linked_at = now() - interval '5 days'`);
    await t.query(`UPDATE public.app_settings SET value = '0' WHERE key = 'daily_report_hour'`);   // due now (local time is after 00:00)
    const todo = await t.call(`public.group_report_todo()`);
    assert.equal(todo.chatId, 777000111);
    assert.ok(todo.report, 'the closed day is due');
    assert.equal(todo.report.partsSent, 0);
    const again = await t.call(`public.group_report_todo()`);                // claimed: not handed out a second time
    assert.equal(again.report, null);
    await t.query(`SELECT public.daily_report_sent($1::date, 1, true)`, [todo.report.day]);
    await t.query(`UPDATE public.daily_reports SET claimed_at = NULL`);
    const done = await t.call(`public.group_report_todo()`);
    assert.equal(done.report, null);                                         // sent: never again
    const row = (await t.query(`SELECT sent_at, parts_sent, send_attempts FROM public.daily_reports`)).rows[0];
    assert.ok(row.sent_at);
    assert.equal(row.parts_sent, 1);
  }));

test('a failed send is retried (the claim is released) and a partly sent report resumes after the parts that went', () =>
  inTx(async (t) => {
    await t.query(`DELETE FROM public.daily_reports`);
    await t.query(`UPDATE public.withdrawal_alert_chat SET chat_id = 777000111, linked_at = now() - interval '5 days'`);
    await t.query(`UPDATE public.app_settings SET value = '0' WHERE key = 'daily_report_hour'`);
    const a = await t.call(`public.group_report_todo()`);
    await t.query(`SELECT public.daily_report_sent($1::date, 1, false, 'Telegram sendMessage: Too Many Requests')`, [a.report.day]);
    const b = await t.call(`public.group_report_todo()`);
    assert.equal(b.report.day, a.report.day);
    assert.equal(b.report.partsSent, 1);                                     // resumes after part 1
    assert.equal((await t.query(`SELECT send_attempts FROM public.daily_reports`)).rows[0].send_attempts, 2);
    await t.query(`UPDATE public.daily_reports SET send_attempts = 10, claimed_at = NULL, parts_sent = 1`);
    assert.equal((await t.call(`public.group_report_todo()`)).report, null);  // gives up after 10 attempts (the error stays visible)
  }));

test('before the morning hour nothing is sent; with no linked chat nothing is claimed', () =>
  inTx(async (t) => {
    await t.query(`DELETE FROM public.daily_reports`);
    await t.query(`UPDATE public.withdrawal_alert_chat SET chat_id = 777000111, linked_at = now() - interval '5 days'`);
    await t.query(`UPDATE public.app_settings SET value = '23' WHERE key = 'daily_report_hour'`);
    const local = (await t.query(`SELECT (now() AT TIME ZONE 'Africa/Mogadishu')::time < time '23:00' AS early`)).rows[0].early;
    if (local) assert.equal((await t.call(`public.group_report_todo()`)).report, null);
    await t.query(`UPDATE public.withdrawal_alert_chat SET chat_id = NULL`);
    assert.equal((await t.call(`public.group_report_todo()`)).chatId, null);
  }));

test('real-time notices: a credited deposit, a failed deposit, the Sahal balance: each once, after the link, not for old history', () =>
  inTx(async (t) => {
    await t.query(`UPDATE public.withdrawal_alert_chat SET chat_id = 777000111, linked_at = now() - interval '1 hour'`);
    await t.query(`UPDATE public.app_settings SET value = (now() - interval '1 hour')::text WHERE key = 'group_report_since'`);
    const now = new Date().toISOString();
    const old = new Date(Date.now() - 6 * 3600_000).toISOString();
    const dep = await order(t, { amount: 25, when: now, code: 'GRNEW1' });
    await order(t, { amount: 99, when: old, code: 'GROLD1' });                       // older than the link: not announced
    const bad = await order(t, { status: 'failed', amount: 8, when: now, code: 'GRBAD1', reason: 'no funds' });
    const first = await t.call(`public.group_report_todo()`);
    const mine = (list) => list.map((d) => d.code).filter((c) => c.startsWith('GR'));      // the shared database may hold other suites' orders
    assert.deepEqual(mine(first.deposits), ['GRNEW1']);
    assert.deepEqual(mine(first.failed), ['GRBAD1']);
    assert.ok(!JSON.stringify(first).match(/password|pin/i));
    assert.match(first.deposits[0].phone, /••••/);
    await t.query(`SELECT public.group_notified_mark('deposit', $1)`, [[dep]]);
    await t.query(`SELECT public.group_notified_mark('failed', $1)`, [[bad]]);
    await t.query(`SELECT public.group_notified_mark('deposit', $1)`, [[dep]]);      // marking twice is harmless
    const second = await t.call(`public.group_report_todo()`);
    assert.deepEqual(mine(second.deposits), []);
    assert.deepEqual(mine(second.failed), []);
  }));

test('the old 21:00 withdrawals summary is gone; the withdrawal alert state is otherwise unchanged', () =>
  inTx(async (t) => {
    await t.query(`UPDATE public.withdrawal_alert_chat SET chat_id = 777000111, linked_at = now() - interval '1 hour', summary_day = NULL`);
    const todo = await t.call(`public.withdrawal_alerts_todo()`);
    assert.equal(todo.summary, null);
    for (const k of ['chatId', 'new', 'changed', 'remind', 'strays']) assert.ok(k in todo, `${k} is still there`);
  }));

test('only the platform worker may use the report functions', async () => {
  for (const claims of [{ role: 'anon' }, { role: 'authenticated', sub: randomUUID() }]) {
    for (const sql of [`public.group_report_todo()`, `public.daily_report_get(NULL)`, `public.daily_report_sent(CURRENT_DATE, 1, true)`, `public.group_notified_mark('x', ARRAY['y'])`]) {
      await inTx(async (t) => {
        await t.query(`SET LOCAL ROLE ${claims.role}`);
        await assert.rejects(() => t.query(`SELECT ${sql}`), /permission denied|FORBIDDEN/i, `${claims.role} ${sql}`);
      }, claims);
    }
  }
  for (const table of ['daily_reports', 'group_notified']) {
    await inTx(async (t) => {
      await t.query('SET LOCAL ROLE authenticated');
      await assert.rejects(() => t.query(`SELECT * FROM public.${table}`), /permission denied/i);
    }, { role: 'authenticated', sub: randomUUID() });
  }
});

test('a saved report is readable by day (for /report), today so far is live, a future day is refused', () =>
  inTx(async (t) => {
    const today = await t.call(`public.daily_report_get(NULL)`);
    assert.equal(today.saved, false);
    assert.equal(today.data.live, true);
    const d = `(now() AT TIME ZONE 'Africa/Mogadishu')::date - 3`;
    await t.query(`INSERT INTO public.daily_reports (day, data) VALUES (${d}, '{"x":1}') ON CONFLICT (day) DO NOTHING`);
    const saved = await t.call(`public.daily_report_get(${d})`);
    assert.equal(saved.saved, true);
    assert.equal(await t.call(`public.daily_report_get((now() AT TIME ZONE 'Africa/Mogadishu')::date + 2)`), null);
  }));

test('/movehere: the person whose private chat gets the alerts can move them to a group; nobody else, and never to a private chat', () =>
  inTx(async (t) => {
    await t.query(`UPDATE public.withdrawal_alert_chat SET chat_id = 123456789, linked_at = now() - interval '3 days'`);
    assert.equal(await t.call(`public.withdrawal_alerts_move(555, -1009999, 'Team')`), false);            // a stranger
    assert.equal(await t.call(`public.withdrawal_alerts_move(123456789, 777, 'Private')`), false);        // not to a private chat
    assert.equal((await t.query(`SELECT chat_id FROM public.withdrawal_alert_chat`)).rows[0].chat_id, '123456789');
    assert.equal(await t.call(`public.withdrawal_alerts_move(123456789, -1009999, 'Team Badal')`), true);
    const row = (await t.query(`SELECT chat_id, chat_name, linked_at FROM public.withdrawal_alert_chat`)).rows[0];
    assert.equal(row.chat_id, '-1009999');
    assert.equal(row.chat_name, 'Team Badal');
    assert.ok(Date.now() - new Date(row.linked_at).getTime() < 60_000, 'the old history is not announced again');
    assert.equal(await t.call(`public.withdrawal_alerts_move(123456789, -1008888, 'Other')`), false);    // the old owner chat no longer matches
    assert.equal((await t.query(`SELECT count(*)::int AS n FROM public.audit_logs WHERE action = 'withdrawal_alerts.move' AND created_at > now() - interval '1 minute'`)).rows[0].n, 1);
  }));
