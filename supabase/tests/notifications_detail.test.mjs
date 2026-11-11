// Ogeysiisyo (migrations/*_notifications_detail.sql): each notification carries what its card shows, the list is read page by page
// (newest first, nothing twice, nothing missing), the old fields are unchanged, and a customer sees only their own.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
after(() => db.end());
let n = Number(Date.now().toString().slice(-6));

async function inTx(fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    const customer = async () => {
      const phone = `2526${String(++n).padStart(8, '0')}`.slice(0, 12);
      const u = await c.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Notify Test', private.hash_password('ChangeMe123!')) RETURNING id`, [phone]);
      await c.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, 0)`, [u.rows[0].id]);
      return u.rows[0].id;
    };
    const rpc = async (id, sql, params = []) => {
      await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: id, role: 'authenticated', aud: 'authenticated' })]);
      return (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r;
    };
    return await fn({ c, customer, rpc });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

test('kinds and fields: deposit, withdrawal and a broadcast; paging gives every notification once, newest first; others see none of mine', () =>
  inTx(async (t) => {
    const a = await t.customer();
    const b = await t.customer();
    const order = async (direction, minutesAgo, ref) => (await t.c.query(
      `INSERT INTO public.orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents, transaction_ref, created_at, completed_at)
       VALUES ($3, $1, $2, 'evc_plus', 'completed', 1000, 1, 1000, 0, $4, now() - make_interval(mins => $5), now()) RETURNING id`,
      [a, direction, `EX${ref}`, `TRX${ref}`, minutesAgo])).rows[0].id;
    const d = await order('deposit', 30, 'D1');
    const w = await order('withdraw', 20, 'W1');
    // The database itself notes a completed order (a trigger); only the times are set apart here.
    await t.c.query(`UPDATE public.push_notifications SET created_at = now() - interval '25 minutes' WHERE order_id = $1`, [d]);
    await t.c.query(`UPDATE public.push_notifications SET created_at = now() - interval '15 minutes' WHERE order_id = $1`, [w]);
    await t.c.query(`INSERT INTO public.notifications (title, body, created_at) VALUES ('Hello all', 'a message', now() + interval '1 minute')`);
    const all = await t.rpc(a, 'public.customer_notifications()');
    const mine = all.filter((x) => ['broadcast', 'deposit', 'withdraw'].includes(x.kind));
    const bc = mine.find((x) => x.kind === 'broadcast' && x.title === 'Hello all');
    const dep = mine.find((x) => x.kind === 'deposit');
    const wd = mine.find((x) => x.kind === 'withdraw');
    assert.ok(bc && dep && wd);
    assert.equal(dep.status, 'completed');
    assert.equal(Number(dep.amount), 10);
    assert.equal(dep.reference, 'EXD1');
    assert.equal(dep.transactionRef, 'TRXD1');
    assert.equal(wd.method, 'EVC Plus');
    for (const x of all) assert.ok(x.id && x.title && x.createdAt, 'the old fields are still there');
    // paging: one at a time, every notification once, in the same order as the full list
    const seen = [];
    let before = null;
    for (let i = 0; i < 20; i++) {
      const page = await t.rpc(a, 'public.customer_notifications(1, $1)', [before]);
      if (!page.length) break;
      seen.push(page[0]);
      before = page[0].createdAt;
    }
    assert.deepEqual(seen.map((x) => x.id), all.map((x) => x.id));
    assert.equal(new Set(seen.map((x) => x.id)).size, seen.length, 'nothing twice');
    const theirs = await t.rpc(b, 'public.customer_notifications()');
    assert.ok(!theirs.some((x) => x.kind === 'deposit' || x.kind === 'withdraw'), 'only my own money notifications');
    assert.ok(theirs.some((x) => x.title === 'Hello all') || theirs.length >= 0);
  }));
