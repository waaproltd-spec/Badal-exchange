// "Money seen, not confirmed" notice (migrations/*_deposit_unconfirmed_notice.sql): a payment SMS or a Sahal transfer that is still
// unmatched after 10 minutes is listed once; fresh ones, matched ones, SIM-check refusals, old ones (before the switch-on) are not.
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
    await c.query(`UPDATE public.app_settings SET value = (now() - interval '2 days')::text WHERE key = 'unconfirmed_notice_since'`);
    await c.query(`UPDATE public.sms_logs SET match_status = 'ignored' WHERE match_status = 'unmatched'`);
    await c.query(`ALTER TABLE public.sms_logs DISABLE TRIGGER USER`);
    return await fn({
      todo: async () => (await c.query(`SELECT public.deposit_unconfirmed_todo() AS r`)).rows[0].r,
      sms: async (minutesAgo, amount, status = 'unmatched', reason = null) => (await c.query(
        `INSERT INTO public.sms_logs (sender, body, received_at, match_status, match_failure_reason, parsed_provider, parsed_phone, parsed_amount)
         VALUES ('perf', 'unconfirmed ' || gen_random_uuid(), now() - make_interval(mins => $1), $3, $4, 'EVC Plus', '252615000111', $2) RETURNING id`,
        [minutesAgo, amount, status, reason])).rows[0].id,
      query: (q, p) => c.query(q, p),
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

test('an SMS unmatched for 10+ minutes is listed once; fresh, matched, SIM-refused and pre-switch-on ones are not', () =>
  inTx(async (t) => {
    const old = await t.sms(15, 12.5);
    await t.sms(3, 5);                                    // too fresh
    await t.sms(20, 7, 'matched');                        // already matched
    await t.sms(20, 9, 'unmatched', 'Rejected by the wallet phone/SIM check: expects the evc_plus wallet');
    await t.sms(30 * 60, 4);                               // more than 24 h old
    const r = await t.todo();
    assert.equal(r.length, 1);
    assert.equal(r[0].key, `sms:${old}`);
    assert.equal(r[0].source, 'sms');
    assert.equal(Number(r[0].amount), 12.5);
    assert.ok(r[0].minutes >= 14);
    await t.query(`SELECT public.group_notified_mark('unconfirmed', ARRAY[$1])`, [r[0].key]);
    assert.deepEqual(await t.todo(), [], 'said once');
    await t.query(`UPDATE public.app_settings SET value = (now() + interval '1 day')::text WHERE key = 'unconfirmed_notice_since'`);
    await t.sms(40, 3);
    assert.deepEqual(await t.todo(), [], 'a payment from before the switch-on is not announced');
  }));

test('a Sahal incoming transfer matching no deposit is listed; a paired or matched one is not; only the service role may call', () =>
  inTx(async (t) => {
    const ins = (id, status, minutes, extra = '') => t.query(
      `INSERT INTO public.merchant_transactions (provider, transaction_id, raw, direction, match_status, payer_phone, amount_cents, first_seen_at)
       VALUES ('golis', $1, '{}'::jsonb, 'in', $2, '252615000222', 2500, now() - make_interval(mins => $3)) RETURNING id`, [id, status, minutes]);
    const a = (await ins('uc-a', 'unmatched', 20)).rows[0].id;
    await ins('uc-b', 'matched', 20);
    await ins('uc-c', 'unmatched', 2);
    const r = await t.todo();
    assert.equal(r.length, 1);
    assert.equal(r[0].key, `sahal:${a}`);
    assert.equal(Number(r[0].amount), 25);
    await t.query(`SELECT set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001"}', true)`);
    await t.query('SAVEPOINT s');
    await assert.rejects(() => t.query(`SELECT public.deposit_unconfirmed_todo()`));
    await t.query('ROLLBACK TO SAVEPOINT s');
  }));
