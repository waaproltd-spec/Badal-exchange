// Security hardening (migrations/*_security_hardening.sql, docs/SECURITY_AUDIT.md):
// agent duties are enforced by the server, ordinary agents can not add unlimited
// money to wallets, the audit log is final, sign-ups are limited, suspicious
// activity is recorded, and the database permissions stay as audited.
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
async function code(promise) {
  try {
    await promise;
    return null;
  } catch (e) {
    return e.code;
  }
}

const seed = Number(Date.now().toString().slice(-6));
let n = 0;
let manager;
const phone = (prefix) => `${prefix}${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;

async function agent(responsibilities) {
  const p = `2526${String(seed * 10 + n++).padStart(8, '0').slice(-8)}`;
  const a = await rpc(manager, 'admin_create_agent', { p_phone: p, p_name: 'Security Test Agent', p_password: PASSWORD, p_responsibilities: responsibilities });
  return { id: a.id, c: await login(p) };
}
async function customer(balanceCents = 100000) {
  const number = phone('61');
  const { rows: [u] } = await db.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash)
                VALUES ('customer', $1, 'Security Test', private.hash_password($2)) RETURNING id)
     INSERT INTO public.wallets (customer_id, available_cents) SELECT id, $3 FROM u RETURNING customer_id`,
    [`252${number}`, PASSWORD, balanceCents]);
  return { id: u.customer_id, phone: `252${number}` };
}
const ghost = () => randomUUID();
// The shipped default is 'off' (turned on in the Agent App's settings once every
// agent has the right duties); the tests of the check itself switch it on and put it back.
const enforcement = (v) => db.query(`UPDATE app_settings SET value = $1 WHERE key = 'agent_duty_enforcement'`, [v]);
async function enforced(fn) {
  await enforcement('on');
  try {
    return await fn();
  } finally {
    await enforcement('off');
  }
}

before(async () => { manager = await login('252610000002'); });
after(() => db.end());

test('agent duties: without the duty an agent can not complete or fail withdrawals, reject deposits or feed payment SMS', async () => {
  const none = await agent([]);
  const viewOnly = await agent(['view_company_balances']);
  await enforced(async () => {
  for (const a of [none, viewOnly]) {
    assert.equal(await code(rpc(a.c, 'agent_withdrawal_complete', { p_order_id: ghost(), p_transaction_ref: 'REF12345', p_idempotency_key: randomUUID() })), 'FORBIDDEN');
    assert.equal(await code(rpc(a.c, 'agent_withdrawal_fail', { p_order_id: ghost(), p_reason: 'not paid' })), 'FORBIDDEN');
    assert.equal(await code(rpc(a.c, 'agent_reject_deposit', { p_order_id: ghost(), p_reason: 'not paid' })), 'FORBIDDEN');
    assert.equal(await code(rpc(a.c, 'agent_ingest_payment_sms', { p_sender: '192', p_body: 'x', p_received_at: new Date().toISOString() })), 'FORBIDDEN');
  }
  });
});

test('agent duties: each duty opens its own calls only; managers always pass', async () => {
  const withdraw = await agent(['evc_withdraw']);
  const deposit = await agent(['evc_deposit']);
  const boss = await agent(['manage_settings']);
  // Past the duty check an unknown order is simply not found (anything but FORBIDDEN).
  const notForbidden = async (promise) => assert.notEqual(await code(promise), 'FORBIDDEN');
  await enforced(async () => {
  await notForbidden(rpc(withdraw.c, 'agent_withdrawal_fail', { p_order_id: ghost(), p_reason: 'not paid' }));
  await notForbidden(rpc(deposit.c, 'agent_reject_deposit', { p_order_id: ghost(), p_reason: 'not paid' }));
  await notForbidden(rpc(boss.c, 'agent_withdrawal_fail', { p_order_id: ghost(), p_reason: 'not paid' }));
  await notForbidden(rpc(boss.c, 'agent_reject_deposit', { p_order_id: ghost(), p_reason: 'not paid' }));
  assert.equal(await code(rpc(withdraw.c, 'agent_reject_deposit', { p_order_id: ghost(), p_reason: 'not paid' })), 'FORBIDDEN', 'withdraw duty is not the deposit duty');
  assert.equal(await code(rpc(deposit.c, 'agent_withdrawal_fail', { p_order_id: ghost(), p_reason: 'not paid' })), 'FORBIDDEN', 'deposit duty is not the withdraw duty');
  });
});

test('agent duties: the kill switch turns the check off, and back on', async () => {
  const none = await agent([]);
  await enforcement('off');
  assert.notEqual(await code(rpc(none.c, 'agent_withdrawal_fail', { p_order_id: ghost(), p_reason: 'not paid' })), 'FORBIDDEN');
  await enforced(async () => {
    assert.equal(await code(rpc(none.c, 'agent_withdrawal_fail', { p_order_id: ghost(), p_reason: 'not paid' })), 'FORBIDDEN');
  });
  const { rows: [r] } = await db.query(`SELECT value FROM app_settings WHERE key = 'agent_duty_enforcement'`);
  assert.equal(r.value, 'off', 'the shipped default stays off');
});

