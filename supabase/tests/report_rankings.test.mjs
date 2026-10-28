// Agent App Reports (migrations/*_report_rankings.sql): Today / Yesterday /
// Last Month / All Time on Mogadishu days; revenue from completed orders only;
// platform, method and user rankings that add up to it; the largest orders.
// Run with the other suites: npm test.
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
let agent;
let customerId;
const phone = `25261${seed}`.slice(0, 12);
const cents = (s) => Math.round(Number(s) * 100);
const report = (range, extra = {}) => rpc(agent, 'agent_report_overview', { p_range: range, ...extra });
let n = 0;
/** An order at Mogadishu local time `local` ('YYYY-MM-DD HH:MI'), or `ago` before now. */
async function order({ method, direction = 'deposit', status = 'completed', amount, fee = 0, ago, local }) {
  const at = local ? `(timestamp '${local}' AT TIME ZONE 'Africa/Mogadishu')` : `now() - interval '${ago ?? '1 minute'}'`;
  await db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, fee_cents, rate, net_cents,
                         wallet_delta_cents, created_at, completed_at)
     VALUES ($1, $2, $3, $4::order_method, $5::order_status, $6::bigint, $7::bigint, 1, $6::bigint - $7::bigint, 0, ${at},
             CASE WHEN $5::text = 'completed' THEN ${at} END)`,
    [`EXRP${seed}${n++}`, customerId, direction, method, status, amount, fee]);
}

before(async () => {
  agent = await login('252610000002');
  const { rows: [u] } = await db.query(
    `INSERT INTO users (role, phone, name, password_hash) VALUES ('customer', $1, 'Report Ranking Test', private.hash_password($2)) RETURNING id`,
    [phone, PASSWORD]);
  customerId = u.id;
  await db.query(`INSERT INTO wallets (customer_id, available_cents) VALUES ($1, 0)`, [customerId]);
});
after(async () => {
  await db.query(`UPDATE orders SET status = 'failed' WHERE order_code LIKE $1 AND status = 'completed'`, [`EXRP${seed}%`]);
  await db.end();
});

test('today: completed orders only make the revenue; failed, cancelled and pending are shown apart', async () => {
  const before = await report('today');
  await order({ method: 'melbet', amount: 517680, fee: 500 });           // $5,176.80
  await order({ method: 'melbet', direction: 'withdraw', amount: 1050 });
  await order({ method: 'evc_plus', amount: 2500 });
  await order({ method: 'melbet', status: 'failed', amount: 99999 });
  await order({ method: 'evc_plus', status: 'cancelled', amount: 88888 });
  await order({ method: 'evc_plus', status: 'pending', amount: 77777 });
  const r = await report('today');
  assert.equal(cents(r.overview.revenue) - cents(before.overview.revenue), 517680 + 1050 + 2500);
  assert.equal(r.overview.transactions - before.overview.transactions, 3);
  assert.equal(cents(r.overview.fees) - cents(before.overview.fees), 500);
  assert.equal(cents(r.statuses.failed.total) - cents(before.statuses?.failed?.total ?? '0'), 99999);

  // Platforms + methods add up to the revenue; so do deposits + withdrawals.
  const sum = (xs) => xs.reduce((s, x) => s + cents(x.total), 0);
  assert.equal(sum(r.platforms) + sum(r.methods), cents(r.overview.revenue));
  assert.equal(r.platforms.reduce((s, x) => s + x.count, 0) + r.methods.reduce((s, x) => s + x.count, 0), r.overview.transactions);
  assert.equal(cents(r.overview.deposits.total) + cents(r.overview.withdrawals.total), cents(r.overview.revenue));
  // Ranked by amount.
  for (const list of [r.platforms, r.methods, r.users]) {
    for (let i = 1; i < list.length; i++) assert.ok(cents(list[i - 1].total) >= cents(list[i].total), 'sorted');
  }
  assert.ok(r.platforms.every((p) => p.method !== 'evc_plus'), 'mobile money is not a platform');
  assert.ok(r.methods.some((p) => p.method === 'evc_plus'));

  // The customer's row is exactly their completed orders.
  const me = r.users.find((u) => u.customerId === customerId);
  assert.deepEqual([me.name, me.phone, me.count, me.total], ['Report Ranking Test', phone, 3, '5209.30']);
  if (r.usersCount <= 20) assert.equal(sum(r.users), cents(r.overview.revenue));
  // Largest orders: the $5,176.80 one first among ours, nothing failed.
  const biggest = r.transactions.filter((t) => t.orderCode.startsWith(`EXRP${seed}`));
  assert.equal(biggest[0].amount, '5176.80');
  assert.ok(!r.transactions.some((t) => t.amount === '999.99'));
  assert.equal(r.series.length, 1);
});

test('yesterday and last month are Mogadishu days; all time has everything', async () => {
  const { rows: [{ y }] } = await db.query(`SELECT to_char((now() AT TIME ZONE 'Africa/Mogadishu')::date - 1, 'YYYY-MM-DD') AS y`);
  const before = await report('yesterday');
  await order({ method: 'onexbet', amount: 12300, local: `${y} 23:50` });  // late yesterday in Mogadishu (20:50 UTC)
  await order({ method: 'onexbet', amount: 4500, local: `${y} 00:10` });   // early yesterday (the day before in UTC)
  const r = await report('yesterday');
  assert.equal(r.from, y);
  assert.equal(r.to, y);
  assert.equal(cents(r.overview.revenue) - cents(before.overview.revenue), 16800);

  const month = await report('last_month');
  assert.equal(month.series.length, 30);
  const today = await report('today');
  const all = await report('all_time');
  assert.equal(all.from, null);
  assert.equal(all.series, null, 'no per-day chart for all time');
  assert.ok(cents(all.overview.revenue) >= cents(month.overview.revenue));
  assert.ok(cents(month.overview.revenue) >= cents(r.overview.revenue) + cents(today.overview.revenue));

  await order({ method: 'onexbet', amount: 7000, ago: '45 days' });
  const later = await report('all_time');
  assert.equal(cents(later.overview.revenue) - cents(all.overview.revenue), 7000, 'all time counts older ones');
  assert.equal(cents((await report('last_month')).overview.revenue), cents(month.overview.revenue), 'not in the last 30 days');
});

test('a custom range is checked; customers cannot read reports', async () => {
  await rejects(report('custom', { p_from: '2026-10-10', p_to: '2026-10-01' }), 'VALIDATION_ERROR');
  await rejects(report('custom', {}), 'VALIDATION_ERROR');
  await rejects(report('weekly-ish'), 'VALIDATION_ERROR');
  const r = await report('custom', { p_from: '2026-01-01', p_to: '2026-01-02' });
  assert.equal(r.series.length, 2);
  const customer = await login(phone);
  await rejects(rpc(customer, 'agent_report_overview', { p_range: 'today' }), 'FORBIDDEN');
});
