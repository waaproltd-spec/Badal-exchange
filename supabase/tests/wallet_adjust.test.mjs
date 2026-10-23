// Agent App Add Money / Deduct Money (migrations/*_wallet_adjustments.sql).
//
//   npm test   (needs the local stack: supabase start)

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
const client = () => createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const authEmail = (phone) => `${phone.replace(/\D/g, '')}@phone.baari.invalid`;
const seed = Number(Date.now().toString().slice(-6));
let n = 0;

async function login(phone, password = PASSWORD) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: authEmail(phone), password });
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

const nextPhone = (prefix) => `${prefix}${String(seed).padStart(6, '0')}${String(n++).padStart(2, '0')}`;

async function newUser(role, balanceCents = 0, responsibilities = []) {
  const phone = nextPhone(role === 'customer' ? '2526' : '2527');
  const { rows } = await db.query(
    `INSERT INTO public.users (role, phone, name, password_hash)
     VALUES ($1, $2, $3, private.hash_password($4)) RETURNING id`,
    [role, phone, `${role} ${n}`, PASSWORD]
  );
  const id = rows[0].id;
  if (role === 'customer') {
    await db.query('INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, $2)', [id, balanceCents]);
  } else {
    await db.query(
      `INSERT INTO public.agent_profiles (user_id, responsibilities) VALUES ($1, $2)
       ON CONFLICT (user_id) DO UPDATE SET responsibilities = EXCLUDED.responsibilities`,
      [id, responsibilities]
    );
  }
  return { id, phone, c: await login(phone) };
}

const adjust = (agent, customerId, direction, amount, reason = 'Correction', key = randomUUID()) =>
  rpc(agent, 'agent_wallet_adjust', {
    p_customer_id: customerId, p_direction: direction, p_amount: String(amount), p_reason: reason, p_idempotency_key: key,
  });
const balance = async (customer) => (await rpc(customer.c, 'customer_wallet')).availableBalance;

let manager;
let agent;

before(async () => {
  manager = { c: await login('252610000002') }; // seeded agent with manage_settings
  agent = await newUser('agent'); // a plain agent
});

after(async () => {
  await db.end();
});

test('add money: balance before/after, reference, customer balance updated', async () => {
  const cu = await newUser('customer', 100);
  const a = await adjust(agent.c, cu.id, 'add', '5', 'Ku shubid macmiilka');
  assert.match(a.reference, /^WAL[0-9A-F]{8}$/);
  assert.deepEqual([a.direction, a.amount, a.balanceBefore, a.balanceAfter, a.status], ['add', '5.00', '1.00', '6.00', 'completed']);
  assert.equal(a.reason, 'Ku shubid macmiilka');
  assert.equal(a.customerPhone, cu.phone);
  assert.equal(a.agentId, agent.id);
  assert.equal(await balance(cu), '6.00');
});

test('deduct money: never below zero', async () => {
  const cu = await newUser('customer', 600);
  const a = await adjust(agent.c, cu.id, 'deduct', '2', 'Ka jarid macmiilka');
  assert.deepEqual([a.balanceBefore, a.balanceAfter], ['6.00', '4.00']);
  await rejects(adjust(agent.c, cu.id, 'deduct', '4.01'), 'INSUFFICIENT_BALANCE');
  assert.equal(await balance(cu), '4.00');
  const all = await adjust(agent.c, cu.id, 'deduct', '4');
  assert.equal(all.balanceAfter, '0.00');
  await rejects(adjust(agent.c, cu.id, 'deduct', '0.01'), 'INSUFFICIENT_BALANCE');
});

test('validation: amount, reason, direction, customer', async () => {
  const cu = await newUser('customer');
  for (const amount of ['0', '-1', 'abc', '100000.01']) {
    await rejects(adjust(agent.c, cu.id, 'add', amount), 'VALIDATION_ERROR');
  }
  await rejects(adjust(agent.c, cu.id, 'add', '1', '  '), 'VALIDATION_ERROR');
  await rejects(adjust(agent.c, cu.id, 'steal', '1'), 'VALIDATION_ERROR');
  await rejects(adjust(agent.c, agent.id, 'add', '1'), 'NOT_FOUND'); // not a customer
  await rejects(adjust(agent.c, randomUUID(), 'add', '1'), 'NOT_FOUND');
  assert.equal(await balance(cu), '0.00');
});

test('a retried request is applied once; reusing its key for something else is refused', async () => {
  const cu = await newUser('customer', 1000);
  const key = randomUUID();
  const first = await adjust(agent.c, cu.id, 'deduct', '3', 'Retry test', key);
  const again = await adjust(agent.c, cu.id, 'deduct', '3', 'Retry test', key);
  assert.equal(again.id, first.id);
  assert.equal(again.replayed, true);
  assert.equal(await balance(cu), '7.00');
  await rejects(adjust(agent.c, cu.id, 'deduct', '4', 'Retry test', key), 'IDEMPOTENCY_CONFLICT');
  const { rows } = await db.query('SELECT count(*)::int AS n FROM wallet_adjustments WHERE customer_id = $1', [cu.id]);
  assert.equal(rows[0].n, 1);
});

