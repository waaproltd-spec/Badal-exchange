// Customer App Dalabaadka (migrations/*_customer_order_counts.sql): the summary cards come from the database, total = deposits +
// withdrawals, they match the list the customer can read, the list pages without repeats, and one customer never sees another's.
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
      const u = await c.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Counts Test', private.hash_password('ChangeMe123!')) RETURNING id`, [phone]);
      await c.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, 0)`, [u.rows[0].id]);
      return u.rows[0].id;
    };
    const order = (cust, direction, status, minutesAgo) => c.query(
      `INSERT INTO public.orders (order_code, customer_id, direction, method, status, amount_cents, rate, net_cents, wallet_delta_cents, created_at)
       VALUES ('EX' || substr(gen_random_uuid()::text, 1, 10), $1, $2, 'evc_plus', $3, 500, 1, 500, 0, now() - make_interval(mins => $4))`,
      [cust, direction, status, minutesAgo]);
    const as = async (id) => c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: id, role: 'authenticated', aud: 'authenticated' })]);
    const rpc = async (id, sql, params = []) => { await as(id); return (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r; };
    return await fn({ c, customer, order, rpc });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

test('the counts are real and add up: total = deposits + withdrawals; unpaid deposits are not part of the list nor of the cards', () =>
  inTx(async (t) => {
    const a = await t.customer();
    const b = await t.customer();
    let m = 0;
    for (let i = 0; i < 5; i++) await t.order(a, 'deposit', 'completed', ++m);
    for (let i = 0; i < 3; i++) await t.order(a, 'deposit', 'pending', ++m);      // not shown anywhere until paid
    await t.order(a, 'deposit', 'failed', ++m);                                    // an unpaid / failed deposit is not listed either
    for (const s of ['completed', 'completed', 'failed', 'pending', 'processing', 'cancelled', 'expired']) await t.order(a, 'withdraw', s, ++m);
    await t.order(b, 'withdraw', 'completed', ++m);
    const counts = await t.rpc(a, 'public.customer_order_counts()');
    assert.deepEqual(counts, { total: 12, deposits: 5, withdrawals: 7 });
    assert.equal(counts.total, counts.deposits + counts.withdrawals);
    // the cards match what the list can reach, page by page, for each tab
    const all = [];
    for (let off = 0; ; off += 4) {
      const page = await t.rpc(a, 'public.customer_orders($1, $2, NULL)', [4, off]);
      if (!page.length) break;
      all.push(...page);
    }
    assert.equal(all.length, counts.total);
    assert.equal(new Set(all.map((o) => o.id)).size, all.length, 'no order twice');
    for (const [dir, key] of [['deposit', 'deposits'], ['withdraw', 'withdrawals']]) {
      const rows = [];
      for (let off = 0; ; off += 3) {
        const page = await t.rpc(a, 'public.customer_orders($1, $2, $3)', [3, off, dir]);
        if (!page.length) break;
        rows.push(...page);
      }
      assert.equal(rows.length, counts[key], dir);
      assert.ok(rows.every((o) => o.direction === dir), 'each order belongs to one tab');
    }
    assert.deepEqual(all.map((o) => o.createdAt), [...all.map((o) => o.createdAt)].sort().reverse(), 'newest first');
    assert.deepEqual(await t.rpc(b, 'public.customer_order_counts()'), { total: 1, deposits: 0, withdrawals: 1 }, 'only the customer\'s own orders');
    // the list without arguments is the same as before: the newest 100
    assert.equal((await t.rpc(a, 'public.customer_orders()')).length, 12);
  }));

test('a bad direction is refused; a customer with no orders gets zeros and an empty list; only customers may call', () =>
  inTx(async (t) => {
    const a = await t.customer();
    assert.deepEqual(await t.rpc(a, 'public.customer_order_counts()'), { total: 0, deposits: 0, withdrawals: 0 });
    assert.deepEqual(await t.rpc(a, 'public.customer_orders()'), []);
    await t.c.query('SAVEPOINT s');
    await assert.rejects(() => t.rpc(a, `public.customer_orders(10, 0, 'transfer')`));
    await t.c.query('ROLLBACK TO SAVEPOINT s');
    await t.c.query(`SELECT set_config('request.jwt.claims', '{"role":"anon"}', true)`);
    await assert.rejects(() => t.c.query(`SELECT public.customer_order_counts()`));
  }));
