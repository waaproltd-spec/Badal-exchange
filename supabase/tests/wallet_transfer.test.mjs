// Wallet to wallet transfers (migrations/*_wallet_transfers.sql): free, immediate, in ONE transaction on the existing wallets, with a 4-digit
// Wallet PIN (hashed, 5 wrong tries lock it), idempotent, no sending to yourself, a name check of the recipient, history and notifications for
// both customers. Every test runs in a transaction that is rolled back, except the concurrency test, which cleans up after itself.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 8 });
after(() => db.end());
const PASSWORD = 'ChangeMe123!';
let n = Number(Date.now().toString().slice(-6));

async function inTx(fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    await c.query(`UPDATE public.app_settings SET value = 'off' WHERE key = 'withdrawal_verification'`);
    await c.query(`INSERT INTO public.app_settings (key, value) VALUES ('withdrawal_verification', 'off') ON CONFLICT (key) DO UPDATE SET value = 'off'`);
    const as = (id, role = 'authenticated') => c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify(id ? { sub: id, role, aud: 'authenticated' } : { role })]);
    return await fn({
      as,
      call: async (id, sql, params = []) => { await as(id); return (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r; },
      query: (sql, params) => c.query(sql, params),
      customer: async (name, cents = 0) => {
        const phone = `2526${String(++n).padStart(8, '0')}`.slice(0, 12);
        const u = await c.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, $2, private.hash_password($3)) RETURNING id`, [phone, name, PASSWORD]);
        const w = await c.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, $2) RETURNING wallet_code`, [u.rows[0].id, cents]);
        return { id: u.rows[0].id, phone, code: w.rows[0].wallet_code, name };
      },
    });
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}
const key = () => randomUUID();
const bal = async (t, id) => Number((await t.query(`SELECT available_cents FROM public.wallets WHERE customer_id = $1`, [id])).rows[0].available_cents);
const expectError = async (t, id, sql, params, re) => {
  await t.query('SAVEPOINT s');
  await t.as(id);
  await assert.rejects(() => t.query(`SELECT ${sql}`, params), re);
  await t.query('ROLLBACK TO SAVEPOINT s');
};

test('a transfer is free and immediate: the sender is debited, the recipient credited, both ledger entries, the history and a notification for each', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 10000);
    const b = await t.customer('Bilan Receiver', 500);
    assert.equal((await t.call(a.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD])).ok, true);
    const r = await t.call(a.id, `public.customer_wallet_transfer($1, '25.50', '4827', $2)`, [b.code, key()]);
    assert.equal(r.ok, true);
    assert.equal(r.direction, 'sent');
    assert.equal(r.amount, '25.50');
    assert.equal(r.fee, '0.00');
    assert.equal(r.counterpartName, 'Bilan Receiver');
    assert.equal(r.counterpartWalletId, b.code);
    assert.match(r.reference, /^TRF[0-9A-F]{8}$/);
    assert.equal(await bal(t, a.id), 7450);
    assert.equal(await bal(t, b.id), 3050);
    assert.equal(r.balanceAfter, '74.50');
    // the existing wallet system: ledger entries, nothing else moved
    const ledger = (await t.query(`SELECT e.entry_type, e.amount_cents, e.balance_after_cents, e.reason, w.customer_id FROM public.ledger_entries e JOIN public.wallets w ON w.id = e.wallet_id
                                    WHERE e.reason LIKE '%' || $1 ORDER BY e.entry_type`, [r.reference])).rows;
    assert.deepEqual(ledger.map((l) => [l.entry_type, Number(l.amount_cents), Number(l.balance_after_cents), l.customer_id]),
      [['credit', 2550, 3050, b.id], ['debit', 2550, 7450, a.id]]);
    const row = (await t.query(`SELECT * FROM public.wallet_transfers WHERE reference = $1`, [r.reference])).rows[0];
    assert.equal(Number(row.fee_cents), 0);
    assert.equal(Number(row.amount_cents), 2550);
    // history of both
    const mine = await t.call(a.id, `public.customer_wallet_transfers(10)`);
    const theirs = await t.call(b.id, `public.customer_wallet_transfers(10)`);
    assert.deepEqual([mine[0].direction, mine[0].counterpartName, mine[0].amount], ['sent', 'Bilan Receiver', '25.50']);
    assert.deepEqual([theirs[0].direction, theirs[0].counterpartName, theirs[0].amount, theirs[0].balanceAfter], ['received', 'Axmed Sender', '25.50', '30.50']);
    // a phone notification queued for each, and an entry in each Notifications list
    const pushes = (await t.query(`SELECT customer_id, kind FROM public.push_notifications WHERE transfer_id = $1 ORDER BY kind`, [row.id])).rows;
    assert.deepEqual(pushes.map((p) => [p.kind, p.customer_id]), [['transfer_received', b.id], ['transfer_sent', a.id]]);
    const na = await t.call(a.id, `public.customer_notifications()`);
    const nb = await t.call(b.id, `public.customer_notifications()`);
    assert.match(na[0].title, /Lacag ayaad dirtay/);
    assert.match(na[0].body, /Bilan Receiver/);
    assert.match(nb[0].title, /Lacag ayaa laguu soo diray/);
    assert.match(nb[0].body, /Axmed Sender/);
    assert.ok(nb[0].body.includes('25.50') && na[0].body.includes('25.50'));
    // the audit trail
    assert.equal((await t.query(`SELECT count(*)::int AS n FROM public.audit_logs WHERE action = 'wallet.transfer' AND entity_id = $1`, [row.id])).rows[0].n, 1);
  }));

