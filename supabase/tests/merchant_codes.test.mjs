// Merchant payment codes for mobile-money deposits
// (migrations/*_merchant_codes.sql): off by default, nothing changes for
// customers until management switches a method on. Needs the local stack only.

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
async function login(phone) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: PASSWORD });
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

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
const number = (prefix) => `${prefix}${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
async function newCustomer(local) {
  const phone = `252${local}`;
  await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Merchant Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id) SELECT id FROM u`, [phone, PASSWORD]);
  return login(phone);
}
const deposit = (c, method, amount, phone) => rpc(c, 'customer_create_deposit', {
  p_method: method, p_amount: String(amount), p_phone_number: phone, p_idempotency_key: randomUUID() });
const methodOf = (list, m) => list.find((x) => x.method === m);
const status = async (id) => (await db.query('SELECT status, via_merchant FROM orders WHERE id = $1', [id])).rows[0];

let manager;
before(async () => {
  manager = await login('252610000002');
});
after(async () => {
  await db.query(`UPDATE payment_methods SET merchant_ussd_enabled = false WHERE kind = 'mobile_money'`);
  await db.end();
});

test('off by default: customers get no merchant code; management sees the three codes', async () => {
  const c = await newCustomer(number('61'));
  const list = await rpc(c, 'customer_payment_methods');
  for (const m of ['evc_plus', 'golis', 'telesom']) assert.equal(methodOf(list, m).merchantUssd, null, m);
  const settings = await rpc(manager, 'manage_payment_methods');
  assert.deepEqual(['evc_plus', 'golis', 'telesom'].map((m) => [methodOf(settings, m).merchantUssd, methodOf(settings, m).merchantUssdEnabled]), [
    ['*789*090353102*{amount}#', false],
    ['*884*353102*{amount}#', false],
    ['*883*090353102*{amount}#', false],
  ]);
});

test('switched off, an EVC Plus deposit is the normal one: not merchant, expires after 30 minutes', async () => {
  const local = number('61');
  const c = await newCustomer(local);
  const d = await deposit(c, 'evc_plus', 2, local);
  assert.equal((await status(d.id)).via_merchant, false);
  await db.query(`UPDATE orders SET created_at = now() - interval '31 minutes' WHERE id = $1`, [d.id]);
  await db.query('SELECT private.expire_unpaid_deposits()');
  assert.equal((await status(d.id)).status, 'expired');
});

test('switched on for Golis: customers get its code, deposits wait 24 hours for an agent', async () => {
  await rpc(manager, 'manage_set_merchant_ussd', { p_method: 'golis', p_code: '*884*353102*{amount}#', p_enabled: true });
  const local = number('90');
  const c = await newCustomer(local);
  const list = await rpc(c, 'customer_payment_methods');
  assert.equal(methodOf(list, 'golis').merchantUssd, '*884*353102*{amount}#');
  assert.equal(methodOf(list, 'evc_plus').merchantUssd, null, 'EVC Plus untouched');

  const d = await deposit(c, 'golis', 5, local);
  assert.equal((await status(d.id)).via_merchant, true);
  await db.query(`UPDATE orders SET created_at = now() - interval '2 hours' WHERE id = $1`, [d.id]);
  await db.query('SELECT private.expire_unpaid_deposits()');
  assert.equal((await status(d.id)).status, 'pending', 'still waiting for the agent');
  await db.query(`UPDATE orders SET created_at = now() - interval '25 hours' WHERE id = $1`, [d.id]);
  await db.query('SELECT private.expire_unpaid_deposits()');
  assert.equal((await status(d.id)).status, 'expired');

  // Switched off again: new deposits are normal ones; the change is audited.
  await rpc(manager, 'manage_set_merchant_ussd', { p_method: 'golis', p_code: '*884*353102*{amount}#', p_enabled: false });
  const d2 = await deposit(c, 'golis', 3, local);
  assert.equal((await status(d2.id)).via_merchant, false);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'payment_method.merchant_ussd' AND entity_id = 'golis'`);
  assert.ok(rows[0].n >= 2);
});

test('checked: written like *789*NUMBER*{amount}#, a code before switching on, mobile money only, managers only', async () => {
  const bad = async (args, re) => {
    const { error } = await manager.rpc('manage_set_merchant_ussd', args);
    assert.match(error.message, re);
  };
  await bad({ p_method: 'evc_plus', p_code: '*789*090353102*5#', p_enabled: false }, /Write the code like/);
  await bad({ p_method: 'evc_plus', p_code: '', p_enabled: true }, /before switching it on/);
  await bad({ p_method: 'melbet', p_code: '*1*2*{amount}#', p_enabled: true }, /only for mobile money/);
  const c = await newCustomer(number('61'));
  const { error } = await c.rpc('manage_set_merchant_ussd', { p_method: 'evc_plus', p_code: '*789*1*{amount}#', p_enabled: true });
  assert.ok(error, 'customers cannot change it');
  const { rows } = await db.query(`SELECT merchant_ussd, merchant_ussd_enabled FROM payment_methods WHERE method = 'evc_plus'`);
  assert.deepEqual(rows[0], { merchant_ussd: '*789*090353102*{amount}#', merchant_ussd_enabled: false }, 'unchanged');
});
