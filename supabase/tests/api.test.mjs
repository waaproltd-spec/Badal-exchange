// End-to-end tests for the Supabase backend: real Supabase Auth, the Data
// API (RPC + row level security) and Realtime, exercised exactly the way the
// Customer App and Agent App call them.
//
//   supabase start            # local stack (from the repo root)
//   supabase db reset         # fresh database with all migrations
//   cd supabase/tests && npm install && npm test
//
// SUPABASE_URL / SUPABASE_ANON_KEY / DATABASE_URL default to the local stack.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import bcrypt from 'bcryptjs';
import pg from 'pg';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const PASSWORD = 'ChangeMe123!';

const db = new pg.Pool({ connectionString: DATABASE_URL });
const run = Date.now().toString().slice(-7);
const phone = (n) => `2526${run}${n}`;

/** Same derivation the apps use (lib/api/supabase_api.dart authEmailFor). */
function authEmail(identifier) {
  if (identifier.includes('@')) return identifier.toLowerCase();
  const digits = identifier.replace(/\D/g, '');
  const local = digits.length >= 4 ? digits : 'x' + Buffer.from(identifier, 'utf8').toString('hex');
  return `${local}@phone.baari.invalid`;
}

function client() {
  return createClient(URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function login(identifier, password = PASSWORD) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: authEmail(identifier), password });
  if (error) throw error;
  return c;
}

