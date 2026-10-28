// Withdrawal bonus (migrations/*_withdrawal_bonus.sql): a completed
// withdrawal earns a percentage into the Bonus balance, once; excluded
// methods, failed withdrawals and customers it is off for earn none; the
// customer moves it to the main wallet. Run with the other suites: npm test.
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
const number = (prefix) => `${prefix}${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;

let manager;
async function customer(prefix = '62', cents = 50_000) {
  const local = number(prefix);
  const { rows: [r] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Bonus Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u RETURNING customer_id`,
    [`252${local}`, PASSWORD, cents]);
  return { c: await login(`252${local}`), id: r.customer_id, local };
}
const withdraw = (cu, method, amount, extra = {}) => rpc(cu.c, 'customer_create_withdrawal', {
  p_method: method, p_amount: String(amount), p_idempotency_key: randomUUID(),
  ...(method === 'edahab' || method === 'evc_plus' ? { p_phone_number: `252${cu.local}` } : { p_account_id: '7841228' }),
  ...extra,
});
const complete = (id) => db.query(`SELECT private.complete_withdraw_order($1, 'TEST', NULL, NULL)`, [id]);
const wallet = (cu) => rpc(cu.c, 'customer_wallet');

before(async () => {
  manager = await login('252610000002');
  await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'bonus:enabled'`);
  await db.query(`UPDATE app_settings SET value = '100' WHERE key = 'bonus:default_bp'`);
});
after(() => db.end());

test('a completed eDahab withdrawal earns 1% into the bonus, once', async () => {
  const cu = await customer('62');
  const w = await withdraw(cu, 'edahab', 100);
  assert.equal((await wallet(cu)).bonusBalance, '0.00', 'nothing before it is paid');
  await complete(w.id);
  assert.equal((await wallet(cu)).bonusBalance, '1.00');
  await db.query(`UPDATE orders SET status = 'processing' WHERE id = $1`, [w.id]);
  await db.query(`UPDATE orders SET status = 'completed' WHERE id = $1`, [w.id]);
  assert.equal((await wallet(cu)).bonusBalance, '1.00', 'never twice for one withdrawal');
  const info = await rpc(cu.c, 'customer_bonus');
  assert.equal(info.rate, '1%');
  assert.deepEqual(info.excludedMethods, ['evc_plus', 'golis', 'telesom']);
  assert.equal(info.entries[0].kind, 'earned');
  assert.equal(info.entries[0].withdrawal, '100.00');
  assert.equal(info.entries[0].amount, '1.00');
});

test('EVC Plus, Golis and ZAAD earn none; a failed withdrawal earns none', async () => {
  const cu = await customer('61');
  const evc = await withdraw(cu, 'evc_plus', 50);
  await complete(evc.id);
  assert.equal((await wallet(cu)).bonusBalance, '0.00');
  const cu2 = await customer('62');
  const failed = await withdraw(cu2, 'edahab', 50);
  await rpc(manager, 'agent_withdrawal_fail', { p_order_id: failed.id, p_reason: 'test' });
  assert.equal((await wallet(cu2)).bonusBalance, '0.00');
});

test('a manager sets a customer to 2%, or turns it off; rounded down to the cent', async () => {
  const cu = await customer('62');
  const s = await rpc(manager, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_rate_bp: 200 });
  assert.equal(s.rate, '2%');
  await rejects(rpc(manager, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_rate_bp: 300 }), 'VALIDATION_ERROR');
  const w = await withdraw(cu, 'edahab', 12.34);
  await complete(w.id);
  assert.equal((await wallet(cu)).bonusBalance, '0.24', '2% of 12.34 = 0.2468, rounded down');
  await rpc(manager, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_enabled: false });
  const w2 = await withdraw(cu, 'edahab', 50);
  await complete(w2.id);
  assert.equal((await wallet(cu)).bonusBalance, '0.24', 'off: nothing more');
  assert.equal((await rpc(manager, 'manage_customer_bonus', { p_customer_id: cu.id })).enabled, false);
  await rejects(rpc(cu.c, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_rate_bp: 200 }), 'FORBIDDEN');
});

test('moving the bonus: all of it to the main wallet, with a ledger credit; nothing to move is refused', async () => {
  const cu = await customer('62', 0);
  await db.query(`UPDATE wallets SET available_cents = 20000 WHERE customer_id = $1`, [cu.id]);
  const w = await withdraw(cu, 'edahab', 100);
  await complete(w.id);
  const before = await wallet(cu);
  const r = await rpc(cu.c, 'customer_move_bonus');
  assert.equal(r.moved, '1.00');
  const after = await wallet(cu);
  assert.equal(after.bonusBalance, '0.00');
  assert.equal(Number(after.availableBalance), Number(before.availableBalance) + 1);
  const { rows } = await db.query(`SELECT entry_type, amount_cents FROM ledger_entries l JOIN wallets w ON w.id = l.wallet_id
                                   WHERE w.customer_id = $1 AND l.reason = 'Bonus moved to main wallet'`, [cu.id]);
  assert.deepEqual(rows, [{ entry_type: 'credit', amount_cents: '100' }]);
  await rejects(rpc(cu.c, 'customer_move_bonus'), 'NO_BONUS');
  assert.equal((await rpc(cu.c, 'customer_bonus')).entries[0].kind, 'moved');
});

test('the programme switched off: nobody earns', async () => {
  await db.query(`UPDATE app_settings SET value = 'off' WHERE key = 'bonus:enabled'`);
  try {
    const cu = await customer('62');
    const w = await withdraw(cu, 'edahab', 100);
    await complete(w.id);
    assert.equal((await wallet(cu)).bonusBalance, '0.00');
  } finally {
    await db.query(`UPDATE app_settings SET value = 'on' WHERE key = 'bonus:enabled'`);
  }
});

test('Withdraw Confirm preview: the bonus a withdrawal will earn, none for excluded methods', async () => {
  const cu = await customer('62');
  assert.deepEqual(await rpc(cu.c, 'customer_bonus_preview', { p_method: 'edahab', p_amount: '250' }),
    { rate: '1%', amount: '2.50' });
  assert.equal(await rpc(cu.c, 'customer_bonus_preview', { p_method: 'evc_plus', p_amount: '250' }), null);
  assert.equal(await rpc(cu.c, 'customer_bonus_preview', { p_method: 'edahab', p_amount: '0.50' }), null, 'under a cent');
});

test('receiver name lookup: only Golis, ZAAD and EVC Plus, always the customer\'s own number', async () => {
  const cu = await customer('63');
  assert.deepEqual(await rpc(cu.c, 'customer_begin_receiver_lookup', { p_method: 'telesom' }),
    { method: 'telesom', mobile: `0${cu.local}` });
  await rejects(rpc(cu.c, 'customer_begin_receiver_lookup', { p_method: 'edahab' }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'customer_begin_receiver_lookup', { p_method: 'golis' }), 'FORBIDDEN');
});