test('lookup: the recipient name is shown (and only the name), your own ID is flagged, an unknown or blocked one is not found, 10 a minute', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 100);
    const b = await t.customer('Bilan Receiver', 0);
    const found = await t.call(a.id, `public.customer_transfer_lookup($1)`, [` ${b.code.toLowerCase()} `]);
    assert.deepEqual(found, { found: true, self: false, walletId: b.code, name: 'Bilan Receiver' });
    assert.deepEqual(await t.call(a.id, `public.customer_transfer_lookup($1)`, [a.code]), { found: true, self: true, walletId: a.code });
    assert.deepEqual(await t.call(a.id, `public.customer_transfer_lookup('BE000000')`), { found: false });
    await t.query(`UPDATE public.users SET status = 'disabled' WHERE id = $1`, [b.id]);
    assert.deepEqual(await t.call(a.id, `public.customer_transfer_lookup($1)`, [b.code]), { found: false });
    await expectError(t, a.id, `public.customer_transfer_lookup('12345')`, [], /Wallet ID/);
    for (let i = 0; i < 6; i++) await t.call(a.id, `public.customer_transfer_lookup('BE000000')`);       // 10 in all this minute
    await expectError(t, a.id, `public.customer_transfer_lookup('BE000000')`, [], /Isku-day badan/);
  }));

test('the Wallet PIN: 4 digits, not a weak one, set with the account password; a wrong password is counted and limited', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 0);
    assert.deepEqual(await t.call(a.id, `public.customer_wallet_pin_status()`), { hasPin: false, locked: false, lockedUntil: null });
    for (const bad of ['123', '12345', 'abcd', '1111', '1234', '0000', '4321']) {
      await expectError(t, a.id, `public.customer_set_wallet_pin($1, $2)`, [bad, PASSWORD], /PIN|lambar/i);
    }
    assert.deepEqual(await t.call(a.id, `public.customer_set_wallet_pin('4827', 'wrong password')`), { ok: false, code: 'WRONG_PASSWORD' });
    assert.equal((await t.call(a.id, `public.customer_wallet_pin_status()`)).hasPin, false);
    assert.deepEqual(await t.call(a.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD]), { ok: true });
    assert.equal((await t.call(a.id, `public.customer_wallet_pin_status()`)).hasPin, true);
    const stored = (await t.query(`SELECT pin_hash FROM public.wallet_pins WHERE customer_id = $1`, [a.id])).rows[0].pin_hash;
    assert.match(stored, /^\$2[aby]\$/, 'a bcrypt hash');
    assert.ok(!stored.includes('4827'));
    // changing it needs the password again
    assert.equal((await t.call(a.id, `public.customer_set_wallet_pin('7391', $1)`, [PASSWORD])).ok, true);
    // 5 wrong passwords in 15 minutes: refused
    const b = await t.customer('Bilan', 0);
    for (let i = 0; i < 5; i++) assert.equal((await t.call(b.id, `public.customer_set_wallet_pin('4827', 'nope')`)).ok, false);
    await expectError(t, b.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD], /Isku-day badan/);
  }));

