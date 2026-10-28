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
  assert.ok(await c('last_3_months') >= micros('2') + micros('4'));
  assert.equal(await c('last_6_months') - await c('last_3_months'), micros('8'));
  assert.equal(await c('last_1_year') - await c('last_6_months'), 0);
  assert.equal(await c('all_time') - await c('last_1_year'), micros('16'));
  assert.ok(await c('this_month') <= await c('last_3_months'));
  const { rows: [{ d }] } = await db.query(`SELECT to_char((now() - interval '50 days') AT TIME ZONE 'Africa/Mogadishu', 'YYYY-MM-DD') AS d`);
  assert.equal(await c('custom', { p_from: d, p_to: d }), micros('4'));
  await rejects(report(agentB, { p_range: 'custom', p_from: '2026-10-10', p_to: '2026-10-01' }), 'VALIDATION_ERROR');
  await rejects(report(agentB, { p_range: 'forever' }), 'VALIDATION_ERROR');
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
