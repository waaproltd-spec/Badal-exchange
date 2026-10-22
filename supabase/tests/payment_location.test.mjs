// Payment Location for 1XBET / 888STARZ deposits
// (migrations/*_payment_location.sql). Needs the local stack only.

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

async function newUser(role, responsibilities = []) {
  const phone = `${role === 'customer' ? '2526' : '2527'}${String(seed).padStart(6, '0')}${String(n++).padStart(2, '0')}`;
  const { rows } = await db.query(`INSERT INTO users (role, phone, name, password_hash)
    VALUES ($1, $2, $3, private.hash_password($4)) RETURNING id`, [role, phone, `${role} ${n}`, PASSWORD]);
  if (role === 'customer') {
    await db.query('INSERT INTO wallets (customer_id) VALUES ($1)', [rows[0].id]);
  } else {
    await db.query(`INSERT INTO agent_profiles (user_id, responsibilities) VALUES ($1, $2)
      ON CONFLICT (user_id) DO UPDATE SET responsibilities = EXCLUDED.responsibilities`, [rows[0].id, responsibilities]);
  }
  const c = createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await c.auth.signInWithPassword({ email: `${phone}@phone.baari.invalid`, password: PASSWORD });
  if (error) throw error;
  return { id: rows[0].id, c };
}

const location = (list, method) => list.find((m) => m.method === method).paymentLocation;

after(async () => {
  await db.query(`UPDATE payment_methods SET payment_city = 'Mogadishu', payment_street = 'FURAHA 5'
    WHERE method IN ('onexbet', '888starz')`);
  await db.end();
});

test('customers get Mogadishu / FURAHA 5 on 1XBET and 888STARZ, nothing on the others', async () => {
  const { c } = await newUser('customer');
  const { data, error } = await c.rpc('customer_payment_methods');
  assert.equal(error, null);
  assert.deepEqual(location(data, 'onexbet'), { city: 'Mogadishu', street: 'FURAHA 5' });
  assert.deepEqual(location(data, '888starz'), { city: 'Mogadishu', street: 'FURAHA 5' });
  for (const m of data.filter((x) => !['onexbet', '888starz'].includes(x.method))) {
    assert.equal(m.paymentLocation, null, m.method);
  }
});

test('a manager changes it (trimmed, audited) and customers see the change; empty clears', async () => {
  const manager = await newUser('agent', ['manage_settings']);
  const { data, error } = await manager.c.rpc('manage_set_payment_location',
    { p_method: '888starz', p_city: ' Hargeisa ', p_street: ' WADDADA 26 ' });
  assert.equal(error, null);
  assert.deepEqual(data.paymentLocation, { city: 'Hargeisa', street: 'WADDADA 26' });

  const settings = await manager.c.rpc('manage_payment_methods');
  assert.deepEqual(location(settings.data, '888starz'), { city: 'Hargeisa', street: 'WADDADA 26' });
  const customer = await newUser('customer');
  assert.deepEqual(location((await customer.c.rpc('customer_payment_methods')).data, '888starz'),
    { city: 'Hargeisa', street: 'WADDADA 26' });
  assert.deepEqual(location((await customer.c.rpc('customer_payment_methods')).data, 'onexbet'),
    { city: 'Mogadishu', street: 'FURAHA 5' }, 'the other company is untouched');

  const { rows } = await db.query(`SELECT before_json, after_json FROM audit_logs
    WHERE action = 'payment_method.location' AND actor_id = $1`, [manager.id]);
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].before_json, { city: 'Mogadishu', street: 'FURAHA 5' });
  assert.deepEqual(rows[0].after_json, { city: 'Hargeisa', street: 'WADDADA 26' });

  // Only a street: the city is gone; both empty: no card at all.
  await manager.c.rpc('manage_set_payment_location', { p_method: '888starz', p_city: '', p_street: 'FURAHA 5' });
  assert.deepEqual(location((await customer.c.rpc('customer_payment_methods')).data, '888starz'),
    { city: null, street: 'FURAHA 5' });
  await manager.c.rpc('manage_set_payment_location', { p_method: '888starz', p_city: ' ', p_street: null });
  assert.equal(location((await customer.c.rpc('customer_payment_methods')).data, '888starz'), null);
});

test('only managers, only 1XBET / 888STARZ, limited length', async () => {
  const manager = await newUser('agent', ['manage_settings']);
  const worker = await newUser('agent', []);
  const customer = await newUser('customer');
  const args = { p_method: 'onexbet', p_city: 'X', p_street: 'Y' };

  for (const c of [worker.c, customer.c]) {
    const { error } = await c.rpc('manage_set_payment_location', args);
    assert.match(error.message, /not allowed|Forbidden/);
  }
  let r = await manager.c.rpc('manage_set_payment_location', { ...args, p_method: 'melbet' });
  assert.match(r.error.message, /only for 1XBET, 888STARZ, WinWin and Betwinner/);
  r = await manager.c.rpc('manage_set_payment_location', { ...args, p_street: 'S'.repeat(81) });
  assert.match(r.error.message, /street/);

  const { rows } = await db.query(`SELECT payment_city, payment_street FROM payment_methods WHERE method = 'onexbet'`);
  assert.deepEqual(rows[0], { payment_city: 'Mogadishu', payment_street: 'FURAHA 5' }, 'nothing changed');
});