test('a wrong PIN moves nothing and is counted; the fifth locks sending for 15 minutes, even for the right PIN', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 5000);
    const b = await t.customer('Bilan Receiver', 0);
    await t.call(a.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD]);
    const go = (pin) => t.call(a.id, `public.customer_wallet_transfer($1, '5', $2, $3)`, [b.code, pin, key()]);
    assert.deepEqual(await go('1111'), { ok: false, code: 'WRONG_PIN', attemptsLeft: 4 });
    assert.deepEqual(await go('abcd'), { ok: false, code: 'WRONG_PIN', attemptsLeft: 3 });
    assert.deepEqual(await go('2222'), { ok: false, code: 'WRONG_PIN', attemptsLeft: 2 });
    assert.deepEqual(await go('3333'), { ok: false, code: 'WRONG_PIN', attemptsLeft: 1 });
    const locked = await go('5555');
    assert.equal(locked.ok, false);
    assert.equal(locked.code, 'PIN_LOCKED');
    assert.ok(new Date(locked.lockedUntil).getTime() > Date.now() + 14 * 60_000);
    assert.equal((await go('4827')).code, 'PIN_LOCKED', 'the right PIN does not help while it is locked');
    assert.equal(await bal(t, a.id), 5000);
    assert.equal(await bal(t, b.id), 0);
    assert.equal((await t.call(a.id, `public.customer_wallet_pin_status()`)).locked, true);
    // after the wait the right PIN works, and a right PIN resets the counter
    await t.query(`UPDATE public.wallet_pins SET locked_until = now() - interval '1 second' WHERE customer_id = $1`, [a.id]);
    assert.equal((await go('4827')).ok, true);
    assert.equal(Number((await t.query(`SELECT failed_attempts FROM public.wallet_pins WHERE customer_id = $1`, [a.id])).rows[0].failed_attempts), 0);
  }));

test('the same request twice is one transfer; the same key for a different request is refused', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 5000);
    const b = await t.customer('Bilan Receiver', 0);
    const c = await t.customer('Cali Other', 0);
    await t.call(a.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD]);
    const k = key();
    const first = await t.call(a.id, `public.customer_wallet_transfer($1, '10', '4827', $2)`, [b.code, k]);
    const again = await t.call(a.id, `public.customer_wallet_transfer($1, '10', '4827', $2)`, [b.code, k]);
    assert.equal(first.replayed, false);
    assert.equal(again.replayed, true);
    assert.equal(again.reference, first.reference);
    assert.equal(await bal(t, a.id), 4000, 'debited once');
    assert.equal(await bal(t, b.id), 1000, 'credited once');
    assert.equal((await t.query(`SELECT count(*)::int AS n FROM public.wallet_transfers WHERE from_customer_id = $1`, [a.id])).rows[0].n, 1);
    assert.equal((await t.query(`SELECT count(*)::int AS n FROM public.push_notifications WHERE transfer_id = $1`, [first.id])).rows[0].n, 2);
    await expectError(t, a.id, `public.customer_wallet_transfer($1, '11', '4827', $2)`, [b.code, k], /horey ayaa loo isticmaalay/);
    await expectError(t, a.id, `public.customer_wallet_transfer($1, '10', '4827', $2)`, [c.code, k], /horey ayaa loo isticmaalay/);
    assert.equal(await bal(t, a.id), 4000);
  }));

