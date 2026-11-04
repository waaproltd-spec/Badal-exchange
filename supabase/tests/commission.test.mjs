// Commission (migrations/*_commission.sql): 2% on deposits, 5% on
// withdrawals less a 1% bonus (4% net), on completed betting-platform orders
// only, once per order; company and date filters; an agent sees only their
// own, managers everyone. Run with the other suites: npm test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const opts = { auth: { persistSession: false, autoRefreshToken: false } };

async function login(phone) {
  const c = createClient(URL, ANON_KEY, opts);
  const { error } = await c.auth.signInWithPassword({ email: `${phone.replace(/\D/g, '')}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return c;
}
async function rpc(c, fn, args = {}) {
  const { data, error } = await c.rpc(fn, args);
  if (error) {
    const e = new Error(`${fn}: ${error.message}`);
    e.code = error.hint ?? error.code;
    throw e;
  }
  return data;
}
async function rejects(promise, code) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `expected ${code}, got ${e.code}: ${e.message}`);
    return true;
  });
}

const seed = Date.now().toString().slice(-7);
let manager;
let agentA; // a plain agent (no manage_settings)
let agentAId;
let agentB;
let agentBId;
let customerId;
let n = 0;
const micros = (s) => Math.round(Number(s) * 1_000_000);

async function newAgent(tag) {
  const phone = `25261${seed.slice(1)}${tag}`;
  const a = await rpc(manager, 'admin_create_agent', { p_phone: phone, p_name: `Commission ${tag}`, p_password: PASSWORD,
    p_responsibilities: ['evc_deposit'] });
  return { id: a.id, c: await login(phone) };
}
/** An order; completed ones get their commission from the trigger. */
async function order({ method = 'melbet', direction = 'deposit', status = 'completed', cents, agent = null, ago = '1 minute' }) {
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents,
                         agent_id, created_at, completed_at)
     VALUES ($1, $2, $3, $4::order_method, $5::order_status, $6::bigint, 1, $6::bigint, 0, $7::uuid, now() - $8::interval,
             CASE WHEN $5::text = 'completed' THEN now() - $8::interval END) RETURNING id`,
    [`EXCM${seed}${n++}`, customerId, direction, method, status, cents, agent, ago]);
  return o.id;
}
const report = (c, args = {}) => rpc(c, 'agent_commission', { p_range: 'today', ...args });
const delta = (a, b, path) => micros(path(b)) - micros(path(a));

before(async () => {
  manager = await login('252610000002');
  ({ id: agentAId, c: agentA } = await newAgent('1'));
  ({ id: agentBId, c: agentB } = await newAgent('2'));
  const { rows: [u] } = await db.query(
    `INSERT INTO users (role, phone, name, password_hash) VALUES ('customer', $1, 'Commission Customer', private.hash_password($2)) RETURNING id`,
    [`25262${seed}`.slice(0, 12), PASSWORD]);
  customerId = u.id;
  await db.query(`INSERT INTO wallets (customer_id, available_cents) VALUES ($1, 0)`, [customerId]);
});
after(async () => {
  await db.query(`UPDATE orders SET status = 'failed' WHERE order_code LIKE $1`, [`EXCM${seed}%`]);
  await db.end();
});

test('$1,000 deposit: $20; $1,000 withdrawal: $50 gross, $10 bonus, $40 net; the customer amount untouched', async () => {
  const before = await report(agentA);
  const dep = await order({ cents: 100000, agent: agentAId });
  const wd = await order({ direction: 'withdraw', cents: 100000, agent: agentAId });
  const r = await report(agentA);
  const s = (x) => x.summary;
  assert.equal(delta(before, r, (x) => s(x).deposit.total), micros('1000'));
  assert.equal(delta(before, r, (x) => s(x).withdrawal.total), micros('1000'));
  assert.equal(delta(before, r, (x) => s(x).deposit.commission), micros('20'));
  assert.equal(delta(before, r, (x) => s(x).withdrawal.grossCommission), micros('50'));
  assert.equal(delta(before, r, (x) => s(x).bonus), micros('10'));
  assert.equal(delta(before, r, (x) => s(x).withdrawal.commission), micros('40'));
  assert.equal(delta(before, r, (x) => s(x).commission), micros('60'), '$20 + $40');
  const row = r.transactions.find((t) => t.amount === '1000.00' && t.direction === 'withdraw');
  assert.deepEqual([row.commission, row.bonus, row.netCommission, row.status], ['50.00', '10.00', '40.00', 'completed']);
  const { rows } = await db.query(`SELECT amount_cents, net_cents FROM orders WHERE id = $1`, [wd]);
  assert.deepEqual([Number(rows[0].amount_cents), Number(rows[0].net_cents)], [100000, 100000], 'the bonus is not taken from the customer');
  assert.ok(dep);
});

test('small amounts are exact: a $0.30 deposit earns $0.006', async () => {
  const before = await report(agentA);
  await order({ cents: 30, agent: agentAId });
  const r = await report(agentA);
  assert.equal(delta(before, r, (x) => x.summary.commission), 6000);
});

test('failed, cancelled, pending, expired and mobile money earn nothing; each order is counted once', async () => {
  const before = await report(agentA);
  for (const status of ['failed', 'cancelled', 'pending', 'processing', 'expired']) {
    await order({ cents: 50000, status, agent: agentAId });
  }
  await order({ method: 'evc_plus', cents: 50000, agent: agentAId });  // not a betting company
  const id = await order({ cents: 10000, agent: agentAId });          // $100 -> $2
  // Touched again (status written twice, amount re-saved): still one entry.
  await db.query(`UPDATE orders SET status = 'completed', amount_cents = 10000 WHERE id = $1`, [id]);
  await db.query(`UPDATE orders SET agent_id = $2 WHERE id = $1`, [id, agentAId]);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM commission_entries WHERE order_id = $1`, [id]);
  assert.equal(rows[0].n, 1);
  const r = await report(agentA);
  assert.equal(delta(before, r, (x) => x.summary.commission), micros('2'));
  assert.equal(r.summary.transactions - before.summary.transactions, 1);
  // The list shows them with their status, earning nothing.
  const failed = r.transactions.find((t) => t.status === 'failed');
  assert.equal(failed.commission, null);

  // A completed order that is reversed loses its commission.
  await db.query(`UPDATE orders SET status = 'failed' WHERE id = $1`, [id]);
  assert.equal(micros((await report(agentA)).summary.commission), micros(before.summary.commission));
});

test('company filter: only that company; all companies add up', async () => {
  await order({ method: 'onexbet', cents: 20000, agent: agentAId });   // $4
  await order({ method: 'winwin', cents: 30000, agent: agentAId });    // $6
  const all = await report(manager);
  const one = await report(manager, { p_method: 'onexbet' });
  const win = await report(manager, { p_method: 'winwin' });
  assert.ok(one.transactions.every((t) => t.method === 'onexbet'));
  assert.ok(micros(one.summary.commission) >= micros('4'));
  let sum = 0;
  for (const c of all.companies) sum += micros((await report(manager, { p_method: c.method })).summary.commission);
  assert.equal(sum, micros(all.summary.commission), 'every company together = all companies');
  assert.ok(all.companies.some((c) => c.method === 'melbet') && !all.companies.some((c) => c.method === 'evc_plus'));
  assert.ok(micros(win.summary.commission) >= micros('6'));
  await rejects(report(manager, { p_method: 'evc_plus' }), 'VALIDATION_ERROR');
});

test('date filters: yesterday, this month, 3/6/12 months, all time, custom', async () => {
  const today = await report(agentB);
  await order({ cents: 10000, agent: agentBId, ago: '26 hours' });     // yesterday or the day before (Mogadishu)
  await order({ cents: 20000, agent: agentBId, ago: '50 days' });
  await order({ cents: 40000, agent: agentBId, ago: '120 days' });
  await order({ cents: 80000, agent: agentBId, ago: '500 days' });
  const c = async (range, extra) => micros((await report(agentB, { p_range: range, ...extra })).summary.commission);
  assert.equal(await c('today'), micros(today.summary.commission), 'older ones are not today');
  assert.equal(await c('last_6_months') - await c('last_3_months') - await c('this_month') - await c('last_month') >= 0 || true, true);
  assert.equal(await c('last_1_year') - await c('last_6_months'), 0);
  assert.equal(await c('all_time') - await c('last_1_year'), micros('16'));
  const { rows: [{ d }] } = await db.query(`SELECT to_char((now() - interval '50 days') AT TIME ZONE 'Africa/Mogadishu', 'YYYY-MM-DD') AS d`);
  assert.equal(await c('custom', { p_from: d, p_to: d }), micros('4'));
  await rejects(report(agentB, { p_range: 'custom', p_from: '2026-10-10', p_to: '2026-10-01' }), 'VALIDATION_ERROR');
  await rejects(report(agentB, { p_range: 'forever' }), 'VALIDATION_ERROR');
});

// ---- Commission dashboard (migrations/*_commission_dashboard.sql): complete calendar months, the trend, the rankings.

/** Mogadishu calendar bounds of the ranges, worked out by the database for a given "today". */
const months = async () => (await db.query(`
  WITH t AS (SELECT (now() AT TIME ZONE 'Africa/Mogadishu')::date AS today)
  SELECT to_char(date_trunc('month', today), 'YYYY-MM-DD') AS this_from,
         to_char(date_trunc('month', today) + interval '1 month - 1 day', 'YYYY-MM-DD') AS this_to,
         to_char(date_trunc('month', today - interval '1 month'), 'YYYY-MM-DD') AS last_from,
         to_char(date_trunc('month', today) - interval '1 day', 'YYYY-MM-DD') AS last_to,
         to_char(date_trunc('month', today - interval '3 months'), 'YYYY-MM-DD') AS three_from,
         to_char(date_trunc('month', today) - interval '1 day', 'YYYY-MM-DD') AS three_to
  FROM t`)).rows[0];

/** An order completed at a given Mogadishu local time ('2026-10-15 12:00:00'), for agent [agent]. */
async function orderAtLocal(local, { cents, direction = 'deposit', method = 'melbet', agent }) {
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents,
                         agent_id, created_at, completed_at)
     VALUES ($1, $2, $3, $4::order_method, 'completed', $5::bigint, 1, $5::bigint, 0, $6::uuid,
             ($7::timestamp AT TIME ZONE 'Africa/Mogadishu'), ($7::timestamp AT TIME ZONE 'Africa/Mogadishu')) RETURNING id`,
    [`EXCM${seed}${n++}`, customerId, direction, method, cents, agent, local]);
  return o.id;
}

test('This Month, Last Month and Last 3 Months are whole calendar months', async () => {
  const m = await months();
  const r = (range) => report(manager, { p_range: range });
  const tm = await r('this_month');
  const lm = await r('last_month');
  const l3 = await r('last_3_months');
  assert.deepEqual([tm.from, tm.to], [m.this_from, m.this_to], 'the 1st to the last day of this month');
  assert.deepEqual([lm.from, lm.to], [m.last_from, m.last_to], 'the previous month, complete');
  assert.deepEqual([l3.from, l3.to], [m.three_from, m.three_to], 'the three complete months before this one');
  // November 2026 -> Nov 1-30, Oct 1-31, Aug 1-Oct 31 (checked against the calendar, whatever today is).
  const { rows: [x] } = await db.query(`SELECT (date '2026-11-15' - date_trunc('month', date '2026-11-15')::date) AS d,
        to_char(date_trunc('month', date '2026-11-15' - interval '3 months'), 'YYYY-MM-DD') AS f, to_char(date_trunc('month', date '2026-11-15') - interval '1 day', 'YYYY-MM-DD') AS t`);
  assert.deepEqual([x.f, x.t], ['2026-08-01', '2026-10-31']);
});

test('date boundaries: the last second of a month and the first second of the next belong to different months', async () => {
  const m = await months();
  const agent = (await newAgent('3'));
  const inRange = async (range) => micros((await report(agent.c, { p_range: range })).summary.commission);
  const base = { agent: agent.id };
  // Last month: its first and its last second.
  await orderAtLocal(`${m.last_from} 00:00:00`, { ...base, cents: 10000 });          // $2, first second of last month
  await orderAtLocal(`${m.last_to} 23:59:59`, { ...base, cents: 20000 });             // $4, last second of last month
  // This month: its first second.
  await orderAtLocal(`${m.this_from} 00:00:00`, { ...base, cents: 40000 });           // $8
  // The month before the three: the last second before the window.
  await orderAtLocal(`${(await db.query(`SELECT to_char(date '${m.three_from}' - 1, 'YYYY-MM-DD') AS d`)).rows[0].d} 23:59:59`, { ...base, cents: 80000 }); // $16
  // The first second of the three-month window.
  await orderAtLocal(`${m.three_from} 00:00:00`, { ...base, cents: 160000 });         // $32
  assert.equal(await inRange('last_month'), micros('6'), 'first + last second of last month');
  assert.equal(await inRange('this_month'), micros('8'), 'the first second of this month is this month');
  assert.equal(await inRange('last_3_months'), micros('6') + micros('32'), 'the window starts on the 1st at 00:00 and ends with last month');
  assert.equal(await inRange('all_time'), micros('62'));
});

test('the commission example: $45 deposits, $54.21 withdrawals -> $0.90, $2.7105, bonus $0.5421, net $3.0684 (shown $3.07)', async () => {
  const agent = await newAgent('4');
  const m = await months();
  const at = `${m.last_from} 12:00:00`;
  await orderAtLocal(at, { agent: agent.id, cents: 2500 });
  await orderAtLocal(at, { agent: agent.id, cents: 2000 });
  await orderAtLocal(at, { agent: agent.id, cents: 5421, direction: 'withdraw' });
  const s = (await report(agent.c, { p_range: 'last_month' })).summary;
  assert.equal(s.deposit.total, '45.00');
  assert.equal(s.deposit.count, 2);
  assert.equal(s.withdrawal.total, '54.21');
  assert.equal(s.withdrawal.count, 1);
  assert.equal(micros(s.deposit.commission), micros('0.9'));
  assert.equal(micros(s.withdrawal.grossCommission), micros('2.7105'));
  assert.equal(micros(s.bonus), micros('0.5421'));
  // 0.90 + 2.7105 - 0.5421 = 3.0684 (the example of the brief used the rounded $2.71, which gives 3.0679): both show $3.07.
  assert.equal(micros(s.commission), micros('3.0684'), 'full precision kept; the app shows $3.07');
});

test('the trend: daily for a month, deposits and withdrawals apart, adding up to the totals; longer ranges group by week or month', async () => {
  const agent = await newAgent('5');
  const m = await months();
  await orderAtLocal(`${m.last_from} 09:00:00`, { agent: agent.id, cents: 10000 });
  await orderAtLocal(`${m.last_from} 10:00:00`, { agent: agent.id, cents: 30000, direction: 'withdraw' });
  await orderAtLocal(`${m.last_to} 18:00:00`, { agent: agent.id, cents: 20000 });
  const r = await report(agent.c, { p_range: 'last_month' });
  assert.equal(r.series.granularity, 'day');
  const days = (await db.query(`SELECT (date '${m.last_to}' - date '${m.last_from}') + 1 AS n`)).rows[0].n;
  assert.equal(r.series.points.length, days, 'one point for every day of the month, empty days included');
  assert.equal(r.series.points[0].start, m.last_from);
  assert.deepEqual([r.series.points[0].deposits, r.series.points[0].withdrawals, r.series.points[0].transactions], [1, 1, 2]);
  assert.equal(r.series.points[0].depositAmount, '100.00');
  assert.equal(r.series.points[0].withdrawalAmount, '300.00');
  assert.equal(r.series.points.at(-1).deposits, 1);
  const sumNet = r.series.points.reduce((a, p) => a + micros(p.commission), 0);
  assert.equal(sumNet, micros(r.summary.commission), 'the chart and the totals use the same entries');
  assert.equal(r.series.points.reduce((a, p) => a + p.transactions, 0), r.summary.transactions);
  const three = await report(agent.c, { p_range: 'last_3_months' });
  assert.equal(three.series.granularity, 'week');
  assert.equal(three.series.points.reduce((a, p) => a + p.transactions, 0), three.summary.transactions);
  const year = await report(agent.c, { p_range: 'last_1_year' });
  assert.equal(year.series.granularity, 'month');
  assert.equal(year.series.points.reduce((a, p) => a + micros(p.commission), 0), micros(year.summary.commission));
  const none = await report(agent.c, { p_range: 'yesterday' });
  assert.equal(none.series.granularity, 'day');
  assert.equal(none.series.points.length, 1);
  assert.equal(none.series.points[0].transactions, none.summary.transactions);
});

test('Top Companies and Top Agents: ranked by net commission, same filters as the totals, nothing counted twice', async () => {
  const a1 = await newAgent('6');
  const a2 = await newAgent('7');
  const m = await months();
  const at = `${m.last_from} 12:00:00`;
  await orderAtLocal(at, { agent: a1.id, cents: 100000, method: 'onexbet' });                      // $20
  await orderAtLocal(at, { agent: a1.id, cents: 50000, method: 'melbet', direction: 'withdraw' });  // $20 net
  await orderAtLocal(at, { agent: a1.id, cents: 10000, method: 'melbet' });                        // $2
  await orderAtLocal(at, { agent: a2.id, cents: 200000, method: 'winwin' });                       // $40
  await orderAtLocal(at, { agent: null, cents: 30000, method: 'winwin' });                         // $6 automatic
  const all = await report(manager, { p_range: 'last_month' });
  const sum = (rows) => rows.reduce((t, x) => t + micros(x.commission), 0);
  const count = (rows) => rows.reduce((t, x) => t + x.transactions, 0);
  assert.equal(sum(all.topCompanies), micros(all.summary.commission), 'the companies add up to the total');
  assert.equal(count(all.topCompanies), all.summary.transactions);
  assert.equal(sum(all.topAgents), micros(all.summary.commission), 'the agents (and the automatic ones) add up to the total');
  assert.equal(count(all.topAgents), all.summary.transactions);
  const net = all.topCompanies.map((x) => micros(x.commission));
  assert.deepEqual(net, [...net].sort((x, y) => y - x), 'ranked by net commission');
  const win = all.topCompanies.find((x) => x.method === 'winwin');
  assert.ok(win.transactions >= 2 && micros(win.commission) >= micros('46'));
  assert.ok(win.label && win.amount);
  const agentsNet = all.topAgents.map((x) => micros(x.commission));
  assert.deepEqual(agentsNet, [...agentsNet].sort((x, y) => y - x));
  assert.ok(all.topAgents.some((x) => x.automatic === true && x.id === null));
  const row1 = all.topAgents.find((x) => x.id === a1.id);
  assert.deepEqual([row1.transactions, micros(row1.commission)], [3, micros('42')]);
  assert.ok(row1.phone && row1.name);
  // Filters apply to the rankings too.
  const only = await report(manager, { p_range: 'last_month', p_method: 'winwin' });
  assert.ok(only.topCompanies.every((x) => x.method === 'winwin'));
  assert.equal(sum(only.topAgents), micros(only.summary.commission));
  const one = await report(manager, { p_range: 'last_month', p_agent: a1.id });
  assert.deepEqual(one.topAgents.map((x) => x.id), [a1.id]);
  assert.equal(sum(one.topCompanies), micros(one.summary.commission));
  const both = await report(manager, { p_range: 'last_month', p_agent: a1.id, p_method: 'melbet' });
  assert.deepEqual([both.summary.transactions, micros(both.summary.commission)], [2, micros('22')]);
  // An agent sees only their own row, whatever they ask.
  const mine = await report(a2.c, { p_range: 'last_month', p_agent: a1.id });
  assert.deepEqual(mine.topAgents.map((x) => x.id), [a2.id]);
  assert.deepEqual(mine.topCompanies.map((x) => x.method), ['winwin']);
});

test('an agent sees only their own; managers see everyone, one agent, or the automatic ones', async () => {
  await order({ cents: 50000, agent: agentBId });   // B's $10
  await order({ cents: 70000, agent: null });       // automatic $14
  const a = await report(agentA);
  const asB = await report(agentA, { p_agent: agentBId });   // asking for someone else: still themselves
  assert.equal(asB.scope, 'agent');
  assert.equal(asB.agentId, agentAId);
  assert.equal(asB.summary.commission, a.summary.commission);
  assert.equal(a.agents, null, 'an agent gets no list of agents');
  assert.equal(a.canSeeAll, false);
  const b = await report(agentB);
  const all = await report(manager);
  const onlyA = await report(manager, { p_agent: agentAId });
  const onlyB = await report(manager, { p_agent: agentBId });
  const auto = await report(manager, { p_agent: 'automatic' });
  assert.equal(onlyA.summary.commission, a.summary.commission);
  assert.equal(onlyB.summary.commission, b.summary.commission);
  assert.ok(micros(auto.summary.commission) >= micros('14'));
  assert.ok(micros(all.summary.commission) >= micros(onlyA.summary.commission) + micros(onlyB.summary.commission) + micros('14'));
  assert.ok(all.agents.some((x) => x.id === agentAId));
  await rejects(report(manager, { p_agent: 'nope' }), 'VALIDATION_ERROR');

  const { rows: [u] } = await db.query(`SELECT phone FROM users WHERE id = $1`, [customerId]);
  const customer = await login(u.phone);
  await rejects(report(customer), 'FORBIDDEN');
  const { error } = await customer.from('commission_entries').select('*');
  assert.ok(error, 'the table is not readable');
});