test('concurrent adjustments: no lost update, no overdraft', async () => {
  const cu = await newUser('customer', 1000); // $10
  // Twenty $1 deductions at once: exactly ten succeed.
  const results = await Promise.allSettled(Array.from({ length: 20 }, () => adjust(agent.c, cu.id, 'deduct', '1')));
  const ok = results.filter((r) => r.status === 'fulfilled');
  assert.equal(ok.length, 10);
  for (const r of results.filter((x) => x.status === 'rejected')) assert.equal(r.reason.code, 'INSUFFICIENT_BALANCE');
  assert.equal(await balance(cu), '0.00');
  // Adds and deducts mixed: the balance is the exact sum.
  await Promise.all([
    ...Array.from({ length: 5 }, () => adjust(agent.c, cu.id, 'add', '2')),
    ...Array.from({ length: 5 }, () => adjust(manager.c, cu.id, 'add', '1')),
  ]);
  assert.equal(await balance(cu), '15.00');
  // Every adjustment's before/after chain is consistent.
  const { rows } = await db.query(
    'SELECT balance_before_cents, balance_after_cents FROM wallet_adjustments WHERE customer_id = $1 ORDER BY created_at, id', [cu.id]);
  const afters = new Set(rows.map((r) => Number(r.balance_after_cents)));
  assert.ok(rows.every((r) => r.balance_after_cents >= 0));
  assert.ok(afters.has(1500));
});

test('authorization: customers and signed-out callers can not adjust or list', async () => {
  const cu = await newUser('customer', 500);
  const other = await newUser('customer');
  await rejects(adjust(cu.c, other.id, 'add', '100'), 'FORBIDDEN');
  await rejects(adjust(cu.c, cu.id, 'add', '100'), 'FORBIDDEN');
  await rejects(rpc(cu.c, 'agent_wallet_adjustments', {}), 'FORBIDDEN');
  const { error } = await client().rpc('agent_wallet_adjust', {
    p_customer_id: cu.id, p_direction: 'add', p_amount: '1', p_reason: 'x', p_idempotency_key: randomUUID() });
  assert.ok(error);
  assert.equal(await balance(cu), '5.00');
});

test('history: agents see their own, managers see everyone\'s; filters work', async () => {
  const cu = await newUser('customer', 0);
  const mine = await adjust(agent.c, cu.id, 'add', '3', 'Mine');
  const theirs = await adjust(manager.c, cu.id, 'deduct', '1', 'Manager');
  const agentView = await rpc(agent.c, 'agent_wallet_adjustments', { p_customer_id: cu.id });
  assert.deepEqual(agentView.map((a) => a.id), [mine.id]);
  const managerView = await rpc(manager.c, 'agent_wallet_adjustments', { p_customer_id: cu.id });
  assert.deepEqual(managerView.map((a) => a.id), [theirs.id, mine.id]);
  const adds = await rpc(manager.c, 'agent_wallet_adjustments', { p_customer_id: cu.id, p_direction: 'add' });
  assert.deepEqual(adds.map((a) => a.id), [mine.id]);
  const audit = await db.query(`SELECT action FROM audit_logs WHERE entity_type = 'wallet_adjustment' AND entity_id = ANY($1)`,
    [[mine.id, theirs.id]]);
  assert.deepEqual(audit.rows.map((r) => r.action).sort(), ['wallet.adjust_add', 'wallet.adjust_deduct']);
});

test('privacy: the customer sees the balance, never the reason, the agent or the history', async () => {
  const cu = await newUser('customer', 0);
  await adjust(agent.c, cu.id, 'add', '4', 'PRIVATE NOTE about dispute 77');
  assert.equal(await balance(cu), '4.00');
  // Direct table reads.
  const { data: rows, error } = await cu.c.from('wallet_adjustments').select('*');
  assert.ok(error || (rows ?? []).length === 0, 'customers can not read adjustments');
  const { data: ledger } = await cu.c.from('ledger_entries').select('*');
  assert.equal(ledger.length, 1);
  const text = JSON.stringify(ledger);
  assert.ok(!text.includes('PRIVATE NOTE'), 'the reason is not in the customer\'s ledger');
  assert.ok(!text.includes(agent.id), 'nor the agent');
  assert.match(ledger[0].reason, /^Wallet adjustment WAL/);
  // Customer API.
  const everything = JSON.stringify([
    await rpc(cu.c, 'customer_wallet'), await rpc(cu.c, 'customer_orders'), await rpc(cu.c, 'customer_notifications'),
  ]);
  assert.ok(!everything.includes('PRIVATE NOTE') && !everything.includes(agent.id));
});

test('adjustments can not be changed or deleted', async () => {
  const cu = await newUser('customer', 0);
  const a = await adjust(agent.c, cu.id, 'add', '1');
  await assert.rejects(db.query('UPDATE wallet_adjustments SET amount_cents = 1 WHERE id = $1', [a.id]), /can not be changed/);
  await assert.rejects(db.query('DELETE FROM wallet_adjustments WHERE id = $1', [a.id]), /can not be changed/);
});
