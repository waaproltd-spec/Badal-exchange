// Agent App Dashboard figures (agent_dashboard_stats): money per status,
// customers, the 7-day chart, top services and deposit methods.
// Run with the other suites: npm test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
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

let agent;
before(async () => {
  agent = await login('252610000002');
});
after(() => db.end());

test('dashboard figures: amounts, customers, seven days, top lists', async () => {
  const s = await rpc(agent, 'agent_dashboard_stats');
  for (const k of ['pendingDeposits', 'pendingWithdrawals', 'processing', 'completed', 'failed']) {
    assert.match(s.amounts[k], /^\d+\.\d\d$/, k);
  }
  assert.ok(s.totalCustomers >= s.newCustomersThisMonth);
  assert.equal(s.days.length, 7);
  assert.equal(s.days[6].day, s.day, 'the chart ends on the chosen day');
  for (const d of s.days) assert.ok(d.deposits >= 0 && d.withdrawals >= 0 && d.orders >= 0);
  assert.ok(Array.isArray(s.topServices) && s.topServices.length <= 5);
  assert.ok(Array.isArray(s.topDepositMethods) && s.topDepositMethods.length <= 5);
});

test('a new customer and a completed deposit show up', async () => {
  const before = await rpc(agent, 'agent_dashboard_stats');
  const number = `61${String(Date.now()).slice(-7)}`;
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Dashboard Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id) SELECT id FROM u RETURNING customer_id`, [`252${number}`, PASSWORD]);
  const c = await login(`252${number}`);
  const d = await rpc(c, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '3', p_phone_number: `252${number}`, p_idempotency_key: randomUUID() });
  await db.query(`UPDATE orders SET status = 'completed', completed_at = now() WHERE id = $1`, [d.id]);
  const after = await rpc(agent, 'agent_dashboard_stats');
  assert.ok(after.totalCustomers >= before.totalCustomers + 1, 'other suites may add customers too');
  assert.ok(after.days[6].deposits >= before.days[6].deposits + 1);
  assert.ok(after.topDepositMethods.some((m) => m.method === 'evc_plus'));
  await db.query('DELETE FROM orders WHERE id = $1', [d.id]).catch(() => {});
  assert.ok(u.customer_id);
});

test('an earlier day; only staff may see it', async () => {
  const s = await rpc(agent, 'agent_dashboard_stats', { p_day: '2026-10-01' });
  assert.equal(s.day, '2026-10-01');
  assert.equal(s.days[0].day, '2026-09-25');
  const number = `61${String(Date.now() + 7).slice(-7)}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Dashboard Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id) SELECT id FROM u`, [`252${number}`, PASSWORD]);
  const c = await login(`252${number}`);
  await assert.rejects(rpc(c, 'agent_dashboard_stats'));
});

test('Users overview: totals all time, new customers in the period', async () => {
  const today = await rpc(agent, 'agent_customer_overview');
  assert.equal(today.total, today.active + today.blocked);
  assert.ok(today.new <= today.total);
  const number = `61${String(Date.now() + 13).slice(-7)}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Overview Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id) SELECT id FROM u`, [`252${number}`, PASSWORD]);
  const after = await rpc(agent, 'agent_customer_overview');
  assert.ok(after.total >= today.total + 1, 'other suites may add customers too');
  assert.ok(after.new >= today.new + 1, 'joined today');
  const old = await rpc(agent, 'agent_customer_overview', { p_from: '2026-01-01', p_to: '2026-01-02' });
  assert.equal(old.total, after.total, 'totals are all time');
  await assert.rejects(rpc(agent, 'agent_customer_overview', { p_from: '2026-02-02', p_to: '2026-02-01' }));
});
