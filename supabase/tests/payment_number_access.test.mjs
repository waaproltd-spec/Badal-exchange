// Payment-number authorization (migrations/*_payment_number_access.sql): only a
// customer an admin authorized may deposit from / withdraw to another phone
// number on EVC Plus, Golis, ZAAD and eDahab; everyone else keeps the
// registered-number rule; the admin sees and manages the numbers and can
// revoke at any time. Run with the other suites: npm test.
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
async function rejects(promise, code) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `expected ${code}, got ${e.code}: ${e.message}`);
    return true;
  });
}

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
let manager;
const local = () => `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
let amount = 3;
const nextAmount = () => String(amount++);

async function customer() {
  const number = local();
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Number Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, 1000000 FROM u RETURNING customer_id`,
    [`252${number}`, PASSWORD]);
  return { c: await login(`252${number}`), number, id: u.customer_id };
}
const deposit = (cu, method, phone) => rpc(cu.c, 'customer_create_deposit', {
  p_method: method, p_amount: nextAmount(), p_phone_number: phone, p_idempotency_key: randomUUID() });
const withdraw = (cu, method, phone) => rpc(cu.c, 'customer_create_withdrawal', {
  p_method: method, p_amount: nextAmount(), p_phone_number: phone, p_idempotency_key: randomUUID() });
const orderPhone = async (o) => (await db.query(`SELECT phone_number FROM orders WHERE id = $1`, [o.id])).rows[0].phone_number;
const grant = (cu, methods = null) => rpc(manager, 'manage_set_payment_number_access', {
  p_customer_id: cu.id, p_enabled: true, p_methods: methods, p_note: 'test' });
const revoke = (cu) => rpc(manager, 'manage_set_payment_number_access', { p_customer_id: cu.id, p_enabled: false });
const numbers = (cu) => rpc(manager, 'manage_customer_payment_numbers', { p_customer_id: cu.id });

before(async () => { manager = await login('252610000002'); });
after(() => db.end());

test('without permission nothing changes: the registered number only, another is refused', async () => {
  const cu = await customer();
  const other = `252${local()}`;
  await rejects(deposit(cu, 'evc_plus', other), 'PHONE_NOT_OWN');
  await rejects(withdraw(cu, 'golis', other), 'PHONE_NOT_OWN');
  const own = await deposit(cu, 'evc_plus', `252${cu.number}`);
  assert.equal(await orderPhone(own), `252${cu.number}`);
  const noPhone = await deposit(cu, 'edahab', null);
  assert.equal(await orderPhone(noPhone), `252${cu.number}`);
  assert.deepEqual(await rpc(cu.c, 'customer_payment_numbers'), { allowed: false, methods: [], numbers: [] });
  await rejects(rpc(cu.c, 'customer_add_payment_number', { p_method: 'evc_plus', p_phone: other }), 'PAYMENT_NUMBER_NOT_ALLOWED');
  assert.equal((await numbers(cu)).numbers.length, 0, 'nothing was registered');
});

