// The Sahal feed signs in again by itself (migrations/*_sahal_auto_reconnect.sql): only while a phone
// reads SMS (it must enter the access code), never after a wrong password, and never more than a few
// times an hour. Database level: every test runs in a transaction that is rolled back.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
let agentId;

before(async () => {
  agentId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
});
after(() => db.end());

async function inTx(fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    const as = (id) => c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify(id ? { sub: id, role: 'authenticated', aud: 'authenticated' } : { role: 'service_role' })]);
    await as(null);
    return await fn({
      as,
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

const feed = (tx, state, { code = null, message = null } = {}) => tx.query(
  `UPDATE public.merchant_feed_status SET state = $1, result_code = $2, message = $3, checked_at = now() WHERE provider = 'golis'`, [state, code, message]);
const phoneReading = (tx, reading = true, hoursAgo = 0) => tx.query(
  `INSERT INTO public.agent_devices (agent_id, device_id, sms_listening_at) VALUES ($1, 'auto-reconnect-phone', $2)
   ON CONFLICT (agent_id, device_id) DO UPDATE SET sms_listening_at = EXCLUDED.sms_listening_at, status = 'active'`,
  [agentId, reading ? new Date(Date.now() - hoursAgo * 3600_000) : null]).then(() => tx.query(`UPDATE public.agent_devices SET sms_listening_at = NULL WHERE device_id <> 'auto-reconnect-phone'`));
const recover = (tx) => tx.call(`public.merchant_feed_auto_recover('golis')`);
const state = async (tx) => (await tx.query(`SELECT state FROM public.merchant_feed_status WHERE provider = 'golis'`)).rows[0].state;
const events = async (tx, event) => (await tx.query(`SELECT count(*)::int AS n FROM private.merchant_feed_events WHERE provider = 'golis' AND event = $1`, [event])).rows[0].n;

test('a stopped feed signs in again by itself while a phone reads SMS', async () => {
  await inTx(async (tx) => {
    await phoneReading(tx);
    await feed(tx, 'stopped', { code: '2007', message: 'Sign-in refused' });
    assert.deepEqual(await recover(tx), { recover: true });
    assert.equal(await state(tx), 'ready', 'the normal run signs in now');
    assert.equal(await events(tx, 'auto_reconnect'), 1, 'logged');
    assert.equal((await recover(tx)).why, 'running', 'once: it is signing in already');
  });
});

test('the app is closed (Sahal ends its session then): a phone seen reading SMS within 24 hours is enough, one not seen for longer is not', async () => {
  await inTx(async (tx) => {
    await feed(tx, 'stopped', { code: '2007' });
    await phoneReading(tx, true, 5);
    assert.equal(await tx.call(`private.merchant_feed_recover_block('golis')`), null, 'seen 5 hours ago');
    await phoneReading(tx, true, 30);
    assert.equal(await tx.call(`private.merchant_feed_recover_block('golis')`), 'no_phone_reading_sms', 'seen 30 hours ago');
    // the Dashboard card is stricter: it says what reads right now
    assert.equal(await tx.call(`private.agent_sim_up()`), false);
  });
});

test('never without a phone that can enter the code, never after a wrong password or a password change', async () => {
  await inTx(async (tx) => {
    await phoneReading(tx, false);
    await feed(tx, 'stopped', { code: '2007' });
    assert.equal((await recover(tx)).why, 'no_phone_reading_sms');
    assert.equal(await state(tx), 'stopped');
    await phoneReading(tx);
    for (const code of ['4001', '6054']) {
      await feed(tx, 'stopped', { code });
      assert.equal((await recover(tx)).why, 'needs_a_person', `code ${code}`);
    }
    await feed(tx, 'stopped', { code: null, message: 'Invalid username or password' });
    assert.equal((await recover(tx)).why, 'needs_a_person', 'a refused password is only said in words');
    assert.equal(await events(tx, 'auto_reconnect'), 0);
    assert.ok(await events(tx, 'auto_reconnect_held') >= 1, 'the refusal is logged');
  });
});

test('an access code that is not entered gets 10 minutes, then the feed signs in again', async () => {
  await inTx(async (tx) => {
    await phoneReading(tx);
    await feed(tx, 'needs_code');
    await tx.query(`INSERT INTO private.merchant_feed_sessions (provider, session_id, second_session_id, second_at)
                    VALUES ('golis', NULL, 'p', now() - interval '5 minutes')
                    ON CONFLICT (provider) DO UPDATE SET second_session_id = 'p', second_at = now() - interval '5 minutes'`);
    assert.equal((await recover(tx)).why, 'waiting_for_code');
    await tx.query(`UPDATE private.merchant_feed_sessions SET second_at = now() - interval '11 minutes' WHERE provider = 'golis'`);
    assert.deepEqual(await recover(tx), { recover: true });
    assert.equal(await state(tx), 'ready');
  });
});

test('limits: 5 minutes apart, 4 an hour, 12 a day', async () => {
  await inTx(async (tx) => {
    await phoneReading(tx);
    await feed(tx, 'stopped', { code: '2007' });
    assert.equal((await recover(tx)).recover, true);
    await feed(tx, 'stopped', { code: '2007' });
    assert.equal((await recover(tx)).why, 'too_soon', 'a second sign-in a moment later');
    // four in the last hour (the newest more than 5 minutes ago)
    await tx.query(`DELETE FROM private.merchant_feed_events WHERE provider = 'golis' AND event = 'auto_reconnect'`);
    await tx.query(`INSERT INTO private.merchant_feed_events (provider, event, at) SELECT 'golis', 'auto_reconnect', now() - make_interval(mins => 6 + g * 10) FROM generate_series(0, 3) g`);
    assert.equal((await recover(tx)).why, 'hourly_limit');
    await tx.query(`DELETE FROM private.merchant_feed_events WHERE provider = 'golis' AND event = 'auto_reconnect'`);
    await tx.query(`INSERT INTO private.merchant_feed_events (provider, event, at) SELECT 'golis', 'auto_reconnect', now() - make_interval(mins => 70 + g * 30) FROM generate_series(0, 11) g`);
    assert.equal((await recover(tx)).why, 'daily_limit');
  });
});

test('a feed that is running is left alone; the timer wakes the worker for a stopped one only when it may recover', async () => {
  await inTx(async (tx) => {
    await phoneReading(tx);
    await feed(tx, 'ok');
    assert.equal((await recover(tx)).why, 'running');
    assert.equal(await state(tx), 'ok');
    assert.equal(await tx.call(`private.merchant_feed_recover_block('golis')`), 'running');
    await feed(tx, 'stopped', { code: '2007' });
    assert.equal(await tx.call(`private.merchant_feed_recover_block('golis')`), null, 'may recover');
    await feed(tx, 'stopped', { code: '4001' });
    assert.equal(await tx.call(`private.merchant_feed_recover_block('golis')`), 'needs_a_person');
    await tx.query(`SELECT private.merchant_feed_kick()`); // never throws
  });
});

test('the dashboard figure is for managers; the recovery is for the service role', async () => {
  await inTx(async (tx) => {
    await tx.as(agentId);
    const r = await tx.call(`public.manage_sahal_connection()`);
    assert.equal(typeof r.autoReconnectsToday, 'number');
    assert.equal(typeof r.codesEnteredToday, 'number');
    await assert.rejects(tx.query(`SAVEPOINT s`).then(() => tx.call(`public.merchant_feed_auto_recover('golis')`)).finally(() => tx.query(`ROLLBACK TO s`)));
  });
});
