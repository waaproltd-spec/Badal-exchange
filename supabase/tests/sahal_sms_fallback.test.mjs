// Sahal is the primary source of a deposit; SMS 898 on the Agent SIM is the fallback
// (migrations/*_sahal_sms_fallback.sql). Whatever source reports a payment, it credits ONCE.
// Database level: every test runs in a transaction that is rolled back.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
let agentId;
const seed = Number(Date.now().toString().slice(-6));
let n = 0;
const local = () => `61${String(seed * 10 + n++).padStart(7, '0').slice(-7)}`;

before(async () => {
  agentId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
});
after(() => db.end());

async function inTx(fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    // Claims decide who is calling (auth.uid()); the connection itself stays the owner so the tests can read tables.
    const as = async (id) => {
      await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify(id ? { sub: id, role: 'authenticated', aud: 'authenticated' } : { role: 'service_role' })]);
    };
    const tx = {
      as,
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
    };
    return await fn(tx);
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

async function customer(tx, number) {
  const id = (await tx.query(
    `WITH u AS (INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Sahal Fallback', private.hash_password('ChangeMe123!')) RETURNING id),
          w AS (INSERT INTO public.wallets (customer_id) SELECT id FROM u)
     SELECT id FROM u`, [`252${number}`])).rows[0].id;
  return id;
}
async function depositOf(tx, customerId, number, amount) {
  await tx.as(customerId);
  const d = await tx.call(`public.customer_create_deposit('evc_plus', $1, $2, $3)`, [String(amount), randomUUID(), `252${number}`]);
  await tx.as(null);
  return d;
}
const wallet = async (tx, id) => (await tx.query(`SELECT available_cents::int AS c FROM wallets WHERE customer_id = $1`, [id])).rows[0].c;
const status = async (tx, id) => (await tx.query(`SELECT status FROM orders WHERE id = $1`, [id])).rows[0].status;
const credits = async (tx, orderId) => (await tx.query(`SELECT count(*)::int AS n FROM ledger_entries WHERE order_id = $1 AND entry_type = 'credit'`, [orderId])).rows[0].n;

/** The SMS 898 as the Agent App uploads it (the Tix is the transaction reference). */
async function sahalSms(tx, { number, amount, tix = String(7000000000 + Math.floor(Math.random() * 999999999)), secondsAgo = 0 }) {
  await tx.as(agentId);
  const at = new Date(Date.now() - secondsAgo * 1000).toISOString();
  const r = await tx.call(`public.agent_ingest_payment_sms($1,$2,$3,'Sahal',$4,$5,$6,1,'sahal-phone')`, [
    '898', `[SAHAL] Tix: ${tix}, Waxaad $${amount} ka heshay  NAME (252${number}) Tar: , Haraagaagu waa $225.35`, at, String(amount), `252${number}`, tix]);
  await tx.as(null);
  return { ...r, tix, at };
}
/** The row Sahal's own feed lists for the same payment. */
async function feedRow(tx, { number, amount, secondsAgo = 0 }) {
  const id = randomUUID();
  await tx.query(`INSERT INTO public.merchant_transactions (id, provider, transaction_id, raw) VALUES ($1, 'golis', $2, $3)`, [
    id, `T${Math.floor(Math.random() * 1e9)}`,
    JSON.stringify({ description: `252${number} paid $${amount} to merchant: BULSHO AGENT (090353102),`, credit: Number(amount).toFixed(2), debit: '-', receiver: `252${number}` })]);
  await tx.query(`UPDATE public.merchant_transactions SET raw = jsonb_set(raw, '{tranDate}', to_jsonb(to_char((now() - make_interval(secs => $2)) AT TIME ZONE 'Africa/Mogadishu', 'DD/MM/YY HH24:MI:SS'))) WHERE id = $1`, [id, secondsAgo]);
  await tx.query(`SELECT private.merchant_sweep('golis')`);
  return id;
}
const feedState = (tx, state) => tx.query(
  `UPDATE public.merchant_feed_status SET state = $1, checked_at = now(), last_ok_at = now() WHERE provider = 'golis'`, [state]);

test('Sahal is down: the SMS 898 credits the deposit, once, however often it is uploaded', async () => {
  await inTx(async (tx) => {
    await feedState(tx, 'stopped');
    const num = local();
    const c = await customer(tx, num);
    const d = await depositOf(tx, c, num, 1);
    const first = await sahalSms(tx, { number: num, amount: 1 });
    assert.equal(first.matchStatus, 'matched');
    assert.equal(await status(tx, d.id), 'completed');
    assert.equal(await wallet(tx, c), 100);
    const again = await sahalSms(tx, { number: num, amount: 1, tix: first.tix });
    assert.equal(again.status, 'already_processed');
    await tx.query(`SELECT private.resweep_unmatched_sms()`);
    assert.equal(await wallet(tx, c), 100, 'credited once');
    assert.equal(await credits(tx, d.id), 1);
  });
});

