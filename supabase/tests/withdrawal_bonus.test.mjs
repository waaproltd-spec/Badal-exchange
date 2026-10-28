// Bonus system (migrations/*_withdrawal_bonus.sql, *_bonus_wallet.sql): a
// completed order of a type the manager made eligible earns a percentage,
// exactly (micro-dollars), once, into the separate bonus wallet; the customer
// transfers it to the main wallet. Run with the other suites: npm test.
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

const EVERY_WITHDRAWAL_BUT = (skip) => ['edahab', 'onexbet', 'melbet', 'winwin', 'betwinner', 'dbbet', '888starz', 'betjam', 'betongame',
  'evc_plus', 'golis', 'telesom'].filter((m) => !skip.includes(m)).map((m) => `withdraw:${m}`);
const DEFAULT_ELIGIBLE = EVERY_WITHDRAWAL_BUT(['evc_plus', 'golis', 'telesom']);
const settings = (args) => rpc(manager, 'manage_set_bonus_settings', args);

let code = 0;
/** An order straight in the table (as a payment worker leaves it), pending first. */
async function order(cu, direction, method, cents, status = 'pending') {
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
     VALUES ($1, $2, $3::order_direction, $4::order_method, $5::order_status, $6, 1, $6, 0) RETURNING id`,
    [`EXBN${seed}${code++}`, cu.id, direction, method, status, cents]);
  return o.id;
}
const setStatus = (id, status) => db.query(
  `UPDATE orders SET status = $2::order_status, completed_at = CASE WHEN $2::text = 'completed' THEN now() END WHERE id = $1`,
  [id, status]);

before(async () => {
  manager = await login('252610000002');
  await settings({ p_enabled: true, p_default_bp: 100, p_eligible: DEFAULT_ELIGIBLE });
});
after(async () => {
  await settings({ p_enabled: true, p_default_bp: 100, p_eligible: DEFAULT_ELIGIBLE }).catch(() => {});
  // Orders made here never reserved money: none may stay open for the payout queue.
  await db.query(`UPDATE orders SET status = 'failed' WHERE order_code LIKE 'EXBN%' AND status IN ('pending', 'processing')`);
  await db.end();
});

test('a completed eDahab withdrawal earns 1% into the bonus wallet, once', async () => {
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
  assert.equal(info.totalEarned, '1.00');
  assert.equal(info.entries[0].kind, 'earned');
  assert.equal(info.entries[0].orderAmount, '100.00');
  assert.equal(info.entries[0].direction, 'withdraw');
  assert.equal(info.entries[0].rate, '1%');
  assert.equal(info.entries[0].amount, '1.00');
  assert.ok(info.eligibleTypes.some((t) => t.direction === 'withdraw' && t.method === 'edahab'));
});

test('1. $0.30 at 2% earns exactly $0.006', async () => {
  const cu = await customer('62');
  await settings({ p_default_bp: 200 });
  try {
    const id = await order(cu, 'withdraw', '888starz', 30);
    await setStatus(id, 'completed');
    const info = await rpc(cu.c, 'customer_bonus');
    assert.equal(info.balance, '0.006');
    assert.equal(info.totalEarned, '0.006');
    assert.equal(info.entries[0].amount, '0.006');
    assert.equal(info.entries[0].rate, '2%');
    // Three more make $0.024: nothing lost to rounding.
    for (let i = 0; i < 3; i++) await setStatus(await order(cu, 'withdraw', '888starz', 30), 'completed');
    assert.equal((await rpc(cu.c, 'customer_bonus')).balance, '0.024');
  } finally {
    await settings({ p_default_bp: 100 });
  }
});

test('3. the bonus never changes the Available Balance until it is transferred', async () => {
  const cu = await customer('62', 500);
  const before = await wallet(cu);
  await setStatus(await order(cu, 'withdraw', 'edahab', 10_000), 'completed');
  const after = await wallet(cu);
  assert.equal(after.bonusBalance, '1.00');
  assert.equal(after.availableBalance, before.availableBalance);
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM ledger_entries l JOIN wallets w ON w.id = l.wallet_id
                                   WHERE w.customer_id = $1 AND l.reason = 'Bonus moved to main wallet'`, [cu.id]);
  assert.equal(rows[0].n, 0);
});

test('5. pending, processing and failed orders earn nothing; a completed one does', async () => {
  const cu = await customer('62');
  const id = await order(cu, 'withdraw', 'edahab', 5_000);
  await setStatus(id, 'processing');
  await setStatus(id, 'failed');
  assert.equal((await wallet(cu)).bonusBalance, '0.00');
  const failed = await withdraw(cu, 'edahab', 50);
  await rpc(manager, 'agent_withdrawal_fail', { p_order_id: failed.id, p_reason: 'test' });
  assert.equal((await wallet(cu)).bonusBalance, '0.00');
  await setStatus(await order(cu, 'withdraw', 'edahab', 5_000), 'completed');
  assert.equal((await wallet(cu)).bonusBalance, '0.50');
});