test('an authorized customer deposits from, and withdraws to, a new number; the admin sees it', async () => {
  const cu = await customer();
  await rejects(deposit(cu, 'evc_plus', `252${local()}`), 'PHONE_NOT_OWN');
  const access = await grant(cu);
  assert.equal(access.enabled, true);
  assert.deepEqual([...access.methods].sort(), ['edahab', 'evc_plus', 'golis', 'telesom']);

  const sendFrom = local();
  const d = await deposit(cu, 'evc_plus', `0${sendFrom}`); // typed the local way
  assert.equal(await orderPhone(d), `252${sendFrom}`, 'the order is for the number the money comes from');
  const payTo = local();
  const w = await withdraw(cu, 'telesom', `252${payTo}`);
  assert.equal(await orderPhone(w), `252${payTo}`, 'a withdrawal is paid to the new number');

  const mine = await rpc(cu.c, 'customer_payment_numbers');
  assert.equal(mine.allowed, true);
  assert.deepEqual(mine.numbers.map((x) => [x.method, x.phone]).sort(), [['evc_plus', `252${sendFrom}`], ['telesom', `252${payTo}`]]);

  const seen = await numbers(cu);
  assert.equal(seen.access.enabled, true);
  const row = seen.numbers.find((x) => x.phone === `252${sendFrom}`);
  assert.deepEqual([row.method, row.addedBy, row.uses, row.blocked], ['evc_plus', 'customer', 1, false]);
  await deposit(cu, 'evc_plus', `252${sendFrom}`);
  assert.equal((await numbers(cu)).numbers.find((x) => x.phone === `252${sendFrom}`).uses, 2, 'used again, not registered twice');
  assert.equal((await numbers(cu)).numbers.length, 2);

  const list = await rpc(manager, 'manage_payment_number_customers', { p_query: cu.number, p_filter: 'authorized' });
  const entry = list.customers.find((x) => x.id === cu.id);
  assert.deepEqual([entry.enabled, entry.numberCount], [true, 2]);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'payment_numbers.grant' AND entity_id = $1`, [cu.id]);
  assert.equal(rows[0].n, 1);
});

test('the customer can save a number first; the permission is per network', async () => {
  const cu = await customer();
  await grant(cu, ['zaad', 'edahab']);
  const saved = await rpc(cu.c, 'customer_add_payment_number', { p_method: 'zaad', p_phone: `252${local()}`, p_label: 'Work' });
  assert.equal(saved.method, 'telesom');
  await rejects(rpc(cu.c, 'customer_add_payment_number', { p_method: 'evc_plus', p_phone: `252${local()}` }), 'PAYMENT_NUMBER_NOT_ALLOWED');
  await rejects(deposit(cu, 'evc_plus', `252${local()}`), 'PHONE_NOT_OWN');
  await rejects(withdraw(cu, 'golis', `252${local()}`), 'PHONE_NOT_OWN');
  await deposit(cu, 'edahab', `252${local()}`);
  await rejects(rpc(manager, 'manage_set_payment_number_access', { p_customer_id: cu.id, p_enabled: true, p_methods: ['paypal'] }), 'VALIDATION_ERROR');
  await rejects(rpc(cu.c, 'customer_add_payment_number', { p_method: 'zaad', p_phone: '12345' }), 'VALIDATION_ERROR');
});

test('revoked at any time: back to the registered number, the numbers stay on file; granted again, they work', async () => {
  const cu = await customer();
  await grant(cu);
  const phone = `252${local()}`;
  await deposit(cu, 'golis', phone);
  const revoked = await revoke(cu);
  assert.equal(revoked.enabled, false);
  assert.ok(revoked.revokedAt);
  await rejects(deposit(cu, 'golis', phone), 'PHONE_NOT_OWN');
  await rejects(withdraw(cu, 'golis', phone), 'PHONE_NOT_OWN');
  assert.equal((await rpc(cu.c, 'customer_payment_numbers')).allowed, false);
  assert.equal(await orderPhone(await deposit(cu, 'golis', `252${cu.number}`)), `252${cu.number}`, 'the registered number still works');
  const seen = await numbers(cu);
  assert.equal(seen.access.enabled, false);
  assert.equal(seen.numbers.length, 1, 'kept for the admin');
  const list = await rpc(manager, 'manage_payment_number_customers', { p_query: cu.number, p_filter: 'revoked' });
  assert.ok(list.customers.find((x) => x.id === cu.id));

  await grant(cu);
  assert.equal(await orderPhone(await deposit(cu, 'golis', phone)), phone);
});

test('the admin adds, blocks, unblocks and removes a number', async () => {
  const cu = await customer();
  await grant(cu);
  const phone = `252${local()}`;
  const added = await rpc(manager, 'manage_add_payment_number', { p_customer_id: cu.id, p_method: 'edahab', p_phone: phone, p_label: 'Wife' });
  assert.equal((await numbers(cu)).numbers.find((x) => x.id === added.id).addedBy, 'admin');
  assert.equal(await orderPhone(await withdraw(cu, 'edahab', phone)), phone);

  await rpc(manager, 'manage_set_payment_number_blocked', { p_number_id: added.id, p_blocked: true });
  await rejects(withdraw(cu, 'edahab', phone), 'PAYMENT_NUMBER_BLOCKED');
  await rejects(deposit(cu, 'edahab', phone), 'PAYMENT_NUMBER_BLOCKED');
  assert.equal((await rpc(cu.c, 'customer_payment_numbers')).numbers.length, 0, 'a blocked number is not offered');
  await rpc(manager, 'manage_set_payment_number_blocked', { p_number_id: added.id, p_blocked: false });
  await deposit(cu, 'edahab', phone);

  await rpc(manager, 'manage_remove_payment_number', { p_number_id: added.id });
  assert.equal((await numbers(cu)).numbers.length, 0);
  const { rows } = await db.query(
    `SELECT action FROM audit_logs WHERE entity_id = $1 AND action LIKE 'payment_numbers.%' ORDER BY created_at`, [cu.id]);
  assert.deepEqual(rows.map((r) => r.action), ['payment_numbers.grant', 'payment_numbers.add', 'payment_numbers.block', 'payment_numbers.unblock', 'payment_numbers.remove']);
});

test('another account\'s login number can be used by an authorized customer, for deposits and withdrawals; nobody else is affected', async () => {
  const a = await customer();
  const b = await customer();
  await grant(a);
  assert.equal(await orderPhone(await deposit(a, 'evc_plus', `252${b.number}`)), `252${b.number}`);
  assert.equal(await orderPhone(await withdraw(a, 'evc_plus', `252${b.number}`)), `252${b.number}`);
  await rpc(manager, 'manage_add_payment_number', { p_customer_id: a.id, p_method: 'golis', p_phone: `252${b.number}` });
  // B has no permission: still refused for A's number or anyone's.
  await rejects(withdraw(b, 'evc_plus', `252${a.number}`), 'PHONE_NOT_OWN');
  await rejects(deposit(b, 'evc_plus', `252${a.number}`), 'PHONE_NOT_OWN');
  const phone = `252${local()}`;
  await deposit(a, 'evc_plus', phone);
  await rejects(deposit(b, 'evc_plus', phone), 'PHONE_NOT_OWN');
  // Nobody but management decides.
  await rejects(rpc(a.c, 'manage_set_payment_number_access', { p_customer_id: a.id, p_enabled: true }), 'FORBIDDEN');
  await rejects(rpc(a.c, 'manage_customer_payment_numbers', { p_customer_id: a.id }), 'FORBIDDEN');
  const { error } = await a.c.from('payment_number_grants').select('*');
  assert.ok(error, 'the table is not readable');
  const { error: e2 } = await a.c.from('customer_payment_numbers').select('*');
  assert.ok(e2, 'the numbers are not readable');
});

test('the receiver name is looked up for the number the money goes to: another number only for an authorized customer', async () => {
  const a = await customer();
  const other = local();
  await rejects(rpc(a.c, 'customer_begin_receiver_lookup', { p_method: 'golis', p_phone: `252${other}` }), 'PHONE_NOT_OWN');
  assert.deepEqual(await rpc(a.c, 'customer_begin_receiver_lookup', { p_method: 'golis', p_phone: `252${a.number}` }),
    { method: 'golis', mobile: `0${a.number}` }, 'the registered number');
  assert.deepEqual(await rpc(a.c, 'customer_begin_receiver_lookup', { p_method: 'golis' }),
    { method: 'golis', mobile: `0${a.number}` }, 'no number given: as before');
  await grant(a, ['evc_plus']);
  await rejects(rpc(a.c, 'customer_begin_receiver_lookup', { p_method: 'golis', p_phone: `252${other}` }), 'PHONE_NOT_OWN');
  await grant(a);
  assert.deepEqual(await rpc(a.c, 'customer_begin_receiver_lookup', { p_method: 'golis', p_phone: `0${other}` }),
    { method: 'golis', mobile: `0${other}` });
});
