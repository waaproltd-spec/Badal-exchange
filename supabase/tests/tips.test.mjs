// TIPS (Shaxaha) (migrations/*_tips.sql): free and paid tips, the purchase from
// the customer wallet, protection of the paid Odds Code, refunds, the Admin
// management API and the Agent view.
//
// Scenarios run in a transaction that is rolled back (as the signed-in user, the
// functions check auth.uid()); the double-charge scenario needs real concurrent
// connections, so it commits its own customer and removes it again.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const db = new pg.Pool({ connectionString: DATABASE_URL, max: 10 });
let managerId;
let customerId;
let otherCustomerId;
let agentId;

before(async () => {
  managerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000002'`)).rows[0].id;
  customerId = (await db.query(`SELECT id FROM users WHERE phone = '252610000003'`)).rows[0].id;
  otherCustomerId = (await db.query(`SELECT id FROM users WHERE role = 'customer' AND id <> $1 ORDER BY created_at LIMIT 1`, [customerId])).rows[0]?.id;
  agentId = (await db.query(`SELECT id FROM users WHERE role = 'agent' AND id <> $1 ORDER BY created_at LIMIT 1`, [managerId])).rows[0]?.id;
});
after(() => db.end());

async function asUser(userId, fn) {
  const c = await db.connect();
  try {
    await c.query('BEGIN');
    const claims = JSON.stringify({ sub: userId, role: 'authenticated', aud: 'authenticated' });
    await c.query(`SELECT set_config('request.jwt.claims', $1, true), set_config('role', 'authenticated', true)`, [claims]);
    await c.query(`RESET ROLE`).catch(() => {});
    let n = 0;
    const tx = {
      call: async (sql, params = []) => (await c.query(`SELECT ${sql} AS r`, params)).rows[0].r,
      query: (sql, params) => c.query(sql, params),
      /** Continue as another user inside the same transaction. */
      as: (id) => c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: id, role: 'authenticated', aud: 'authenticated' })]),
      refused: async (sql, params = []) => {
        const sp = `sp${n++}`;
        await c.query(`SAVEPOINT ${sp}`);
        try {
          await c.query(`SELECT ${sql} AS r`, params);
          return null;
        } catch (e) {
          return e.hint ?? e.message;
        } finally {
          await c.query(`ROLLBACK TO ${sp}`);
        }
      },
    };
    return await fn(tx);
  } finally {
    await c.query('ROLLBACK');
    c.release();
  }
}

const CODE_PAID = 'SECRET-PAID-7Q9X2';
const CODE_FREE = 'FREE-CODE-123';
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64').toString('base64');