test('the guards are in the functions themselves (a later migration that rewrites one must keep them)', async () => {
  const { rows } = await db.query(
    `SELECT proname, pg_get_functiondef(oid) AS def FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('agent_withdrawal_complete', 'agent_withdrawal_fail', 'agent_reject_deposit', 'agent_ingest_payment_sms',
                       'agent_payout_confirmation', 'agent_payout_report_step1', 'agent_payout_report_step2', 'agent_payout_start_dial',
                       'agent_exchange_payout_confirmation', 'agent_exchange_report_step1', 'agent_exchange_report_step2', 'agent_exchange_start_dial')`);
  const names = new Set(rows.map((r) => r.proname));
  for (const core of ['agent_withdrawal_complete', 'agent_withdrawal_fail', 'agent_reject_deposit', 'agent_ingest_payment_sms',
                      'agent_payout_confirmation', 'agent_payout_report_step1', 'agent_payout_report_step2', 'agent_payout_start_dial']) {
    assert.ok(names.has(core), `${core} exists`);
  }
  for (const r of rows) assert.match(r.def, /require_agent_duty/, `${r.proname} checks the duty`);
  const { rows: reg } = await db.query(`SELECT pg_get_functiondef(oid) AS def FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'register_customer'`);
  assert.match(reg[0].def, /security_signups/, 'register_customer keeps its sign-up limit');
});

test('wallet adjustments: an ordinary agent is capped per day; a manager is not; deducting is not capped', async () => {
  const cu = await customer(0);
  const ordinary = await agent(['evc_deposit']);
  const boss = await agent(['manage_settings']);
  await db.query(`UPDATE app_settings SET value = '100' WHERE key = 'wallet_adjust_agent_daily_cap'`);
  const add = (a, amount) => rpc(a.c, 'agent_wallet_adjust', { p_customer_id: cu.id, p_direction: 'add', p_amount: amount, p_reason: 'security test', p_idempotency_key: randomUUID() });
  try {
    await add(ordinary, '60');
    assert.equal(await code(add(ordinary, '50')), 'ADJUSTMENT_LIMIT', '60 + 50 is over the $100 a day');
    await add(ordinary, '40'); // exactly up to the limit
    assert.equal(await code(add(ordinary, '1')), 'ADJUSTMENT_LIMIT');
    await rpc(ordinary.c, 'agent_wallet_adjust', { p_customer_id: cu.id, p_direction: 'deduct', p_amount: '30', p_reason: 'security test', p_idempotency_key: randomUUID() });
    await add(boss, '500'); // a manager is audited, not capped
    const { rows } = await db.query(`SELECT available_cents FROM wallets WHERE customer_id = $1`, [cu.id]);
    assert.equal(Number(rows[0].available_cents), 6000 + 4000 - 3000 + 50000, 'the balance is exactly what was allowed');
  } finally {
    await db.query(`UPDATE app_settings SET value = '2000' WHERE key = 'wallet_adjust_agent_daily_cap'`);
  }
});

test('the audit log is final: no update, delete or truncate, even for the database owner', async () => {
  const { rows: [row] } = await db.query(`SELECT id FROM audit_logs ORDER BY created_at DESC LIMIT 1`);
  assert.ok(row, 'there are audit rows');
  await assert.rejects(db.query(`UPDATE audit_logs SET action = 'tampered' WHERE id = $1`, [row.id]), /can not be changed or deleted/);
  await assert.rejects(db.query(`DELETE FROM audit_logs WHERE id = $1`, [row.id]), /can not be changed or deleted/);
  await assert.rejects(db.query(`TRUNCATE audit_logs`), /can not be changed or deleted/);
  assert.ok((await db.query(`SELECT 1 FROM audit_logs WHERE id = $1 AND action <> 'tampered'`, [row.id])).rows.length === 1);
});

test('sign-ups are limited for the whole service (150 in 10 minutes), and the limit lifts when the window passes', async () => {
  // Inside a transaction that is rolled back: other suites registering at the same time are not affected and no account is left behind.
  const attempt = async (minutesAgo) => {
    const c = await db.connect();
    try {
      await c.query('BEGIN');
      await c.query(`DELETE FROM security_signups`);
      await c.query(`INSERT INTO security_signups (at) SELECT now() - make_interval(mins => $1) FROM generate_series(1, 150)`, [minutesAgo]);
      return await c.query(`SELECT public.register_customer($1, 'Sign Up Limit', 'LongEnough123!')`, [`252${phone('61')}`]);
    } finally {
      await c.query('ROLLBACK');
      c.release();
    }
  };
  await assert.rejects(attempt(1), /Too many sign-ups right now/);
  const ok = await attempt(11);
  assert.equal(ok.rows.length, 1, 'allowed once the window has passed');
});