test('refused: yourself, an unknown / blocked recipient, more than the balance, a bad amount, no PIN set, an unapproved account; nothing moves', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 1000);
    const b = await t.customer('Bilan Receiver', 0);
    const send = (to, amount, pin = '4827') => [`public.customer_wallet_transfer($1, $2, $3, $4)`, [to, amount, pin, key()]];
    await expectError(t, a.id, ...send(b.code, '5'), /Marka hore samee Wallet PIN/);
    await t.call(a.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD]);
    await expectError(t, a.id, ...send(a.code, '5'), /Naftaada/);
    await expectError(t, a.id, ...send('BE000000', '5'), /lama helin/);
    await expectError(t, a.id, ...send('nonsense', '5'), /Wallet ID/);
    await expectError(t, a.id, ...send(b.code, '10.01'), /kuma filna/);
    for (const bad of ['0', '-5', 'abc', '', '1e3', '0.001']) await expectError(t, a.id, ...send(b.code, bad), /./);
    await t.query(`UPDATE public.users SET status = 'disabled' WHERE id = $1`, [b.id]);
    await expectError(t, a.id, ...send(b.code, '5'), /lama helin/);
    await t.query(`UPDATE public.users SET status = 'active' WHERE id = $1`, [b.id]);
    // an account that may not withdraw yet (the admin's first-withdrawal approval) can not use a transfer to get round it
    await t.query(`UPDATE public.app_settings SET value = 'on' WHERE key = 'withdrawal_verification'`);
    await expectError(t, a.id, ...send(b.code, '5'), /lama fasaxin/);
    assert.equal(await bal(t, a.id), 1000);
    assert.equal(await bal(t, b.id), 0);
    assert.equal((await t.query(`SELECT count(*)::int AS n FROM public.wallet_transfers`)).rows[0].n >= 0, true);
  }));

test('only the signed-in customer: not anonymous, not staff; the tables are not readable from the app', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 100);
    const staff = (await t.query(`SELECT id FROM public.users WHERE role <> 'customer' AND status = 'active' LIMIT 1`)).rows[0].id;
    for (const sql of [`public.customer_wallet_pin_status()`, `public.customer_wallet_transfers(5)`, `public.customer_transfer_lookup('BE000000')`,
                       `public.customer_set_wallet_pin('4827', 'x')`, `public.customer_wallet_transfer('BE000000', '1', '4827', 'abcdefgh1')`]) {
      await t.query('SAVEPOINT s');
      await t.as(null, 'anon');
      await t.query('SET LOCAL ROLE anon');
      await assert.rejects(() => t.query(`SELECT ${sql}`), /permission denied|FORBIDDEN|Unauthorized|JWT/i, `anon ${sql}`);
      await t.query('ROLLBACK TO SAVEPOINT s');
      await t.query('SAVEPOINT s');
      await t.as(staff);
      await assert.rejects(() => t.query(`SELECT ${sql}`), /Forbidden|FORBIDDEN/i, `staff ${sql}`);
      await t.query('ROLLBACK TO SAVEPOINT s');
    }
    for (const table of ['wallet_pins', 'wallet_transfers', 'wallet_transfer_events']) {
      await t.query('SAVEPOINT s');
      await t.as(a.id);
      await t.query('SET LOCAL ROLE authenticated');
      await assert.rejects(() => t.query(`SELECT * FROM public.${table}`), /permission denied/i, table);
      await t.query('ROLLBACK TO SAVEPOINT s');
    }
  }));

test('the fee column can only be zero and a transfer can not be to yourself (the table says so too)', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 100);
    const b = await t.customer('Bilan Receiver', 0);
    const wa = (await t.query(`SELECT id FROM public.wallets WHERE customer_id = $1`, [a.id])).rows[0].id;
    const wb = (await t.query(`SELECT id FROM public.wallets WHERE customer_id = $1`, [b.id])).rows[0].id;
    const insert = (from, to, wf, wt, fee) => t.query(`INSERT INTO public.wallet_transfers (reference, from_customer_id, to_customer_id, from_wallet_id, to_wallet_id, amount_cents, fee_cents, from_balance_after, to_balance_after, idempotency_key)
      VALUES ($1, $2, $3, $4, $5, 100, $6, 0, 0, $7)`, [`TRF${randomUUID().slice(0, 8).toUpperCase()}`, from, to, wf, wt, fee, key()]);
    await t.query('SAVEPOINT s');
    await assert.rejects(() => insert(a.id, b.id, wa, wb, 5), /wallet_transfers_fee_cents_check|check constraint/);
    await t.query('ROLLBACK TO SAVEPOINT s');
    await t.query('SAVEPOINT s');
    await assert.rejects(() => insert(a.id, a.id, wa, wa, 0), /check constraint/);
    await t.query('ROLLBACK TO SAVEPOINT s');
  }));