test('6. ZAAD, Golis and EVC Plus withdrawals earn nothing until a manager enables them', async () => {
  const cu = await customer('63');
  await setStatus(await order(cu, 'withdraw', 'telesom', 10_000), 'completed');
  await setStatus(await order(cu, 'withdraw', 'golis', 10_000), 'completed');
  await setStatus(await order(cu, 'withdraw', 'evc_plus', 10_000), 'completed');
  assert.equal((await wallet(cu)).bonusBalance, '0.00');
  await settings({ p_eligible: [...DEFAULT_ELIGIBLE, 'withdraw:telesom'] });
  try {
    await setStatus(await order(cu, 'withdraw', 'telesom', 10_000), 'completed');
    assert.equal((await wallet(cu)).bonusBalance, '1.00', 'ZAAD once enabled');
    await setStatus(await order(cu, 'withdraw', 'golis', 10_000), 'completed');
    assert.equal((await wallet(cu)).bonusBalance, '1.00', 'Golis still off');
  } finally {
    await settings({ p_eligible: DEFAULT_ELIGIBLE });
  }
});

test('deposits earn only when their type is enabled; completed is not enough', async () => {
  const cu = await customer('62');
  await setStatus(await order(cu, 'deposit', 'edahab', 10_000), 'completed');
  await setStatus(await order(cu, 'deposit', 'melbet', 10_000), 'completed');
  assert.equal((await wallet(cu)).bonusBalance, '0.00');
  await settings({ p_eligible: [...DEFAULT_ELIGIBLE, 'deposit:melbet'] });
  try {
    await setStatus(await order(cu, 'deposit', 'melbet', 10_000), 'completed');
    assert.equal((await wallet(cu)).bonusBalance, '1.00');
    assert.equal((await rpc(cu.c, 'customer_bonus')).entries[0].direction, 'deposit');
  } finally {
    await settings({ p_eligible: DEFAULT_ELIGIBLE });
  }
});

test('8. a repeated update or webhook never credits the same order twice', async () => {
  const cu = await customer('62');
  const id = await order(cu, 'withdraw', 'edahab', 10_000);
  await Promise.all([1, 2, 3, 4].map(() => setStatus(id, 'completed')));
  await setStatus(id, 'completed');
  await db.query(`UPDATE orders SET status = 'processing' WHERE id = $1`, [id]);
  await setStatus(id, 'completed');
  await db.query(`SELECT private.credit_order_bonus(o) FROM orders o WHERE o.id = $1`, [id]);
  assert.equal((await wallet(cu)).bonusBalance, '1.00');
  const { rows } = await db.query(`SELECT count(*)::int AS n FROM bonus_entries WHERE order_id = $1`, [id]);
  assert.equal(rows[0].n, 1);
});

test('a completed order inserted as completed earns too, once', async () => {
  const cu = await customer('62');
  const id = await order(cu, 'withdraw', 'edahab', 10_000, 'completed');
  await setStatus(id, 'completed');
  assert.equal((await wallet(cu)).bonusBalance, '1.00');
});

test('a manager sets a customer to 2%, or turns it off for them', async () => {
  const cu = await customer('62');
  const s = await rpc(manager, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_rate_bp: 200 });
  assert.equal(s.rate, '2%');
  await rejects(rpc(manager, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_rate_bp: 300 }), 'VALIDATION_ERROR');
  const w = await withdraw(cu, 'edahab', 12.34);
  await complete(w.id);
  assert.equal((await wallet(cu)).bonusBalance, '0.2468', '2% of 12.34, exactly');
  await rpc(manager, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_enabled: false });
  const w2 = await withdraw(cu, 'edahab', 50);
  await complete(w2.id);
  assert.equal((await wallet(cu)).bonusBalance, '0.2468', 'off: nothing more');
  assert.equal((await rpc(manager, 'manage_customer_bonus', { p_customer_id: cu.id })).enabled, false);
  await rejects(rpc(cu.c, 'manage_set_customer_bonus', { p_customer_id: cu.id, p_rate_bp: 200 }), 'FORBIDDEN');
});