const save = (tx, v = {}) => tx.call('public.manage_save_tip($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11,$12)', [
  v.id ?? null, v.title ?? 'Weekend accumulator', v.sport ?? 'football', v.teams ?? 5, v.paid ?? false, v.price ?? null,
  v.code ?? (v.paid ? CODE_PAID : CODE_FREE), v.totalOdds ?? 12.5,
  JSON.stringify(v.matches ?? [{ match: 'Arsenal v Chelsea', pick: 'Over 2.5', odds: 1.85 }]), v.note ?? null, v.image ?? null, v.removeImage ?? false,
]);
const publish = (tx, id, on = true) => tx.call('public.manage_publish_tip($1,$2)', [id, on]);
const list = (tx, f = 'all') => tx.call('public.customer_tips($1)', [f]);
const buy = (tx, id, expected = null) => tx.call('public.customer_buy_tip($1,$2)', [id, expected]);
async function fund(tx, customer, cents) {
  await tx.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, $2)
                  ON CONFLICT (customer_id) DO UPDATE SET available_cents = $2`, [customer, cents]);
}
const balance = async (tx, customer) => Number((await tx.query(`SELECT available_cents FROM public.wallets WHERE customer_id = $1`, [customer])).rows[0].available_cents);
const ledgerCount = async (tx, customer) =>
  Number((await tx.query(`SELECT count(*) FROM public.ledger_entries l JOIN public.wallets w ON w.id = l.wallet_id WHERE w.customer_id = $1 AND l.reason LIKE 'Tips%'`, [customer])).rows[0].count);

test('the manager creates tips; a draft is hidden; publishing and unpublishing show and hide it', async () => {
  await asUser(managerId, async (tx) => {
    const free = await save(tx, { title: 'Free pick' });
    const paid = await save(tx, { title: 'Paid pick', paid: true, price: '2.50' });
    assert.equal(free.published, false);
    assert.equal(paid.price, '2.50');
    assert.equal(paid.oddsCode, CODE_PAID, 'the manager sees the code');
    await tx.as(customerId);
    const ids = (await list(tx)).tips.map((t) => t.id);
    assert.ok(!ids.includes(free.id) && !ids.includes(paid.id), 'drafts are not shown to customers');
    await tx.as(managerId);
    await publish(tx, free.id);
    await publish(tx, paid.id);
    await tx.as(customerId);
    const shown = (await list(tx)).tips.map((t) => t.id);
    assert.ok(shown.includes(free.id) && shown.includes(paid.id));
    await tx.as(managerId);
    await publish(tx, paid.id, false);
    await tx.as(customerId);
    assert.ok(!(await list(tx)).tips.some((t) => t.id === paid.id), 'unpublished is hidden again');
  });
});

test('Free / Paid filters; a free tip shows its code to everyone', async () => {
  await asUser(managerId, async (tx) => {
    const free = await publish(tx, (await save(tx, { title: 'F' })).id);
    const paid = await publish(tx, (await save(tx, { title: 'P', paid: true, price: '1' })).id);
    await tx.as(customerId);
    const f = (await list(tx, 'free')).tips;
    const p = (await list(tx, 'paid')).tips;
    assert.ok(f.some((t) => t.id === free.id) && !f.some((t) => t.id === paid.id));
    assert.ok(p.some((t) => t.id === paid.id) && !p.some((t) => t.id === free.id));
    assert.ok(f.every((t) => !t.isPaid) && p.every((t) => t.isPaid));
    const row = f.find((t) => t.id === free.id);
    assert.equal(row.oddsCode, CODE_FREE);
    assert.equal(row.locked, false);
    assert.equal(row.sport, 'football');
    assert.equal(row.teamCount, 5);
    assert.equal(await tx.refused(`public.customer_tips('nonsense')`), 'VALIDATION_ERROR');
  });
});

test('a paid tip is locked: no code, no picks, in the list and in the detail', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '3', image: PNG })).id);
    await tx.as(customerId);
    await fund(tx, customerId, 1000);
    const raw = JSON.stringify(await list(tx, 'paid')) + JSON.stringify(await tx.call('public.customer_tip($1)', [paid.id]));
    assert.ok(!raw.includes(CODE_PAID), 'the Odds Code is not in the answer');
    assert.ok(!raw.includes('Arsenal'), 'the picks are not in the answer');
    assert.ok(!raw.includes(PNG), 'the picture is not in the answer');
    const row = (await list(tx, 'paid')).tips.find((t) => t.id === paid.id);
    assert.equal(row.locked, true);
    assert.equal(row.oddsCode, null);
    assert.equal(row.price, '3.00');
    assert.equal(row.hasImage, true);
  });
});

test('the app roles can not read the tables at all', async () => {
  const r = await db.query(`SELECT has_table_privilege('authenticated','public.tips','SELECT') AS a,
                                   has_table_privilege('anon','public.tips','SELECT') AS b,
                                   has_table_privilege('authenticated','public.tip_purchases','SELECT') AS c,
                                   has_table_privilege('authenticated','public.tips','INSERT') AS d`);
  assert.deepEqual(r.rows[0], { a: false, b: false, c: false, d: false });
  const anon = await db.query(`SELECT has_function_privilege('anon','public.customer_tips(text)','EXECUTE') AS a,
                                      has_function_privilege('anon','public.customer_buy_tip(uuid,text)','EXECUTE') AS b`);
  assert.deepEqual(anon.rows[0], { a: false, b: false });
});

test('buying: the price leaves the wallet once, the ledger and the purchase record it, the code unlocks, buying again charges nothing', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '2.50', image: PNG })).id);
    await tx.as(customerId);
    await fund(tx, customerId, 1000);
    const r = await buy(tx, paid.id, '2.50');
    assert.equal(r.charged, true);
    assert.equal(r.tip.oddsCode, CODE_PAID);
    assert.equal(r.tip.locked, false);
    assert.equal(r.tip.matches.length, 1);
    assert.equal(r.tip.image, PNG);
    assert.equal(r.availableBalance, '7.50');
    assert.equal(await balance(tx, customerId), 750);
    const led = (await tx.query(`SELECT l.entry_type, l.amount_cents, l.balance_after_cents, l.reason FROM public.ledger_entries l
                                  JOIN public.wallets w ON w.id = l.wallet_id WHERE w.customer_id = $1 AND l.reason LIKE 'Tips%'`, [customerId])).rows;
    assert.equal(led.length, 1);
    assert.equal(led[0].entry_type, 'debit');
    assert.equal(Number(led[0].amount_cents), 250);
    assert.equal(Number(led[0].balance_after_cents), 750);

    // Again: nothing charged, the code is still there.
    const again = await buy(tx, paid.id, '2.50');
    assert.equal(again.charged, false);
    assert.equal(again.alreadyOwned, true);
    assert.equal(again.tip.oddsCode, CODE_PAID);
    assert.equal(await balance(tx, customerId), 750);
    assert.equal(await ledgerCount(tx, customerId), 1);

    // The list and the history remember it.
    const row = (await list(tx)).tips.find((t) => t.id === paid.id);
    assert.equal(row.owned, true);
    assert.equal(row.oddsCode, CODE_PAID);
    const mine = (await tx.call('public.customer_tip_purchases()')).purchases;
    assert.equal(mine.length >= 1, true);
    assert.equal(mine.find((p) => p.tipId === paid.id).price, '2.50');

    // Another customer still sees it locked.
    if (otherCustomerId) {
      await tx.as(otherCustomerId);
      const theirs = (await list(tx)).tips.find((t) => t.id === paid.id);
      assert.equal(theirs.locked, true);
      assert.equal(theirs.oddsCode, null);
    }
  });
});

test('never a negative balance: not enough money charges nothing; exactly enough leaves zero', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '5' })).id);
    await tx.as(customerId);
    await fund(tx, customerId, 499);
    assert.equal(await tx.refused('public.customer_buy_tip($1, NULL)', [paid.id]), 'INSUFFICIENT_FUNDS');
    assert.equal(await balance(tx, customerId), 499);
    assert.equal(await ledgerCount(tx, customerId), 0);
    assert.equal((await tx.query(`SELECT count(*) FROM public.tip_purchases WHERE customer_id = $1 AND tip_id = $2`, [customerId, paid.id])).rows[0].count, '0');
    assert.equal((await list(tx)).tips.find((t) => t.id === paid.id).locked, true);
    await fund(tx, customerId, 500);
    await buy(tx, paid.id);
    assert.equal(await balance(tx, customerId), 0);
  });
});

test('a changed price, a free tip, a draft or a deleted tip are not charged', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '4' })).id);
    const free = await publish(tx, (await save(tx, {})).id);
    const draft = await save(tx, { paid: true, price: '4' });
    const gone = await publish(tx, (await save(tx, { paid: true, price: '4' })).id);
    await tx.call('public.manage_delete_tip($1)', [gone.id]);
    await tx.as(customerId);
    await fund(tx, customerId, 2000);
    assert.equal(await tx.refused('public.customer_buy_tip($1,$2)', [paid.id, '3.00']), 'PRICE_CHANGED');
    assert.equal(await tx.refused('public.customer_buy_tip($1,$2)', [paid.id, 'abc']), 'VALIDATION_ERROR');
    assert.equal(await tx.refused('public.customer_buy_tip($1, NULL)', [free.id]), 'TIP_IS_FREE');
    assert.equal(await tx.refused('public.customer_buy_tip($1, NULL)', [draft.id]), 'TIP_NOT_FOUND');
    assert.equal(await tx.refused('public.customer_buy_tip($1, NULL)', [gone.id]), 'TIP_NOT_FOUND');
    assert.equal(await tx.refused('public.customer_tip($1)', [draft.id]), 'TIP_NOT_FOUND');
    assert.equal(await balance(tx, customerId), 2000);
    assert.equal(await ledgerCount(tx, customerId), 0);
  });
});

test('if anything fails after the money moved, everything is undone: no charge, no entry, still locked', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '2' })).id);
    await tx.as(customerId);
    await fund(tx, customerId, 1000);
    await tx.query(`CREATE FUNCTION public.tmp_tips_boom() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RAISE EXCEPTION 'boom'; END $f$`);
    await tx.query(`CREATE TRIGGER tmp_tips_boom BEFORE INSERT ON public.tip_purchases FOR EACH ROW EXECUTE FUNCTION public.tmp_tips_boom()`);
    assert.match(await tx.refused('public.customer_buy_tip($1, NULL)', [paid.id]), /boom/);
    assert.equal(await balance(tx, customerId), 1000, 'the wallet is exactly as it was');
    assert.equal(await ledgerCount(tx, customerId), 0, 'no ledger entry is left');
    await tx.query(`DROP TRIGGER tmp_tips_boom ON public.tip_purchases`);
    assert.equal((await list(tx)).tips.find((t) => t.id === paid.id).locked, true);
    assert.equal((await buy(tx, paid.id)).charged, true, 'and the customer can buy normally afterwards');
    assert.equal(await balance(tx, customerId), 800);
  });
});

test('a refund gives the money back once and withdraws the access; the tip can be bought again', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '6' })).id);
    await tx.as(customerId);
    await fund(tx, customerId, 1000);
    const bought = await buy(tx, paid.id);
    await tx.as(managerId);
    assert.equal(await tx.refused('public.manage_refund_tip_purchase($1, $2)', [bought.purchaseId, 'x']), 'VALIDATION_ERROR');
    const r = await tx.call('public.manage_refund_tip_purchase($1, $2)', [bought.purchaseId, 'Wrong tip sent']);
    assert.equal(r.status, 'refunded');
    assert.equal(await balance(tx, customerId), 1000);
    assert.equal(await tx.refused('public.manage_refund_tip_purchase($1, $2)', [bought.purchaseId, 'Again']), 'ALREADY_REFUNDED');
    assert.equal(await balance(tx, customerId), 1000, 'not refunded twice');
    const kinds = (await tx.query(`SELECT l.entry_type FROM public.ledger_entries l JOIN public.wallets w ON w.id = l.wallet_id
                                    WHERE w.customer_id = $1 AND l.reason LIKE 'Tips%' ORDER BY l.created_at, l.entry_type`, [customerId])).rows.map((x) => x.entry_type);
    assert.deepEqual(kinds.sort(), ['credit', 'debit']);
    await tx.as(customerId);
    const row = (await list(tx)).tips.find((t) => t.id === paid.id);
    assert.equal(row.locked, true);
    assert.equal(row.oddsCode, null);
    assert.equal((await buy(tx, paid.id)).charged, true);
    assert.equal(await balance(tx, customerId), 400);
  });
});

test('purchase history, sales and revenue (a refund is not revenue)', async () => {
  await asUser(managerId, async (tx) => {
    const a = await publish(tx, (await save(tx, { title: 'Stats A', paid: true, price: '2' })).id);
    const b = await publish(tx, (await save(tx, { title: 'Stats B', paid: true, price: '3' })).id);
    const before = await tx.call('public.manage_tips_stats()');
    await tx.as(customerId);
    await fund(tx, customerId, 5000);
    const pa = await buy(tx, a.id);
    await buy(tx, b.id);
    await tx.as(managerId);
    const mid = await tx.call('public.manage_tips_stats()');
    assert.equal(mid.sales - before.sales, 2);
    assert.equal(Math.round((Number(mid.revenue) - Number(before.revenue)) * 100), 500);
    assert.equal(mid.salesToday - before.salesToday, 2);
    await tx.call('public.manage_refund_tip_purchase($1, $2)', [pa.purchaseId, 'Customer asked']);
    const after = await tx.call('public.manage_tips_stats()');
    assert.equal(after.sales - before.sales, 1);
    assert.equal(Math.round((Number(after.revenue) - Number(before.revenue)) * 100), 300);
    assert.equal(after.refunds - before.refunds, 1);
    const hist = (await tx.call('public.manage_tip_purchases($1)', [a.id])).purchases;
    assert.equal(hist.length, 1);
    assert.equal(hist[0].status, 'refunded');
    assert.equal(hist[0].customerId, customerId);
    assert.ok(hist[0].customerPhone);
    const one = (await tx.call('public.manage_tips($1)', ['paid'])).tips.find((t) => t.id === b.id);
    assert.equal(one.sales, 1);
    assert.equal(one.revenue, '3.00');
    const all = (await tx.call('public.manage_tip_purchases()')).purchases;
    assert.ok(all.length >= 2);
  });
});

test('editing keeps what customers paid; unpublish keeps owners\' access; delete hides it but keeps the money records', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '2' })).id);
    await tx.as(customerId);
    await fund(tx, customerId, 1000);
    await buy(tx, paid.id);
    await tx.as(managerId);
    await save(tx, { id: paid.id, paid: true, price: '9', code: 'NEW-CODE-1' });
    assert.equal((await tx.query(`SELECT price_cents FROM public.tip_purchases WHERE tip_id = $1`, [paid.id])).rows[0].price_cents, '200');
    await publish(tx, paid.id, false);
    await tx.as(customerId);
    const row = (await list(tx)).tips.find((t) => t.id === paid.id);
    assert.equal(row.oddsCode, 'NEW-CODE-1', 'the owner still has access, to the current code');
    await tx.as(managerId);
    await tx.call('public.manage_delete_tip($1)', [paid.id]);
    assert.ok(!(await tx.call('public.manage_tips()')).tips.some((t) => t.id === paid.id));
    assert.equal((await tx.call('public.manage_tip_purchases($1)', [paid.id])).purchases.length, 1);
    assert.equal(await tx.refused('public.manage_delete_tip($1)', [paid.id]), 'TIP_NOT_FOUND');
    await tx.as(customerId);
    assert.ok(!(await list(tx)).tips.some((t) => t.id === paid.id));
    assert.equal((await tx.call('public.customer_tip_purchases()')).purchases.length >= 1, true);
  });
});

test('what the manager types is checked', async () => {
  await asUser(managerId, async (tx) => {
    const args = (o) => [null, o.title ?? 'T', o.sport ?? 'football', o.teams ?? 3, o.paid ?? false, o.price ?? null, o.code ?? 'C', null, JSON.stringify(o.matches ?? []), null, o.image ?? null, false];
    const sql = 'public.manage_save_tip($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11,$12)';
    assert.equal(await tx.refused(sql, args({ title: ' ' })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ sport: 'curling' })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ teams: 0 })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ teams: 41 })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ code: '  ' })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ paid: true, price: null })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ paid: true, price: '0' })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ paid: true, price: '5000' })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ matches: [{ pick: 'x' }] })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused(sql, args({ image: Buffer.from('not a picture').toString('base64') })), 'VALIDATION_ERROR');
    assert.equal(await tx.refused('public.manage_publish_tip($1,true)', ['00000000-0000-0000-0000-000000000000']), 'TIP_NOT_FOUND');
    // A free tip has no price even if one was typed.
    const free = await save(tx, { paid: false, price: '7' });
    assert.equal(free.price, '0.00');
    // A picture can be added and removed.
    const withPic = await save(tx, { id: free.id, image: PNG });
    assert.equal(withPic.hasImage, true);
    assert.equal((await save(tx, { id: free.id, removeImage: true })).hasImage, false);
  });
});

test('who may do what', async () => {
  await asUser(managerId, async (tx) => {
    const paid = await publish(tx, (await save(tx, { paid: true, price: '2' })).id);
    await tx.as(customerId);
    await fund(tx, customerId, 1000);
    const bought = await buy(tx, paid.id);
    // A customer can not manage, refund, or read the agent view.
    for (const [sql, params] of [
      ['public.manage_tips()', []],
      ['public.manage_tips_stats()', []],
      ['public.manage_tip_purchases()', []],
      ['public.manage_publish_tip($1,true)', [paid.id]],
      ['public.manage_delete_tip($1)', [paid.id]],
      ['public.manage_refund_tip_purchase($1,$2)', [bought.purchaseId, 'because']],
      ['public.agent_tip_purchases()', []],
    ]) {
      assert.equal(await tx.refused(sql, params), 'FORBIDDEN', sql);
    }
    assert.equal(await balance(tx, customerId), 800);
    // The managers' and agents' accounts are not customers: they can not buy.
    await tx.as(managerId);
    assert.equal(await tx.refused('public.customer_buy_tip($1, NULL)', [paid.id]), 'FORBIDDEN');
    assert.equal(await tx.refused('public.customer_tips()'), 'FORBIDDEN');
    // An agent can view the purchases (not manage).
    if (agentId) {
      await tx.as(agentId);
      const v = await tx.call('public.agent_tip_purchases(50, NULL)');
      assert.ok(v.purchases.some((p) => p.id === bought.purchaseId));
      assert.ok(v.summary.sales >= 1);
      const q = await tx.call('public.agent_tip_purchases(50, $1)', ['zzzz-nothing-matches']);
      assert.equal(q.purchases.length, 0);
      assert.ok(!JSON.stringify(v).includes(CODE_PAID), 'the agent view never carries a code');
      assert.equal(await tx.refused('public.manage_refund_tip_purchase($1,$2)', [bought.purchaseId, 'because']), 'FORBIDDEN');
    }
  });
});

test('the same customer pressing Buy many times at once is charged once', async () => {
  const phone = `2526${String(Date.now()).slice(-8)}`;
  const tipRow = (await db.query(
    `INSERT INTO public.tips (title, sport, team_count, is_paid, price_cents, odds_code, published, published_at)
     VALUES ('Concurrency', 'football', 3, true, 300, 'CONC-CODE', true, now()) RETURNING id`)).rows[0];
  const user = (await db.query(
    `INSERT INTO public.users (role, phone, name, password_hash) VALUES ('customer', $1, 'Concurrent buyer', private.hash_password('ChangeMe123!')) RETURNING id`, [phone])).rows[0];
  const wallet = (await db.query(`INSERT INTO public.wallets (customer_id, available_cents) VALUES ($1, 1000) RETURNING id`, [user.id])).rows[0];
  try {
    const attempt = async () => {
      const c = await db.connect();
      try {
        await c.query('BEGIN');
        await c.query(`SELECT set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: user.id, role: 'authenticated', aud: 'authenticated' })]);
        const r = (await c.query(`SELECT public.customer_buy_tip($1, '3.00') AS r`, [tipRow.id])).rows[0].r;
        await c.query('COMMIT');
        return r;
      } catch (e) {
        await c.query('ROLLBACK').catch(() => {});
        return { error: e.hint ?? e.message };
      } finally {
        c.release();
      }
    };
    const results = await Promise.all(Array.from({ length: 6 }, attempt));
    assert.equal(results.filter((r) => r.charged === true).length, 1, JSON.stringify(results));
    assert.equal(results.filter((r) => r.error).length, 0, JSON.stringify(results));
    assert.equal(results.filter((r) => r.alreadyOwned === true).length, 5);
    const w = (await db.query(`SELECT available_cents FROM public.wallets WHERE id = $1`, [wallet.id])).rows[0];
    assert.equal(w.available_cents, '700');
    assert.equal((await db.query(`SELECT count(*) FROM public.tip_purchases WHERE customer_id = $1`, [user.id])).rows[0].count, '1');
    assert.equal((await db.query(`SELECT count(*) FROM public.ledger_entries WHERE wallet_id = $1`, [wallet.id])).rows[0].count, '1');
  } finally {
    // The audit log and the ledger are append-only, so the throwaway customer and its wallet stay (like the
    // customers the other suites create); the tip must not stay: it would show in the shared lists.
    await db.query(`DELETE FROM public.tip_purchases WHERE tip_id = $1`, [tipRow.id]);
    await db.query(`DELETE FROM public.tips WHERE id = $1`, [tipRow.id]);
  }
});