test('money is conserved: five transfers at once from one wallet can not spend more than it has, and nothing is lost', async () => {
  // Committed data (the transfers run on separate connections); everything is removed at the end.
  const ids = [];
  const mk = async (name, cents) => {
    const phone = `2526${String(++n).padStart(8, '0')}`.slice(0, 12);
    const u = await db.query(`INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, $2, private.hash_password($3)) RETURNING id`, [phone, name, PASSWORD]);
    const w = await db.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, $2) RETURNING wallet_code`, [u.rows[0].id, cents]);
    ids.push(u.rows[0].id);
    return { id: u.rows[0].id, code: w.rows[0].wallet_code };
  };
  const settingBefore = (await db.query(`SELECT value FROM public.app_settings WHERE key = 'withdrawal_verification'`)).rows[0]?.value;
  await db.query(`INSERT INTO public.app_settings (key, value) VALUES ('withdrawal_verification', 'off') ON CONFLICT (key) DO UPDATE SET value = 'off'`);
  try {
    const a = await mk('Race Sender', 10000);
    const b = await mk('Race Receiver', 0);
    const run = async (sql, params) => {
      const c = await db.connect();
      try {
        await c.query('BEGIN');
        await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: a.id, role: 'authenticated', aud: 'authenticated' })]);
        const r = (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r;
        await c.query('COMMIT');
        return r;
      } catch (e) { await c.query('ROLLBACK'); return { error: e.message }; } finally { c.release(); }
    };
    assert.equal((await run(`public.customer_set_wallet_pin('4827', $1)`, [PASSWORD])).ok, true);
    const results = await Promise.all(Array.from({ length: 5 }, () => run(`public.customer_wallet_transfer($1, '30', '4827', $2)`, [b.code, key()])));
    const ok = results.filter((r) => r.ok === true).length;
    assert.equal(ok, 3, JSON.stringify(results));                                     // $100 pays three $30 transfers, never four
    assert.equal(results.filter((r) => r.error).length, 2);
    const sa = Number((await db.query(`SELECT available_cents FROM public.wallets WHERE customer_id = $1`, [a.id])).rows[0].available_cents);
    const sb = Number((await db.query(`SELECT available_cents FROM public.wallets WHERE customer_id = $1`, [b.id])).rows[0].available_cents);
    assert.deepEqual([sa, sb, sa + sb], [1000, 9000, 10000]);
    // the same key at once: one transfer
    const k = key();
    const twin = await Promise.all([run(`public.customer_wallet_transfer($1, '5', '4827', $2)`, [b.code, k]), run(`public.customer_wallet_transfer($1, '5', '4827', $2)`, [b.code, k])]);
    assert.equal((await db.query(`SELECT count(*)::int AS n FROM public.wallet_transfers WHERE idempotency_key = $1`, [k])).rows[0].n, 1, JSON.stringify(twin));
    const total = (await db.query(`SELECT sum(available_cents)::bigint AS s FROM public.wallets WHERE customer_id = ANY($1)`, [ids])).rows[0].s;
    assert.equal(Number(total), 10000);
  } finally {
    await db.query(`DELETE FROM public.push_notifications WHERE transfer_id IN (SELECT id FROM public.wallet_transfers WHERE from_customer_id = ANY($1))`, [ids]);
    await db.query(`DELETE FROM public.ledger_entries WHERE wallet_id IN (SELECT id FROM public.wallets WHERE customer_id = ANY($1))`, [ids]);
    await db.query(`DELETE FROM public.wallet_transfers WHERE from_customer_id = ANY($1) OR to_customer_id = ANY($1)`, [ids]);
    await db.query(`DELETE FROM public.audit_logs WHERE actor_id = ANY($1)`, [ids]).catch(() => {});
    await db.query(`DELETE FROM public.users WHERE id = ANY($1)`, [ids]).catch(() => {});
    if (settingBefore != null) await db.query(`UPDATE public.app_settings SET value = $1 WHERE key = 'withdrawal_verification'`, [settingBefore]);
    else await db.query(`DELETE FROM public.app_settings WHERE key = 'withdrawal_verification'`);
  }
});

test('security: a transfer call does not tell whether a Wallet ID exists unless the PIN is right', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 1000);
    const b = await t.customer('Bilan Receiver', 0);
    await t.call(a.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD]);
    const go = (to, pin) => t.call(a.id, `public.customer_wallet_transfer($1, '1', $2, $3)`, [to, pin, key()]);
    // a wrong PIN answers the same for an existing and for a missing Wallet ID
    assert.deepEqual(await go(b.code, '1357'), { ok: false, code: 'WRONG_PIN', attemptsLeft: 4 });
    assert.deepEqual(await go('BE000000', '1357'), { ok: false, code: 'WRONG_PIN', attemptsLeft: 3 });
    // only with the right PIN is a missing Wallet ID reported
    await expectError(t, a.id, `public.customer_wallet_transfer('BE000000', '1', '4827', $1)`, [key()], /lama helin/);
  }));

test('security: every further PIN lock doubles the wait; the right PIN resets it', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 1000);
    const b = await t.customer('Bilan Receiver', 0);
    await t.call(a.id, `public.customer_set_wallet_pin('4827', $1)`, [PASSWORD]);
    const lockFor = async () => {
      let r;
      for (let i = 0; i < 5; i++) r = await t.call(a.id, `public.customer_wallet_transfer($1, '1', '1357', $2)`, [b.code, key()]);
      assert.equal(r.code, 'PIN_LOCKED');
      return (new Date(r.lockedUntil).getTime() - Date.now()) / 60_000;
    };
    const first = await lockFor();
    assert.ok(first > 14 && first < 16, `first lock ${first} min`);
    await t.query(`UPDATE public.wallet_pins SET locked_until = now() - interval '1 second' WHERE customer_id = $1`, [a.id]);
    const second = await lockFor();
    assert.ok(second > 29 && second < 31, `second lock ${second} min`);
    await t.query(`UPDATE public.wallet_pins SET locked_until = now() - interval '1 second' WHERE customer_id = $1`, [a.id]);
    const third = await lockFor();
    assert.ok(third > 59 && third < 61, `third lock ${third} min`);
    // the right PIN after the wait: sent, and the doubling starts again
    await t.query(`UPDATE public.wallet_pins SET locked_until = now() - interval '1 second' WHERE customer_id = $1`, [a.id]);
    assert.equal((await t.call(a.id, `public.customer_wallet_transfer($1, '1', '4827', $2)`, [b.code, key()])).ok, true);
    assert.equal(Number((await t.query(`SELECT lock_count FROM public.wallet_pins WHERE customer_id = $1`, [a.id])).rows[0].lock_count), 0);
    const again = await lockFor();
    assert.ok(again > 14 && again < 16, `after a success the first lock is short again: ${again} min`);
  }));

test('security: 40 Wallet ID lookups an hour at most (the minute limit alone allowed 14,000 a day)', () =>
  inTx(async (t) => {
    const a = await t.customer('Axmed Sender', 0);
    // 40 lookups spread over the last hour (none in the last minute)
    await t.query(`INSERT INTO public.wallet_transfer_events (customer_id, kind, at) SELECT $1, 'lookup', now() - interval '5 minutes' - (g || ' seconds')::interval FROM generate_series(1, 40) g`, [a.id]);
    await expectError(t, a.id, `public.customer_transfer_lookup('BE000000')`, [], /Isku-day badan/);
    // an hour later they no longer count
    await t.query(`UPDATE public.wallet_transfer_events SET at = at - interval '2 hours' WHERE customer_id = $1`, [a.id]);
    assert.deepEqual(await t.call(a.id, `public.customer_transfer_lookup('BE000000')`), { found: false });
  }));