test('Sahal is up and lists the payment: the feed credits it and the SMS is only a duplicate', async () => {
  await inTx(async (tx) => {
    await feedState(tx, 'ok');
    const num = local();
    const c = await customer(tx, num);
    const d = await depositOf(tx, c, num, 2);
    const sms = await sahalSms(tx, { number: num, amount: 2 });
    assert.equal(sms.matchStatus, 'unmatched', 'the SMS waits for Sahal while it answers');
    assert.equal(await status(tx, d.id), 'pending');
    await feedRow(tx, { number: num, amount: 2 });
    assert.equal(await status(tx, d.id), 'completed', 'the feed credited it');
    await tx.query(`SELECT private.resweep_unmatched_sms()`);
    const row = (await tx.query(`SELECT match_status FROM sms_logs WHERE id = $1`, [sms.id])).rows[0];
    assert.equal(row.match_status, 'duplicate_blocked');
    assert.equal(await wallet(tx, c), 200, 'credited once');
    assert.equal(await credits(tx, d.id), 1);
  });
});

test('Sahal is up but never lists the payment (a direct wallet transfer): after 90 seconds the SMS credits it', async () => {
  await inTx(async (tx) => {
    await feedState(tx, 'ok');
    const num = local();
    const c = await customer(tx, num);
    const d = await depositOf(tx, c, num, 1);
    const sms = await sahalSms(tx, { number: num, amount: 1, secondsAgo: 120 });
    assert.equal(sms.matchStatus, 'matched', 'not listed by Sahal, and the 90 seconds are over');
    assert.equal(await status(tx, d.id), 'completed');
    assert.equal(await wallet(tx, c), 100);
  });
});

test('the SMS credited first, then Sahal lists the same payment: it credits nothing, not even another deposit of the same amount', async () => {
  await inTx(async (tx) => {
    await feedState(tx, 'stopped');
    const num = local();
    const c = await customer(tx, num);
    const first = await depositOf(tx, c, num, 1);
    const second = await depositOf(tx, c, num, 1);
    const sms = await sahalSms(tx, { number: num, amount: 1 });
    assert.equal(sms.matchStatus, 'matched');
    await feedState(tx, 'ok'); // Sahal is back
    const row = await feedRow(tx, { number: num, amount: 1 });
    assert.equal((await tx.query(`SELECT match_status FROM merchant_transactions WHERE id = $1`, [row])).rows[0].match_status, 'duplicate');
    assert.equal(await wallet(tx, c), 100, 'one payment, one credit');
    const states = [await status(tx, first.id), await status(tx, second.id)].sort();
    assert.deepEqual(states, ['completed', 'pending'], 'the other deposit still waits for its own payment');
  });
});

test('two real payments of the same amount are two credits (each source pairs with its own)', async () => {
  await inTx(async (tx) => {
    await feedState(tx, 'ok');
    const num = local();
    const c = await customer(tx, num);
    await depositOf(tx, c, num, 1);
    await depositOf(tx, c, num, 1);
    await sahalSms(tx, { number: num, amount: 1, secondsAgo: 5 });
    await feedRow(tx, { number: num, amount: 1, secondsAgo: 5 });
    await sahalSms(tx, { number: num, amount: 1, secondsAgo: 4 });
    await feedRow(tx, { number: num, amount: 1, secondsAgo: 4 });
    await tx.query(`SELECT private.resweep_unmatched_sms()`);
    assert.equal(await wallet(tx, c), 200, 'two payments, two credits, no more');
  });
});

test('a Sahal SMS for a payment nobody is waiting for credits nothing and is kept', async () => {
  await inTx(async (tx) => {
    await feedState(tx, 'stopped');
    const num = local();
    const c = await customer(tx, num);
    const sms = await sahalSms(tx, { number: num, amount: 5 });
    assert.equal(sms.matchStatus, 'unmatched');
    assert.equal(await wallet(tx, c), 0);
    const d = await depositOf(tx, c, num, 5);
    assert.equal(await status(tx, d.id), 'completed', 'the SMS waits and takes the deposit when it is made');
  });
});

test('the dashboard shows the active source: Sahal, Agent SIM fallback, or neither', async () => {
  await inTx(async (tx) => {
    await tx.query(`UPDATE agent_devices SET sms_listening_at = NULL`);
    await feedState(tx, 'ok');
    await tx.as(agentId);
    assert.equal((await tx.call(`public.manage_payment_source()`)).source, 'sahal');
    await tx.as(null);
    await feedState(tx, 'stopped');
    await tx.as(agentId);
    assert.equal((await tx.call(`public.manage_payment_source()`)).source, 'none', 'Sahal is down and no phone reads SMS');
    await tx.query(`INSERT INTO agent_devices (agent_id, device_id) VALUES ($1, 'sim-phone') ON CONFLICT DO NOTHING`, [agentId]);
    await tx.call(`public.agent_sms_heartbeat('sim-phone')`);
    const r = await tx.call(`public.manage_payment_source()`);
    assert.equal(r.source, 'agent_sim');
    assert.equal(r.simUp, true);
    await tx.as(null);
    await feedState(tx, 'ok');
    await tx.as(agentId);
    assert.equal((await tx.call(`public.manage_payment_source()`)).source, 'sahal', 'Sahal is back: it is the source again');
  });
});

test('who may call: the heartbeat is for agents, the dashboard figure for managers', async () => {
  await inTx(async (tx) => {
    const num = local();
    const c = await customer(tx, num);
    await tx.as(c);
    for (const sql of [`public.agent_sms_heartbeat('x-phone-1')`, `public.manage_payment_source()`]) {
      await assert.rejects(tx.query(`SAVEPOINT s`).then(() => tx.call(sql)).finally(() => tx.query(`ROLLBACK TO s`)));
    }
  });
});
