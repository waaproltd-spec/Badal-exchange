// One customer account, one phone at a time
// (migrations/*_one_phone_per_customer.sql). Each client below is a phone.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';
const db = new pg.Pool({ connectionString: DATABASE_URL });
const seed = Number(Date.now().toString().slice(-6));
let n = 0;

after(() => db.end());

async function newUser(role) {
  const phone = `252${role === 'customer' ? '61' : '62'}${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;
  const { rows } = await db.query(`INSERT INTO users (role, phone, name, password_hash)
    VALUES ($1, $2, 'One Phone', private.hash_password($3)) RETURNING id`, [role, phone, PASSWORD]);
  if (role === 'customer') await db.query('INSERT INTO wallets (customer_id, available_cents) VALUES ($1, 0)', [rows[0].id]);
  return phone;
}
/** A phone signing in the way the Customer App does. */
async function phone(number, { recordLogin = true } = {}) {
  const c = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await c.auth.signInWithPassword({ email: `${number}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  if (recordLogin) {
    const r = await c.rpc('session_profile', { p_record_login: true });
    if (r.error) throw r.error;
  }
  return c;
}
const works = async (c, fn = 'customer_wallet') => {
  const { error } = await c.rpc(fn);
  assert.equal(error, null, error?.message);
};
const replaced = async (c, fn = 'customer_wallet') => {
  const { error } = await c.rpc(fn);
  assert.ok(error, `${fn} should be refused`);
  assert.equal(error.hint ?? error.code, 'SESSION_REPLACED');
  assert.match(error.message, /another phone/);
};

test('a second phone takes over: the first is refused everywhere, then can take it back', async () => {
  const number = await newUser('customer');
  const a = await phone(number);
  await works(a);
  const b = await phone(number);
  await works(b);
  await replaced(a);
  await replaced(a, 'customer_orders');
  const { error } = await a.rpc('session_profile');
  assert.equal(error?.hint ?? error?.code, 'SESSION_REPLACED', 'the app\'s session check also sees it');

  // Logging in again on the first phone moves the account back to it.
  const a2 = await phone(number);
  await works(a2);
  await replaced(b);
});

test('signing out the other phones revokes their refresh tokens too', async () => {
  const number = await newUser('customer');
  const a = await phone(number);
  const b = await phone(number);
  const { error } = await b.auth.signOut({ scope: 'others' });
  assert.equal(error, null);
  const r = await a.auth.refreshSession();
  assert.ok(r.error, 'the old phone cannot renew its session');
  await works(b);
});

test('a phone signed in before this change keeps working until the next login', async () => {
  const number = await newUser('customer');
  const old = await phone(number, { recordLogin: false });
  await works(old);
  const fresh = await phone(number);
  await works(fresh);
  await replaced(old);
});

test('agents and managers are not limited to one phone', async () => {
  const number = await newUser('agent');
  const a = await phone(number);
  const b = await phone(number);
  await works(a, 'agent_dashboard');
  await works(b, 'agent_dashboard');
});