test('suspicious activity is recorded: many withdrawals, a large wallet adjustment, a permission change, Wallet ID probing', async () => {
  await db.query(`UPDATE security_events SET alerted_at = now() WHERE alerted_at IS NULL`);
  const cu = await customer(1000000);
  for (let i = 0; i < 8; i++) {
    await db.query(
      `INSERT INTO orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents)
       VALUES ($1, $2, 'withdraw', 'evc_plus', 'pending', $3, 1, $3, 0)`, [`EXSEC${seed}${n++}`, cu.id, 100 + i]);
  }
  const velocity = await db.query(`SELECT * FROM security_events WHERE kind = 'withdraw_velocity' AND customer_id = $1`, [cu.id]);
  assert.equal(velocity.rows.length, 1, 'once, not once a withdrawal');
  assert.match(velocity.rows[0].title_so, /Bixinno badan/);
  assert.match(velocity.rows[0].detail_so, /Lambarka telefoonka: 252/);
  assert.ok(!/password|pin|parool/i.test(velocity.rows[0].detail_so), 'no secrets');

  await rpc(manager, 'agent_wallet_adjust', { p_customer_id: cu.id, p_direction: 'add', p_amount: '600', p_reason: 'security test', p_idempotency_key: randomUUID() });
  assert.equal((await db.query(`SELECT 1 FROM security_events WHERE kind = 'wallet_adjust_large' AND customer_id = $1`, [cu.id])).rows.length, 1);

  await rpc(manager, 'manage_set_payment_number_access', { p_customer_id: cu.id, p_enabled: true });
  assert.equal((await db.query(`SELECT 1 FROM security_events WHERE kind = 'payment_number_access' AND customer_id = $1`, [cu.id])).rows.length, 1);

  const chat = 800000000 + seed;
  for (let i = 0; i < 5; i++) await db.query(`INSERT INTO support_events (chat_id, kind) VALUES ($1, 'wrong_wallet')`, [chat]);
  assert.equal((await db.query(`SELECT 1 FROM security_events WHERE kind = 'support_wallet_probe' AND dedupe_key = $1`, [String(chat)])).rows.length, 1);

  // Only the alert worker reads them to send; management reads the list; customers nothing.
  const cuClient = await login(cu.phone);
  assert.ok((await cuClient.rpc('security_events_todo')).error, 'a customer can not read the events');
  assert.ok((await cuClient.rpc('manage_security_events', {})).error);
  assert.ok((await cuClient.from('security_events').select('*')).error, 'the table is not readable');
  const list = await rpc(manager, 'manage_security_events', { p_limit: 20 });
  assert.ok(list.some((e) => e.kind === 'wallet_adjust_large'));
  await db.query(`UPDATE security_events SET alerted_at = now() WHERE alerted_at IS NULL`);
});

test('database permissions stay as audited: row level security everywhere, nothing open to anon, every definer function has a fixed search path', async () => {
  const { rows: noRls } = await db.query(
    `SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity ORDER BY 1`);
  assert.deepEqual(noRls.map((r) => r.relname), [], 'every public table has row level security');

  const { rows: anonTables } = await db.query(
    `SELECT table_name, privilege_type FROM information_schema.role_table_grants
     WHERE grantee = 'anon' AND table_schema = 'public' AND privilege_type <> 'SELECT'`);
  assert.deepEqual(anonTables, [], 'anon can not write any table');
  const { rows: anonReads } = await db.query(
    `SELECT table_name FROM information_schema.role_table_grants WHERE grantee = 'anon' AND table_schema = 'public' AND privilege_type = 'SELECT' ORDER BY 1`);
  assert.deepEqual(anonReads.map((r) => r.table_name), ['payment_methods'], 'anon reads only the public catalog');

  const { rows: writers } = await db.query(
    `SELECT table_name, privilege_type FROM information_schema.role_table_grants
     WHERE grantee = 'authenticated' AND table_schema = 'public' AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')`);
  assert.deepEqual(writers, [], 'the apps never write a table directly');

  // What a signed-out visitor may call: sign-up and the public catalogs, nothing that starts with a role.
  const { rows: anonFns } = await db.query(
    `SELECT p.proname FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('anon', p.oid, 'EXECUTE') ORDER BY 1`);
  for (const f of anonFns) {
    if (f.proname === 'support_contacts') continue; // the login screen's help numbers, public on purpose
    assert.ok(!/^(manage_|agent_|admin_|customer_|support_|telegram_|security_|platform_|payout_|merchant_)/.test(f.proname), `anon can run ${f.proname}`);
  }

  const { rows: loose } = await db.query(
    `SELECT n.nspname, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('public', 'private') AND p.prosecdef
       AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c WHERE c LIKE 'search_path=%')`);
  assert.deepEqual(loose, [], 'every SECURITY DEFINER function pins its search path');

  const { rows: privateOpen } = await db.query(
    `SELECT p.proname FROM pg_proc p WHERE p.pronamespace = 'private'::regnamespace AND p.prosecdef
       AND (has_function_privilege('anon', p.oid, 'EXECUTE')) AND p.proname NOT IN ('app_role', 'is_staff')`);
  assert.deepEqual(privateOpen.map((r) => r.proname), [], 'anon can run no private definer function (but the two row policy helpers)');
});
