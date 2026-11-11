// Performance optimizations (migrations/20261111000500_performance_optimizations.sql): writes that would store the same value
// again are skipped, a real change is always written, and the worker wake-up gates run without error.
// Every test runs in a transaction that is rolled back.
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
    return await fn(c);
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}
const ctid = async (c, sql, params = []) => (await c.query(sql, params)).rows[0].ctid;

test('an SMS update that changes nothing is skipped; a real change is written', () =>
  inTx(async (c) => {
    const { rows } = await c.query(`INSERT INTO public.sms_logs (sender, body, received_at, match_status, match_failure_reason)
      VALUES ('perf', 'perf test ' || gen_random_uuid(), now(), 'unmatched', 'same reason') RETURNING id`);
    const id = rows[0].id;
    const before = await ctid(c, `SELECT ctid::text FROM public.sms_logs WHERE id = $1`, [id]);
    await c.query(`UPDATE public.sms_logs SET match_failure_reason = 'same reason' WHERE id = $1`, [id]);
    assert.equal(await ctid(c, `SELECT ctid::text FROM public.sms_logs WHERE id = $1`, [id]), before, 'identical update must not rewrite the row');
    await c.query(`UPDATE public.sms_logs SET match_failure_reason = 'another reason' WHERE id = $1`, [id]);
    assert.notEqual(await ctid(c, `SELECT ctid::text FROM public.sms_logs WHERE id = $1`, [id]), before);
    assert.equal((await c.query(`SELECT match_failure_reason FROM public.sms_logs WHERE id = $1`, [id])).rows[0].match_failure_reason, 'another reason');
    await c.query(`UPDATE public.sms_logs SET match_status = 'ignored' WHERE id = $1`, [id]);
    assert.equal((await c.query(`SELECT match_status FROM public.sms_logs WHERE id = $1`, [id])).rows[0].match_status, 'ignored');
  }));

test('feed sessions: a "still here" save is skipped for 5 minutes, new cookies are written at once, an old time stamp is refreshed', () =>
  inTx(async (c) => {
    await c.query(`ALTER TABLE private.merchant_feed_sessions DISABLE TRIGGER zz_heartbeat`);
    await c.query(`INSERT INTO private.merchant_feed_sessions (provider, session_id, cookies, updated_at) VALUES ('perf', 's1', 'c1', now())
                   ON CONFLICT (provider) DO UPDATE SET session_id = 's1', cookies = 'c1', updated_at = now()`);
    await c.query(`ALTER TABLE private.merchant_feed_sessions ENABLE TRIGGER zz_heartbeat`);
    const q = `SELECT ctid::text FROM private.merchant_feed_sessions WHERE provider = 'perf'`;
    const a = await ctid(c, q);
    await c.query(`UPDATE private.merchant_feed_sessions SET cookies = 'c1', updated_at = now() WHERE provider = 'perf'`);
    assert.equal(await ctid(c, q), a, 'same cookies, fresh time stamp: skipped');
    await c.query(`UPDATE private.merchant_feed_sessions SET cookies = 'c2', updated_at = now() WHERE provider = 'perf'`);
    const b = await ctid(c, q);
    assert.notEqual(b, a, 'new cookies are written');
    await c.query(`ALTER TABLE private.merchant_feed_sessions DISABLE TRIGGER zz_heartbeat`);
    await c.query(`UPDATE private.merchant_feed_sessions SET updated_at = now() - interval '10 minutes' WHERE provider = 'perf'`);
    await c.query(`ALTER TABLE private.merchant_feed_sessions ENABLE TRIGGER zz_heartbeat`);
    const d = await ctid(c, q);
    await c.query(`UPDATE private.merchant_feed_sessions SET cookies = 'c2', updated_at = now() WHERE provider = 'perf'`);
    assert.notEqual(await ctid(c, q), d, 'a stale time stamp is refreshed');
  }));