test('4. transferring moves the whole cents once, with a ledger credit; a fraction of a cent stays', async () => {
  const cu = await customer('62', 0);
  await db.query(`UPDATE wallets SET available_cents = 20000 WHERE customer_id = $1`, [cu.id]);
  await settings({ p_default_bp: 150 });
  try {
    await setStatus(await order(cu, 'withdraw', 'edahab', 10_033), 'completed'); // 1.5% of 100.33 = 1.50495
  } finally {
    await settings({ p_default_bp: 100 });
  }
  const before = await wallet(cu);
  assert.equal(before.bonusBalance, '1.50495');
  // Two at once: one transfer, never two.
  const results = await Promise.allSettled([rpc(cu.c, 'customer_move_bonus'), rpc(cu.c, 'customer_move_bonus')]);
  const ok = results.filter((r) => r.status === 'fulfilled');
  assert.equal(ok.length, 1, 'exactly one transfer');
  assert.equal(ok[0].value.moved, '1.50');
  assert.equal(results.find((r) => r.status === 'rejected').reason.code, 'NO_BONUS');
  const after = await wallet(cu);
  assert.equal(after.bonusBalance, '0.00495', 'the fraction of a cent stays');
  assert.equal(Number(after.availableBalance), Number(before.availableBalance) + 1.5);
  const { rows } = await db.query(`SELECT entry_type, amount_cents FROM ledger_entries l JOIN wallets w ON w.id = l.wallet_id
                                   WHERE w.customer_id = $1 AND l.reason = 'Bonus moved to main wallet'`, [cu.id]);
  assert.deepEqual(rows, [{ entry_type: 'credit', amount_cents: '150' }]);
  const info = await rpc(cu.c, 'customer_bonus');
  assert.equal(info.entries[0].kind, 'moved');
  assert.equal(info.entries[0].movedToMain, '1.50');
  assert.ok(info.entries[0].createdAt);
  await rejects(rpc(cu.c, 'customer_move_bonus'), 'NO_BONUS');
});

test('7. a manager turns the system off and on, sets the rate and the eligible types', async () => {
  const s = await settings({ p_enabled: false });
  assert.equal(s.enabled, false);
  try {
    const cu = await customer('62');
    await setStatus(await order(cu, 'withdraw', 'edahab', 10_000), 'completed');
    assert.equal((await wallet(cu)).bonusBalance, '0.00', 'off: nobody earns');
  } finally {
    await settings({ p_enabled: true });
  }
  await rejects(settings({ p_default_bp: 300 }), 'VALIDATION_ERROR');
  await rejects(settings({ p_eligible: ['withdraw:nope'] }), 'VALIDATION_ERROR');
  const view = await rpc(manager, 'manage_bonus_settings');
  assert.equal(view.enabled, true);
  assert.equal(view.defaultRateBp, 100);
  const zaad = view.types.find((t) => t.direction === 'withdraw' && t.method === 'telesom');
  assert.equal(zaad.eligible, false);
  assert.ok(view.types.find((t) => t.direction === 'withdraw' && t.method === 'edahab').eligible);
  assert.ok(Array.isArray(view.customers) && Array.isArray(view.history));
  const cu = await customer('62');
  await rejects(rpc(cu.c, 'manage_bonus_settings'), 'FORBIDDEN');
  await rejects(rpc(cu.c, 'manage_set_bonus_settings', { p_enabled: false }), 'FORBIDDEN');
});

test('the manager sees each customer\'s bonus balance and the history', async () => {
  const cu = await customer('62');
  await setStatus(await order(cu, 'withdraw', 'edahab', 30), 'completed'); // 1% of $0.30 = $0.003
  const view = await rpc(manager, 'manage_bonus_settings');
  const entry = view.history.find((e) => e.customerPhone === `252${cu.local}`);
  assert.equal(entry.amount, '0.003');
  const one = await rpc(manager, 'manage_customer_bonus', { p_customer_id: cu.id });
  assert.equal(one.balance, '0.003');
  assert.equal(one.transferable, '0.00');
});

test('Withdraw Confirm preview: the exact bonus, none for types that do not earn', async () => {
  const cu = await customer('62');
  assert.deepEqual(await rpc(cu.c, 'customer_bonus_preview', { p_method: 'edahab', p_amount: '250' }),
    { rate: '1%', amount: '2.50' });
  assert.deepEqual(await rpc(cu.c, 'customer_bonus_preview', { p_method: 'edahab', p_amount: '0.30' }),
    { rate: '1%', amount: '0.003' });
  assert.equal(await rpc(cu.c, 'customer_bonus_preview', { p_method: 'evc_plus', p_amount: '250' }), null);
});

test('receiver name lookup: only Golis, ZAAD and EVC Plus, always the customer\'s own number', async () => {
  const cu = await customer('63');
  assert.deepEqual(await rpc(cu.c, 'customer_begin_receiver_lookup', { p_method: 'telesom' }),
    { method: 'telesom', mobile: `0${cu.local}` });
  await rejects(rpc(cu.c, 'customer_begin_receiver_lookup', { p_method: 'edahab' }), 'VALIDATION_ERROR');
  await rejects(rpc(manager, 'customer_begin_receiver_lookup', { p_method: 'golis' }), 'FORBIDDEN');
});
