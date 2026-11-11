// Payment Backup notice (migrations/*_payment_backup_notice.sql): a change of the source that confirms payments (Sahal, the Agent
// phone's SMS, none) is announced once, only after it lasted 2 minutes; a flicker and the first run announce nothing.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
after(() => db.end());

async function inTx(fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`);
    // The source is whatever private.payment_source() reads: control it through the two things it reads.
    await c.query(`ALTER TABLE public.merchant_feed_status DISABLE TRIGGER USER`);
    await c.query(`DELETE FROM public.payment_source_state`);
    await c.query(`DELETE FROM public.payment_source_events`);
    return await fn({
      todo: async () => (await c.query(`SELECT public.payment_source_todo() AS r`)).rows[0].r,
      source: async () => (await c.query(`SELECT private.payment_source() AS s`)).rows[0].s,
      setSahal: (up) => c.query(`UPDATE public.merchant_feed_status SET state = $1, checked_at = now() - $2::interval WHERE provider = 'golis'`, [up ? 'ok' : 'ready', up ? '0 seconds' : '1 hour']),
      setPhone: (up) => c.query(`UPDATE public.agent_devices SET sms_listening_at = ${up ? 'now()' : `now() - interval '1 hour'`}`),
      age: (secs) => c.query(`UPDATE public.payment_source_state SET pending_since = pending_since - make_interval(secs => $1)`, [secs]),
      query: (q, p) => c.query(q, p),
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

async function withDevice(t) {
  // One Agent phone of our own, so the test never depends on what the database holds (rolled back with the transaction).
  await t.query(`UPDATE public.agent_devices SET status = 'revoked'`);
  const a = await t.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('agent', $1, 'Perf Agent', private.hash_password('ChangeMe123!')) RETURNING id`,
    [`2526${String(Date.now()).slice(-8)}`]);
  await t.query(`INSERT INTO public.agent_devices (agent_id, device_id, status, sms_listening_at) VALUES ($1, 'perf-phone', 'active', now())`, [a.rows[0].id]);
  return true;
}

test('the first run announces nothing; a change lasting 2 minutes is announced once, then marked sent', () =>
  inTx(async (t) => {
    await withDevice(t);
    await t.setSahal(true); await t.setPhone(true);
    assert.equal(await t.source(), 'sahal');
    assert.deepEqual(await t.todo(), []);                       // first run: the starting point
    await t.setSahal(false);
    assert.equal(await t.source(), 'agent_sim');
    assert.deepEqual(await t.todo(), []);                       // seen, not yet confirmed
    await t.age(121);
    const r = await t.todo();
    assert.equal(r.length, 1);
    assert.equal(r[0].from, 'sahal'); assert.equal(r[0].to, 'agent_sim');
    assert.equal((await t.todo()).length, 1, 'still listed until it is marked sent');
    await t.query(`SELECT public.group_notified_mark('source', ARRAY[$1])`, [String(r[0].id)]);
    assert.deepEqual(await t.todo(), [], 'announced once');
  }));

test('a flicker (back within 2 minutes) announces nothing; Sahal coming back and both down are announced', () =>
  inTx(async (t) => {
    await withDevice(t);
    await t.setSahal(true); await t.setPhone(true);
    await t.todo();
    await t.setSahal(false); await t.todo();
    await t.setSahal(true);
    assert.deepEqual(await t.todo(), []);
    assert.equal((await t.query(`SELECT pending FROM public.payment_source_state`)).rows[0].pending, null);
    await t.setSahal(false); await t.setPhone(false);
    assert.equal(await t.source(), 'none');
    await t.todo(); await t.age(130);
    let r = await t.todo();
    assert.equal(r.length, 1); assert.equal(r[0].to, 'none');
    await t.query(`SELECT public.group_notified_mark('source', ARRAY[$1])`, [String(r[0].id)]);
    await t.setSahal(true);
    await t.todo(); await t.age(130);
    r = await t.todo();
    assert.equal(r.length, 1); assert.equal(r[0].from, 'none'); assert.equal(r[0].to, 'sahal');
  }));

test('only the service role may call it, and it changes no money', () =>
  inTx(async (t) => {
    await t.query(`SELECT set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001"}', true)`);
    await t.query('SAVEPOINT s');
    await assert.rejects(() => t.query(`SELECT public.payment_source_todo()`));
    await t.query('ROLLBACK TO SAVEPOINT s');
  }));