async function rpc(c, fn, args = {}) {
  const { data, error } = await c.rpc(fn, args);
  if (error) {
    const e = new Error(`${fn}: ${error.message}`);
    e.code = error.hint ?? error.code;
    e.pg = error;
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

const key = () => randomUUID();
let agent; // demo agent, has manage_settings
let customer;
let customer2;
let customerId;

before(async () => {
  agent = await login('252610000002');
  const anon = client();
  const reg = await rpc(anon, 'register_customer', { p_phone: phone(1), p_name: 'Test Customer', p_password: PASSWORD });
  customerId = reg.user.id;
  customer = await login(phone(1));
  await rpc(anon, 'register_customer', { p_phone: phone(2), p_name: 'Other Customer', p_password: PASSWORD });
  customer2 = await login(phone(2));
});

after(async () => {
  for (const c of [agent, customer, customer2]) await c?.removeAllChannels();
  await db.end();
});

test('catalog is public; customer data is not', async () => {
  const anon = client();
  const catalog = await rpc(anon, 'payment_method_catalog');
  assert.equal(catalog.length, 10);
  assert.deepEqual(catalog.map((m) => m.method).slice(0, 4), ['evc_plus', 'golis', 'telesom', 'edahab']);
  assert.equal(catalog.find((m) => m.method === 'onexbet').label, '1XBET');
  const { error } = await anon.rpc('customer_wallet');
  assert.ok(error, 'anon must not call customer_wallet');
  const { data: rows } = await anon.from('orders').select('*');
  assert.equal((rows ?? []).length, 0);
});

test('register: validation, duplicate phone, session profile', async () => {
  const anon = client();
  await rejects(rpc(anon, 'register_customer', { p_phone: phone(1), p_name: 'Dup', p_password: PASSWORD }), 'PHONE_TAKEN');
  await rejects(rpc(anon, 'register_customer', { p_phone: phone(3), p_name: 'Short', p_password: 'short' }), 'VALIDATION_ERROR');
  const me = await rpc(customer, 'session_profile', { p_record_login: true });
  assert.equal(me.role, 'customer');
  assert.equal(me.phone, phone(1));
  const w = await rpc(customer, 'customer_wallet');
  assert.deepEqual(w, { availableBalance: '0.00', pendingBalance: '0.00', totalDeposit: '0.00', totalWithdraw: '0.00' });
});

test('wrong password and role separation', async () => {
  await assert.rejects(login(phone(1), 'wrong-password'));
  await rejects(rpc(customer, 'agent_dashboard'), 'FORBIDDEN');
  await rejects(rpc(agent, 'customer_wallet'), 'FORBIDDEN');
  await rejects(rpc(customer, 'manage_payment_methods'), 'FORBIDDEN');
});

test('a user migrated with a bcryptjs hash logs in with the same password', async () => {
  const hash = bcrypt.hashSync('Legacy-Pass-1', 12); // what the Node backend stored
  const { rows } = await db.query(
    `INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Legacy', $2) RETURNING id`,
    [phone(9), hash]
  );
  const c = await login(phone(9), 'Legacy-Pass-1');
  const me = await rpc(c, 'session_profile');
  assert.equal(me.id, rows[0].id);
});

test('quote matches the backend math', async () => {
  const dep = await rpc(customer, 'customer_quote', { p_direction: 'deposit', p_method: 'evc_plus', p_amount: '10' });
  assert.equal(dep.fee, '0.20');
  assert.equal(dep.netAmount, '9.80');
  const wd = await rpc(customer, 'customer_quote', { p_direction: 'withdraw', p_method: 'winwin', p_amount: '10' });
  assert.equal(wd.fee, '0.10');
  assert.equal(wd.walletDelta, '10.10');
  assert.equal(wd.netAmount, '10.00');
  await rejects(rpc(customer, 'customer_quote', { p_direction: 'withdraw', p_method: 'winwin', p_amount: '0.5' }), 'BELOW_MIN_WITHDRAWAL');
  await rejects(rpc(customer, 'customer_quote', { p_direction: 'withdraw', p_method: 'winwin', p_amount: '501' }), 'ABOVE_MAX_WITHDRAWAL');
});

test('mobile-money deposit: idempotency, SMS match, wallet credit, dedupe', async () => {
  const k = key();
  const args = { p_method: 'evc_plus', p_amount: '25', p_idempotency_key: k, p_phone_number: phone(1) };
  await rejects(rpc(customer, 'customer_create_deposit', { ...args, p_idempotency_key: null }), 'IDEMPOTENCY_KEY_REQUIRED');
  await rejects(rpc(customer, 'customer_create_deposit', { ...args, p_phone_number: null }), 'VALIDATION_ERROR');
  const order = await rpc(customer, 'customer_create_deposit', args);
  assert.equal(order.status, 'pending');
  assert.equal(order.netAmount, '24.80');
  assert.equal(order.depositCode, null);
  const replay = await rpc(customer, 'customer_create_deposit', args);
  assert.equal(replay.id, order.id, 'retry with the same key returns the same order');
  await rejects(rpc(customer, 'customer_create_deposit', { ...args, p_amount: '26' }), 'IDEMPOTENCY_KEY_REUSED');

  const pending = await rpc(agent, 'agent_pending_deposits');
  assert.ok(pending.some((o) => o.id === order.id));

  const ref = `TX${run}A`;
  const sms = { p_provider: 'evc_plus', p_sender: phone(1), p_amount: '25', p_transaction_ref: ref,
    p_occurred_at: new Date().toISOString(), p_idempotency_key: key(), p_device_id: 'dev-1' };
  const match = await rpc(agent, 'agent_submit_sms_transaction', sms);
  assert.deepEqual(match, { status: 'matched', orderId: order.id });
  const dup = await rpc(agent, 'agent_submit_sms_transaction', { ...sms, p_idempotency_key: key() });
  assert.equal(dup.status, 'duplicate');

  const after = await rpc(customer, 'customer_order', { p_id: order.id });
  assert.equal(after.status, 'completed');
  assert.equal(after.transactionRef, ref);
  const w = await rpc(customer, 'customer_wallet');
  assert.equal(w.availableBalance, '24.80');
  assert.equal(w.totalDeposit, '24.80');
});

test('manual mobile-money and unmatched confirmations', async () => {
  const order = await rpc(customer, 'customer_create_deposit', {
    p_method: 'golis', p_amount: '5', p_idempotency_key: key(), p_phone_number: phone(1) });
  const r = await rpc(agent, 'agent_submit_mobile_money_transaction', {
    p_method: 'golis', p_sender_phone: phone(1), p_amount: '5', p_transaction_ref: `G${run}`,
    p_occurred_at: new Date().toISOString(), p_idempotency_key: key() });
  assert.deepEqual(r, { status: 'matched', orderId: order.id });
  const none = await rpc(agent, 'agent_submit_mobile_money_transaction', {
    p_method: 'golis', p_sender_phone: '252699999999', p_amount: '7', p_transaction_ref: `G${run}X`,
    p_occurred_at: new Date().toISOString(), p_idempotency_key: key() });
  assert.equal(none.status, 'unmatched');
});

test('platform deposit with deposit code', async () => {
  const order = await rpc(customer, 'customer_create_deposit', {
    p_method: 'melbet', p_amount: '20', p_idempotency_key: key(), p_account_id: 'MB12345' });
  assert.match(order.depositCode, /^[A-Z2-9]{4}$/);
  assert.equal(order.accountId, 'MB12345');
  const wrongCode = await rpc(agent, 'agent_submit_platform_transaction', {
    p_method: 'melbet', p_account_id: 'MB12345', p_amount: '20', p_reference: `M${run}0`,
    p_occurred_at: new Date().toISOString(), p_idempotency_key: key(), p_deposit_code: 'ZZZZ' });
  assert.equal(wrongCode.status, 'unmatched');
  const ok = await rpc(agent, 'agent_submit_platform_transaction', {
    p_method: 'melbet', p_account_id: 'MB12345', p_amount: '20', p_reference: `M${run}1`,
    p_occurred_at: new Date().toISOString(), p_idempotency_key: key(), p_deposit_code: order.depositCode });
  assert.deepEqual(ok, { status: 'matched', orderId: order.id });
  const w = await rpc(customer, 'customer_wallet');
  assert.equal(w.availableBalance, '49.40'); // 24.80 + 4.80 + 19.80
});

test('withdrawals: reserve, duplicate guard, complete, fail releases', async () => {
  await rejects(rpc(customer, 'customer_create_withdrawal', {
    p_method: 'evc_plus', p_amount: '400', p_idempotency_key: key(), p_phone_number: phone(1) }), 'INSUFFICIENT_BALANCE');

  const wd = await rpc(customer, 'customer_create_withdrawal', {
    p_method: 'evc_plus', p_amount: '10', p_idempotency_key: key(), p_phone_number: phone(1) });
  let w = await rpc(customer, 'customer_wallet');
  assert.equal(w.availableBalance, '39.30');
  assert.equal(w.pendingBalance, '10.10');
  await rejects(rpc(customer, 'customer_create_withdrawal', {
    p_method: 'evc_plus', p_amount: '10', p_idempotency_key: key(), p_phone_number: phone(1) }), 'DUPLICATE_WITHDRAWAL');

  const started = await rpc(agent, 'agent_withdrawal_start', { p_order_id: wd.id });
  assert.equal(started.status, 'processing');
  await rejects(rpc(agent, 'agent_withdrawal_start', { p_order_id: wd.id }), 'INVALID_ORDER_STATE');
  const done = await rpc(agent, 'agent_withdrawal_complete', { p_order_id: wd.id, p_transaction_ref: `W${run}`, p_idempotency_key: key() });
  assert.equal(done.status, 'completed');
  w = await rpc(customer, 'customer_wallet');
  assert.equal(w.pendingBalance, '0.00');
  assert.equal(w.totalWithdraw, '10.10');

  const wd2 = await rpc(customer, 'customer_create_withdrawal', {
    p_method: 'onexbet', p_amount: '5', p_idempotency_key: key(), p_account_id: '1X998877' });
  const failed = await rpc(agent, 'agent_withdrawal_fail', { p_order_id: wd2.id, p_reason: 'Account not found' });
  assert.equal(failed.status, 'failed');
  w = await rpc(customer, 'customer_wallet');
  assert.equal(w.availableBalance, '39.30');
  assert.equal(w.pendingBalance, '0.00');
  const ledger = await rpc(agent, 'agent_customer_ledger', { p_id: customerId });
  assert.deepEqual(ledger.slice(0, 2).map((l) => l.type), ['release', 'reserve']);
});

test('row level security: each role sees only its rows; no direct writes', async () => {
  const { data: own } = await customer.from('orders').select('id, customer_id');
  assert.ok(own.length > 0 && own.every((o) => o.customer_id === customerId));
  const { data: others } = await customer2.from('orders').select('id');
  assert.equal(others.length, 0);
  const { data: sms } = await customer.from('sms_transactions').select('id');
  assert.equal(sms.length, 0);
  const { error: pwErr } = await customer.from('users').select('password_hash');
  assert.ok(pwErr, 'password_hash is not readable');
  const { data: users } = await customer.from('users').select('id');
  assert.deepEqual(users.map((u) => u.id), [customerId]);
  const { error: insErr } = await customer.from('wallets').update({ available_cents: 999999 }).eq('customer_id', customerId);
  assert.ok(insErr, 'wallet is not writable');
  const { data: all } = await agent.from('orders').select('id');
  assert.ok(all.length >= own.length);
  const { error: auditErr, data: audit } = await agent.from('audit_logs').select('id');
  assert.ok(auditErr || audit.length === 0, 'audit log only through the management API');
});

test('agent console: dashboard, users, reports, history, account', async () => {
  const dash = await rpc(agent, 'agent_dashboard');
  assert.ok(dash.totalTransactions >= 5);
  assert.ok(dash.recentActivity.length > 0);
  const users = await rpc(agent, 'agent_customers', { p_q: phone(1) });
  assert.equal(users.length, 1);
  assert.equal(users[0].walletBalance, '39.30');
  assert.ok(users[0].deposits >= 3);
  const sorted = await rpc(agent, 'agent_customers', { p_sort: 'balance', p_limit: 100 });
  assert.ok(sorted.length >= 2);
  const detail = await rpc(agent, 'agent_customer', { p_id: customerId });
  assert.equal(detail.totalWithdrawals, '10.10');
  assert.ok(detail.recentOrders.length > 0);
  const rep = await rpc(agent, 'agent_reports', { p_period: 'weekly' });
  assert.equal(rep.series.length, 7);
  assert.ok(rep.deposits.count >= 3);
  await rejects(rpc(agent, 'agent_reports', { p_period: 'custom', p_from: '2026-02-01', p_to: '2026-01-01' }), 'VALIDATION_ERROR');
  const hist = await rpc(agent, 'agent_history', { p_limit: 100 });
  assert.ok(hist.some((h) => h.kind === 'confirmation') && hist.some((h) => h.kind === 'order'));
  const conf = await rpc(agent, 'agent_history', { p_type: 'confirmation', p_status: 'unmatched' });
  assert.ok(conf.every((h) => h.kind === 'confirmation' && h.status === 'unmatched'));
  const mine = await rpc(agent, 'agent_history', { p_customer_id: customerId, p_method: 'melbet' });
  assert.ok(mine.length === 1 && mine[0].methodLabel === 'MELBET');
  const acct = await rpc(agent, 'agent_account');
  assert.equal(acct.canManageSettings, true);
  await rpc(agent, 'agent_register_device', { p_device_id: 'device-abc', p_device_label: 'Test phone' });
});

test('management: method switch, rates, fees, limits, content', async () => {
  await rpc(agent, 'manage_set_payment_method', { p_method: 'telesom', p_enabled: false });
  const methods = await rpc(customer, 'customer_payment_methods');
  assert.ok(!methods.some((m) => m.method === 'telesom'));
  await rejects(rpc(customer, 'customer_create_deposit', {
    p_method: 'telesom', p_amount: '5', p_idempotency_key: key(), p_phone_number: phone(1) }), 'METHOD_DISABLED');
  await rpc(agent, 'manage_set_payment_method', { p_method: 'telesom', p_enabled: true });

  await rpc(agent, 'admin_set_exchange_rate', { p_method: 'dbbet', p_direction: 'deposit', p_rate: 1.05 });
  await rpc(agent, 'admin_set_fee', { p_method: 'dbbet', p_direction: 'deposit', p_fee_type: 'flat', p_value: 50 });
  await rpc(agent, 'admin_set_withdrawal_limits', { p_method: 'dbbet', p_min_amount: 2, p_max_amount: 300 });
  const list = await rpc(agent, 'manage_payment_methods');
  const dbbet = list.find((m) => m.method === 'dbbet');
  assert.equal(dbbet.depositRate, 1.05);
  assert.deepEqual(dbbet.depositFee, { type: 'flat', value: 50 });
  assert.equal(dbbet.minWithdraw, '2.00');
  assert.equal(dbbet.maxWithdraw, '300.00');
  const q = await rpc(customer, 'customer_quote', { p_direction: 'deposit', p_method: 'dbbet', p_amount: '100' });
  assert.equal(q.netAmount, '104.50');

  const ad = await rpc(agent, 'manage_save_home_ad', { p_title: 'Welcome', p_link_url: 'https://example.com' });
  await rejects(rpc(agent, 'manage_save_home_ad', { p_title: 'Bad', p_link_url: 'not a url' }), 'VALIDATION_ERROR');
  assert.ok((await rpc(customer, 'customer_home_ads')).some((a) => a.id === ad.id));
  await rpc(agent, 'manage_save_home_ad', { p_id: ad.id, p_title: 'Welcome', p_enabled: false });
  assert.ok(!(await rpc(customer, 'customer_home_ads')).some((a) => a.id === ad.id));
  await rpc(agent, 'manage_delete_home_ad', { p_id: ad.id });

  const num = await rpc(agent, 'manage_save_deposit_number', { p_method: 'evc_plus', p_number: `61${run}`, p_label: 'Main' });
  await rejects(rpc(agent, 'manage_save_deposit_number', { p_method: 'evc_plus', p_number: `61${run}` }), 'DUPLICATE_DEPOSIT_NUMBER');
  const evc = (await rpc(customer, 'customer_payment_methods')).find((m) => m.method === 'evc_plus');
  assert.ok(evc.depositNumbers.some((n) => n.number === `61${run}`));
  await rpc(agent, 'manage_delete_deposit_number', { p_id: num.id });

  await rpc(agent, 'manage_send_notification', { p_title: 'Hello', p_body: 'Test notice' });
  assert.equal((await rpc(customer, 'customer_notifications'))[0].title, 'Hello');
  const contacts = await rpc(agent, 'manage_set_contacts', { p_whatsapp: ' https://wa.me/252610000000 ', p_facebook: '', p_telegram: '' });
  assert.equal(contacts.whatsapp, 'https://wa.me/252610000000');
  assert.equal((await rpc(customer, 'customer_contacts')).whatsapp, 'https://wa.me/252610000000');

  const audit = await rpc(agent, 'admin_audit_logs');
  assert.ok(audit.some((a) => a.action === 'contacts.update'));
});

test('agents: create, responsibilities, disable signs out and blocks', async () => {
  const created = await rpc(agent, 'admin_create_agent', {
    p_phone: phone(5), p_name: 'New Agent', p_password: 'Agent-Pass-1', p_responsibilities: ['evc_deposit', 'evc_deposit'] });
  const a2 = await login(phone(5), 'Agent-Pass-1');
  assert.equal((await rpc(a2, 'agent_account')).canManageSettings, false);
  await rejects(rpc(a2, 'manage_payment_methods'), 'FORBIDDEN');
  const resp = await rpc(agent, 'admin_set_agent_responsibilities', { p_id: created.id, p_responsibilities: ['evc_deposit', 'manage_settings'] });
  assert.deepEqual(resp.responsibilities, ['evc_deposit', 'manage_settings']);
  await rpc(a2, 'manage_payment_methods');
  const me = await rpc(agent, 'session_profile');
  await rejects(rpc(agent, 'admin_set_agent_responsibilities', { p_id: me.id, p_responsibilities: [] }), 'SELF_LOCKOUT');
  await rejects(rpc(agent, 'admin_set_agent_status', { p_id: me.id, p_enabled: false }), 'SELF_LOCKOUT');

  await rpc(agent, 'admin_set_agent_status', { p_id: created.id, p_enabled: false });
  await rejects(rpc(a2, 'agent_dashboard'), 'FORBIDDEN');
  await assert.rejects(login(phone(5), 'Agent-Pass-1'), /banned/i);
  await rpc(agent, 'admin_set_agent_status', { p_id: created.id, p_enabled: true });
  await login(phone(5), 'Agent-Pass-1');
  assert.ok((await rpc(agent, 'admin_agents')).some((x) => x.id === created.id));
});

test('change password', async () => {
  const anon = client();
  await rpc(anon, 'register_customer', { p_phone: phone(6), p_name: 'Pw', p_password: PASSWORD });
  const c = await login(phone(6));
  await rejects(rpc(c, 'change_password', { p_current_password: 'nope', p_new_password: 'New-Pass-123' }), 'INVALID_PASSWORD');
  await rpc(c, 'change_password', { p_current_password: PASSWORD, p_new_password: 'New-Pass-123' });
  await rpc(c, 'customer_wallet'); // this session stays signed in
  await login(phone(6), 'New-Pass-123');
  await assert.rejects(login(phone(6), PASSWORD));
});

test('payment integrations: credentials in Vault, password never returned', async () => {
  const r = await rpc(agent, 'admin_set_integration_credentials', {
    p_provider: 'mobcash_winwin', p_username: 'manager1', p_password: 's3cret', p_config: {} });
  assert.equal(r.username, 'manager1');
  assert.equal(r.hasCredentials, true);
  assert.ok(!JSON.stringify(r).includes('s3cret'));
  const again = await rpc(agent, 'admin_set_integration_credentials', {
    p_provider: 'mobcash_winwin', p_username: 'manager2', p_password: 'other', p_config: {} });
  assert.equal(again.username, 'manager2');
  const { rows } = await db.query(
    `SELECT s.decrypted_secret FROM public.payment_integrations p JOIN vault.decrypted_secrets s ON s.id = p.password_secret_id
     WHERE p.provider = 'mobcash_winwin'`);
  assert.equal(rows[0].decrypted_secret, 'other');
  const auto = await rpc(agent, 'admin_set_integration_automation', { p_provider: 'mobcash_winwin', p_mode: 'automatic', p_dry_run: true });
  assert.equal(auto.automationMode, 'automatic');
  const tested = await rpc(agent, 'admin_test_integration_connection', { p_provider: 'mobcash_winwin' });
  assert.equal(tested.lastTestResult, 'not_configured');
  await rpc(agent, 'admin_set_integration_automation', { p_provider: 'mobcash_winwin', p_mode: 'manual', p_dry_run: true });
  assert.equal((await rpc(agent, 'admin_payment_integrations')).length, 2);
  await rejects(rpc(agent, 'admin_mobcash_login_check', { p_username: 'a', p_password: 'b' }), 'WORKER_REQUIRED');
});

test('realtime: customers get their own order and wallet changes only', async () => {
  const mine = [];
  const theirs = [];
  // Realtime restarts with `supabase db reset`; retry while it comes back.
  const subscribe = async (c, sink) => {
    for (let attempt = 1; ; attempt++) {
      try {
        return await subscribeOnce(c, sink);
      } catch (err) {
        await c.removeAllChannels();
        if (attempt >= 15) throw err;
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
  };
  const subscribeOnce = (c, sink) =>
    new Promise((resolve, reject) => {
      c.channel(`t-${randomUUID()}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, (p) => sink.push(p))
        .on('postgres_changes', { event: '*', schema: 'public', table: 'wallets' }, (p) => sink.push(p))
        .subscribe((status, err) => {
          if (status === 'SUBSCRIBED') resolve();
          if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') reject(err ?? new Error(status));
        });
    });
  for (const c of [customer, customer2]) {
    const { data } = await c.auth.getSession();
    c.realtime.setAuth(data.session.access_token);
  }
  await subscribe(customer, mine);
  await subscribe(customer2, theirs);
  // On a freshly started stack Realtime creates its replication slot on the
  // first subscription; wait until changes are actually streaming.
  const warmUntil = Date.now() + 30000;
  while (Date.now() < warmUntil && !mine.some((p) => p.table === 'wallets')) {
    await db.query('UPDATE public.wallets SET updated_at = now() WHERE customer_id = $1', [customerId]);
    await new Promise((r) => setTimeout(r, 1000));
  }
  mine.length = 0;
  theirs.length = 0;

  const order = await rpc(customer, 'customer_create_deposit', {
    p_method: 'evc_plus', p_amount: '3', p_idempotency_key: key(), p_phone_number: phone(1) });
  await rpc(agent, 'agent_submit_sms_transaction', {
    p_provider: 'evc_plus', p_sender: phone(1), p_amount: '3', p_transaction_ref: `RT${run}`,
    p_occurred_at: new Date().toISOString(), p_idempotency_key: key() });

  const deadline = Date.now() + 15000;
  while (Date.now() < deadline && !mine.some((p) => p.table === 'orders' && p.new?.status === 'completed')) {
    await new Promise((r) => setTimeout(r, 250));
  }
  assert.ok(mine.some((p) => p.table === 'orders' && p.new?.id === order.id && p.new.status === 'completed'));
  assert.ok(mine.some((p) => p.table === 'wallets' && p.new?.customer_id === customerId));
  assert.equal(theirs.length, 0, 'another customer receives nothing');
});