test('feed status: the same state within 30 seconds is skipped; a state change or rows seen is written at once', () =>
  inTx(async (c) => {
    const { rows } = await c.query(`SELECT provider FROM public.merchant_feed_status LIMIT 1`);
    if (!rows.length) return; // no feed row in this database
    const p = rows[0].provider;
    await c.query(`ALTER TABLE public.merchant_feed_status DISABLE TRIGGER zz_heartbeat`);
    await c.query(`UPDATE public.merchant_feed_status SET state = 'ok', result_code = 'ok', message = 'm', rows_seen = 5, checked_at = now(), last_ok_at = now(), updated_at = now() WHERE provider = $1`, [p]);
    await c.query(`ALTER TABLE public.merchant_feed_status ENABLE TRIGGER zz_heartbeat`);
    const q = `SELECT ctid::text FROM public.merchant_feed_status WHERE provider = '${p}'`;
    const a = await ctid(c, q);
    await c.query(`UPDATE public.merchant_feed_status SET state = 'ok', result_code = 'ok', message = 'm', checked_at = now(), last_ok_at = now(), updated_at = now() WHERE provider = $1`, [p]);
    assert.equal(await ctid(c, q), a, 'same state, fresh heartbeat: skipped');
    await c.query(`UPDATE public.merchant_feed_status SET state = 'signing_in', result_code = 'error', checked_at = now(), updated_at = now() WHERE provider = $1`, [p]);
    const b = await ctid(c, q);
    assert.notEqual(b, a, 'a state change is written');
    await c.query(`UPDATE public.merchant_feed_status SET rows_seen = rows_seen + 1, checked_at = now(), updated_at = now() WHERE provider = $1`, [p]);
    assert.notEqual(await ctid(c, q), b, 'new rows seen are written');
  }));

test('company balances: a third identical read only moves the time of the newest row; a change, an error or a person\'s read is a new row', () =>
  inTx(async (c) => {
    const m = (await c.query(`SELECT method FROM public.payment_methods WHERE private.is_cashdesk_method(method) ORDER BY sort_order LIMIT 1`)).rows[0]?.method;
    if (!m) return;
    await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ role: 'service_role' })]);
    await c.query(`DELETE FROM public.cashdesk_balances WHERE method = $1`, [m]);
    const count = async () => Number((await c.query(`SELECT count(*) FROM public.cashdesk_balances WHERE method = $1`, [m])).rows[0].count);
    const rec = (bal, lim, err = null, by = null) => c.query(`SELECT public.company_balance_record($1, $2, $3, $4, $5)`, [m, bal, lim, err, by]);
    await rec(100, 500); await rec(100, 500);
    assert.equal(await count(), 2);
    await c.query(`UPDATE public.cashdesk_balances SET checked_at = now() - interval '1 hour' WHERE method = $1`, [m]);
    await rec(100, 500);
    assert.equal(await count(), 2, 'the third identical read adds no row');
    const newest = (await c.query(`SELECT balance_cents, checked_at > now() - interval '1 minute' AS fresh FROM public.cashdesk_balances WHERE method = $1 ORDER BY checked_at DESC LIMIT 1`, [m])).rows[0];
    assert.equal(Number(newest.balance_cents), 10000);
    assert.equal(newest.fresh, true, 'the newest row carries the time of the last read (freshness checks read it)');
    await rec(90, 500);
    assert.equal(await count(), 3, 'a changed balance is a new row');
    await rec(null, null, 'down');
    assert.equal(await count(), 4, 'an error is a new row');
    const { rows: [u] } = await c.query(`SELECT id FROM public.users LIMIT 1`);
    await rec(90, 500, null, u.id);
    assert.equal(await count(), 5, 'a read asked by a person is always a row');
  }));

test('housekeeping runs without error and the worker wake-up gates run', () =>
  inTx(async (c) => {
    const r = (await c.query(`SELECT private.housekeeping() AS r`)).rows[0].r;
    assert.notEqual(r.error, true);
    await c.query(`SELECT private.platform_kick_if_work()`);
    await c.query(`SELECT private.broadcast_kick()`);
    await c.query(`SELECT private.withdrawal_alerts_kick()`);
    // The gate queries themselves (the kick functions swallow errors by design, so run the SQL directly).
    await c.query(`SELECT EXISTS (SELECT 1 FROM public.broadcast_schedules WHERE status = 'active' AND deleted_at IS NULL AND next_run_at <= now())
        OR EXISTS (SELECT 1 FROM public.broadcast_deliveries WHERE status = 'pending')
        OR EXISTS (SELECT 1 FROM public.broadcast_deliveries WHERE status = 'sending' AND claimed_at < now() - interval '5 minutes')`);
    await c.query(`SELECT EXISTS (SELECT 1 FROM public.orders o WHERE o.direction = 'withdraw'
        AND (o.status IN ('pending', 'processing') OR o.updated_at > now() - interval '30 minutes'))`);
    await c.query(`SELECT EXISTS (SELECT 1 FROM public.orders o WHERE o.status = 'pending' AND o.auto_claimed_at IS NULL
        AND o.created_at > now() - interval '1 day' AND private.platform_eligible(o))`);
    const idx = (await c.query(`SELECT indexname FROM pg_indexes WHERE indexname IN ('dev_audit_recent', 'idx_cashdesk_balances_requested_by')`)).rows;
    assert.equal(idx.length, 0);
  }));
