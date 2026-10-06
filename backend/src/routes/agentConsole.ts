import { Router, Request, Response, NextFunction } from 'express';
import { z } from 'zod';
import { pool } from '../db/pool';
import { asyncHandler } from '../lib/asyncHandler';
import { ApiError } from '../lib/errors';
import { fromCents } from '../lib/money';
import { hashPassword, verifyPassword } from '../lib/crypto';
import { writeAudit } from '../lib/audit';
import { METHODS, MOBILE_MONEY_METHODS, METHOD_LABELS } from '../lib/methods';
import {
  CONTACT_KEYS,
  getContacts,
  listDepositNumbers,
  listHomeAds,
  listNotifications,
  listPaymentMethods,
  serializeDepositNumber,
  serializeHomeAd,
  serializeNotification,
} from '../services/settingsService';

/**
 * Agent App console: Dashboard, Users (customers, view-only), Reports,
 * History and the Account tab's settings. Registered on the agent router,
 * so every route here already requires an authenticated, active agent.
 *
 * Settings writes additionally require the 'manage_settings'
 * responsibility, which only an admin can grant. Customer data is read-only
 * from here: there is no route that changes a customer.
 */
export function registerAgentConsoleRoutes(router: Router) {
  // -------------------------------------------------------------------------
  // Dashboard
  // -------------------------------------------------------------------------
  router.get(
    '/dashboard',
    asyncHandler(async (_req, res) => {
      const [counts, recent] = await Promise.all([
        pool.query(
          `SELECT
             count(*) FILTER (WHERE direction = 'deposit' AND status = 'pending')::int  AS pending_deposits,
             count(*) FILTER (WHERE direction = 'withdraw' AND status = 'pending')::int AS pending_withdrawals,
             count(*) FILTER (WHERE status = 'processing')::int AS processing,
             count(*) FILTER (WHERE status = 'completed')::int  AS completed,
             count(*) FILTER (WHERE status = 'failed')::int     AS failed,
             count(*)::int AS total
           FROM orders`
        ),
        pool.query(
          `SELECT o.*, u.name AS customer_name, u.phone AS customer_phone
           FROM orders o JOIN users u ON u.id = o.customer_id
           ORDER BY o.updated_at DESC LIMIT 10`
        ),
      ]);
      const c = counts.rows[0];
      res.json({
        pendingDeposits: c.pending_deposits,
        pendingWithdrawals: c.pending_withdrawals,
        processing: c.processing,
        completed: c.completed,
        failed: c.failed,
        totalTransactions: c.total,
        recentActivity: recent.rows.map(serializeHistoryOrder),
      });
    })
  );

  // -------------------------------------------------------------------------
  // Users = Customer App customers (view-only)
  // -------------------------------------------------------------------------
  const customersQuery = z.object({
    q: z.string().max(100).optional(),
    status: z.enum(['all', 'active', 'blocked']).default('all'),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    offset: z.coerce.number().int().min(0).default(0),
  });

  router.get(
    '/customers',
    asyncHandler(async (req, res) => {
      const query = customersQuery.parse(req.query);
      const params: unknown[] = [];
      const where = [`u.role = 'customer'`];
      if (query.q) {
        params.push(`%${query.q.trim()}%`);
        where.push(`(u.name ILIKE $${params.length} OR u.phone ILIKE $${params.length})`);
      }
      if (query.status !== 'all') {
        params.push(query.status === 'active' ? 'active' : 'disabled');
        where.push(`u.status = $${params.length}`);
      }
      params.push(query.limit, query.offset);
      const { rows } = await pool.query(
        `SELECT u.id, u.name, u.phone, u.status, u.created_at, COALESCE(w.available_cents, 0) AS available_cents
         FROM users u LEFT JOIN wallets w ON w.customer_id = u.id
         WHERE ${where.join(' AND ')}
         ORDER BY u.created_at DESC
         LIMIT $${params.length - 1} OFFSET $${params.length}`,
        params
      );
      res.json(
        rows.map((r) => ({
          id: r.id,
          name: r.name,
          phone: r.phone,
          status: customerStatus(r.status),
          walletBalance: fromCents(r.available_cents),
          registeredAt: r.created_at,
        }))
      );
    })
  );

  router.get(
    '/customers/:id',
    asyncHandler(async (req, res) => {
      const id = z.string().uuid().parse(req.params.id);
      const { rows } = await pool.query(
        `SELECT u.id, u.name, u.phone, u.status, u.created_at,
                COALESCE(w.available_cents, 0) AS available_cents, COALESCE(w.pending_cents, 0) AS pending_cents,
                w.id AS wallet_id
         FROM users u LEFT JOIN wallets w ON w.customer_id = u.id
         WHERE u.id = $1 AND u.role = 'customer'`,
        [id]
      );
      const customer = rows[0];
      if (!customer) throw ApiError.notFound('Customer not found');

      const [totals, recentOrders, recentLedger, ledgerCount] = await Promise.all([
        pool.query(
          `SELECT count(*)::int AS orders,
                  COALESCE(sum(net_cents) FILTER (WHERE direction = 'deposit' AND status = 'completed'), 0) AS deposits,
                  COALESCE(sum(wallet_delta_cents) FILTER (WHERE direction = 'withdraw' AND status = 'completed'), 0) AS withdrawals
           FROM orders WHERE customer_id = $1`,
          [id]
        ),
        pool.query(
          `SELECT o.*, $2::text AS customer_name, $3::text AS customer_phone
           FROM orders o WHERE o.customer_id = $1 ORDER BY o.created_at DESC LIMIT 10`,
          [id, customer.name, customer.phone]
        ),
        customer.wallet_id
          ? pool.query(
              `SELECT id, entry_type, amount_cents, balance_after_cents, reason, created_at
               FROM ledger_entries WHERE wallet_id = $1 ORDER BY created_at DESC LIMIT 10`,
              [customer.wallet_id]
            )
          : Promise.resolve({ rows: [] as any[] }),
        customer.wallet_id
          ? pool.query('SELECT count(*)::int AS n FROM ledger_entries WHERE wallet_id = $1', [customer.wallet_id])
          : Promise.resolve({ rows: [{ n: 0 }] }),
      ]);
      const t = totals.rows[0];
      res.json({
        id: customer.id,
        name: customer.name,
        phone: customer.phone,
        status: customerStatus(customer.status),
        registeredAt: customer.created_at,
        walletBalance: fromCents(customer.available_cents),
        pendingBalance: fromCents(customer.pending_cents),
        totalOrders: t.orders,
        totalDeposits: fromCents(t.deposits),
        totalWithdrawals: fromCents(t.withdrawals),
        totalTransactions: ledgerCount.rows[0].n,
        recentOrders: recentOrders.rows.map(serializeHistoryOrder),
        recentTransactions: recentLedger.rows.map((l) => ({
          id: l.id,
          type: l.entry_type,
          amount: fromCents(l.amount_cents),
          balanceAfter: fromCents(l.balance_after_cents),
          description: l.reason,
          createdAt: l.created_at,
        })),
      });
    })
  );

  // -------------------------------------------------------------------------
  // Reports
  // -------------------------------------------------------------------------
  const reportsQuery = z.object({
    period: z.enum(['daily', 'weekly', 'monthly', 'custom']).default('daily'),
    from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  });

  router.get(
    '/reports',
    asyncHandler(async (req, res) => {
      const query = reportsQuery.parse(req.query);
      const { from, to } = reportRange(query.period, query.from, query.to);

      // [from, to] are whole UTC days, inclusive.
      const range = [from, to];
      const [summary, series] = await Promise.all([
        pool.query(
          `SELECT
             count(*) FILTER (WHERE direction = 'deposit')::int AS deposit_count,
             COALESCE(sum(amount_cents) FILTER (WHERE direction = 'deposit'), 0) AS deposit_total,
             count(*) FILTER (WHERE direction = 'withdraw')::int AS withdraw_count,
             COALESCE(sum(amount_cents) FILTER (WHERE direction = 'withdraw'), 0) AS withdraw_total,
             count(*)::int AS order_count,
             COALESCE(sum(amount_cents), 0) AS order_total,
             count(*) FILTER (WHERE status = 'completed')::int AS completed_count,
             COALESCE(sum(amount_cents) FILTER (WHERE status = 'completed'), 0) AS completed_total,
             count(*) FILTER (WHERE status = 'failed')::int AS failed_count,
             COALESCE(sum(amount_cents) FILTER (WHERE status = 'failed'), 0) AS failed_total
           FROM orders
           WHERE created_at >= $1::date AND created_at < ($2::date + 1)`,
          range
        ),
        pool.query(
          `SELECT to_char(d, 'YYYY-MM-DD') AS day,
                  count(o.id) FILTER (WHERE o.direction = 'deposit')::int AS deposits,
                  count(o.id) FILTER (WHERE o.direction = 'withdraw')::int AS withdrawals,
                  count(o.id)::int AS orders
           FROM generate_series($1::date, $2::date, interval '1 day') d
           LEFT JOIN orders o ON o.created_at >= d AND o.created_at < d + interval '1 day'
           GROUP BY d ORDER BY d`,
          range
        ),
      ]);
      const s = summary.rows[0];
      const item = (count: number, total: string | number) => ({ count, total: fromCents(total) });
      res.json({
        period: query.period,
        from,
        to,
        deposits: item(s.deposit_count, s.deposit_total),
        withdrawals: item(s.withdraw_count, s.withdraw_total),
        orders: item(s.order_count, s.order_total),
        completed: item(s.completed_count, s.completed_total),
        failed: item(s.failed_count, s.failed_total),
        series: series.rows.map((r) => ({
          date: r.day,
          deposits: r.deposits,
          withdrawals: r.withdrawals,
          orders: r.orders,
        })),
      });
    })
  );

  // -------------------------------------------------------------------------
  // History: orders plus payment confirmations (SMS / agent-entered)
  // -------------------------------------------------------------------------
  const historyQuery = z.object({
    q: z.string().max(100).optional(),
    customerId: z.string().uuid().optional(),
    type: z.enum(['all', 'deposit', 'withdraw', 'order', 'confirmation']).default('all'),
    status: z.string().max(20).optional(),
    method: z.enum(METHODS).optional(),
    from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    offset: z.coerce.number().int().min(0).default(0),
  });

  router.get(
    '/history',
    asyncHandler(async (req, res) => {
      const query = historyQuery.parse(req.query);
      const window = query.limit + query.offset;
      const wantOrders = query.type !== 'confirmation';
      const wantConfirmations = (query.type === 'all' || query.type === 'confirmation') && !query.customerId;

      const [orders, confirmations] = await Promise.all([
        wantOrders ? historyOrders(query, window) : Promise.resolve([]),
        wantConfirmations ? historyConfirmations(query, window) : Promise.resolve([]),
      ]);
      const merged = [...orders, ...confirmations]
        .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
        .slice(query.offset, query.offset + query.limit);
      res.json(merged);
    })
  );

  async function historyOrders(query: z.infer<typeof historyQuery>, window: number) {
    const params: unknown[] = [];
    const where: string[] = [];
    const add = (sql: string, value: unknown) => {
      params.push(value);
      where.push(sql.replace('?', `$${params.length}`));
    };
    if (query.type === 'deposit' || query.type === 'withdraw') add('o.direction = ?', query.type);
    if (query.status) add('o.status::text = ?', query.status);
    if (query.method) add('o.method = ?', query.method);
    if (query.customerId) add('o.customer_id = ?', query.customerId);
    if (query.from) add('o.created_at >= ?::date', query.from);
    if (query.to) add(`o.created_at < (?::date + 1)`, query.to);
    if (query.q) {
      params.push(`%${query.q.trim()}%`);
      const p = `$${params.length}`;
      where.push(
        `(u.name ILIKE ${p} OR u.phone ILIKE ${p} OR o.phone_number ILIKE ${p} OR o.winwin_id ILIKE ${p} OR o.order_code ILIKE ${p})`
      );
    }
    params.push(window);
    const { rows } = await pool.query(
      `SELECT o.*, u.name AS customer_name, u.phone AS customer_phone
       FROM orders o JOIN users u ON u.id = o.customer_id
       ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
       ORDER BY o.created_at DESC LIMIT $${params.length}`,
      params
    );
    return rows.map(serializeHistoryOrder);
  }

  async function historyConfirmations(query: z.infer<typeof historyQuery>, window: number) {
    // One row per confirmation: mobile-money payments (SMS or agent-entered)
    // and betting-platform top-ups, with the customer of the order they
    // matched, if any.
    const params: unknown[] = [MOBILE_MONEY_METHODS];
    const where: string[] = [];
    const add = (sql: string, value: unknown) => {
      params.push(value);
      where.push(sql.replace('?', `$${params.length}`));
    };
    if (query.status) add('c.status = ?', query.status);
    if (query.method) add('c.method = ?', query.method);
    if (query.from) add('c.created_at >= ?::date', query.from);
    if (query.to) add(`c.created_at < (?::date + 1)`, query.to);
    if (query.q) {
      params.push(`%${query.q.trim()}%`);
      const p = `$${params.length}`;
      where.push(`(c.counterparty ILIKE ${p} OR c.reference ILIKE ${p} OR u.name ILIKE ${p} OR u.phone ILIKE ${p})`);
    }
    params.push(window);
    const { rows } = await pool.query(
      `WITH c AS (
         SELECT s.id, CASE WHEN s.provider = ANY($1) THEN s.provider ELSE 'evc_plus' END AS method,
                s.sender AS counterparty, s.amount_cents, s.transaction_ref AS reference,
                s.match_status AS status, s.matched_order_id, s.created_at
         FROM sms_transactions s
         UNION ALL
         SELECT w.id, w.method::text, w.winwin_id, w.amount_cents, w.mobcash_ref,
                w.match_status, w.matched_order_id, w.created_at
         FROM winwin_transactions w
       )
       SELECT c.*, u.name AS customer_name, u.phone AS customer_phone
       FROM c LEFT JOIN orders o ON o.id = c.matched_order_id LEFT JOIN users u ON u.id = o.customer_id
       ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
       ORDER BY c.created_at DESC LIMIT $${params.length}`,
      params
    );
    return rows.map((r) => ({
      kind: 'confirmation' as const,
      id: r.id,
      orderCode: null,
      direction: 'deposit',
      method: r.method,
      methodLabel: METHOD_LABELS[r.method as keyof typeof METHOD_LABELS] ?? r.method,
      status: r.status,
      amount: fromCents(r.amount_cents),
      counterparty: r.counterparty,
      reference: r.reference,
      customerName: r.customer_name,
      customerPhone: r.customer_phone,
      createdAt: r.created_at,
    }));
  }

  // -------------------------------------------------------------------------
  // Account: profile + password
  // -------------------------------------------------------------------------
  router.get(
    '/account',
    asyncHandler(async (req, res) => {
      const { rows } = await pool.query(
        `SELECT u.id, u.name, u.phone, u.email, u.status, ap.responsibilities
         FROM users u LEFT JOIN agent_profiles ap ON ap.user_id = u.id WHERE u.id = $1`,
        [req.user!.id]
      );
      const agent = rows[0];
      if (!agent) throw ApiError.notFound('Agent not found');
      const responsibilities: string[] = agent.responsibilities ?? [];
      res.json({
        id: agent.id,
        name: agent.name,
        phone: agent.phone,
        email: agent.email,
        status: agent.status,
        responsibilities,
        canManageSettings: responsibilities.includes(MANAGE_SETTINGS),
        contacts: await getContacts(),
      });
    })
  );

  const passwordSchema = z.object({
    currentPassword: z.string().min(1),
    newPassword: z.string().min(8).max(72),
  });

  router.post(
    '/account/password',
    asyncHandler(async (req, res) => {
      const body = passwordSchema.parse(req.body);
      const { rows } = await pool.query('SELECT password_hash FROM users WHERE id = $1', [req.user!.id]);
      if (!rows[0] || !(await verifyPassword(body.currentPassword, rows[0].password_hash))) {
        throw ApiError.badRequest('Current password is incorrect', 'INVALID_PASSWORD');
      }
      await pool.query('UPDATE users SET password_hash = $1, updated_at = now() WHERE id = $2', [
        await hashPassword(body.newPassword),
        req.user!.id,
      ]);
      // Sign out every other session; this one logs in again with the new password.
      await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [
        req.user!.id,
      ]);
      await writeAudit({ actorId: req.user!.id, actorRole: 'agent', action: 'user.change_password', entityType: 'user', entityId: req.user!.id });
      res.status(204).send();
    })
  );

  // -------------------------------------------------------------------------
  // Account: admin features (require 'manage_settings')
  // -------------------------------------------------------------------------
  router.get(
    '/manage/payment-methods',
    requireManageSettings,
    asyncHandler(async (_req, res) => {
      res.json(await listPaymentMethods());
    })
  );

  router.put(
    '/manage/payment-methods/:method',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const method = z.enum(METHODS).parse(req.params.method);
      const { enabled } = z.object({ enabled: z.boolean() }).parse(req.body);
      const { rows } = await pool.query(
        `INSERT INTO payment_methods (method, enabled, updated_by) VALUES ($1, $2, $3)
         ON CONFLICT (method) DO UPDATE SET enabled = EXCLUDED.enabled, updated_by = EXCLUDED.updated_by, updated_at = now()
         RETURNING *`,
        [method, enabled, req.user!.id]
      );
      await audit(req, 'payment_method.update', 'payment_method', method, rows[0]);
      res.json({ method, label: METHOD_LABELS[method], enabled: rows[0].enabled });
    })
  );

  const adSchema = z.object({
    title: z.string().min(1).max(120),
    body: z.string().max(500).nullish(),
    imageUrl: z.string().url().max(500).nullish(),
    linkUrl: z.string().url().max(500).nullish(),
    enabled: z.boolean().default(true),
    sortOrder: z.number().int().min(0).max(1000).default(0),
  });

  router.get(
    '/manage/home-ads',
    requireManageSettings,
    asyncHandler(async (_req, res) => {
      res.json(await listHomeAds({ enabledOnly: false }));
    })
  );

  router.post(
    '/manage/home-ads',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const b = adSchema.parse(req.body);
      const { rows } = await pool.query(
        `INSERT INTO home_ads (title, body, image_url, link_url, enabled, sort_order, created_by, updated_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $7) RETURNING *`,
        [b.title, b.body ?? null, b.imageUrl ?? null, b.linkUrl ?? null, b.enabled, b.sortOrder, req.user!.id]
      );
      await audit(req, 'home_ad.create', 'home_ad', rows[0].id, rows[0]);
      res.status(201).json(serializeHomeAd(rows[0]));
    })
  );

  router.put(
    '/manage/home-ads/:id',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const id = z.string().uuid().parse(req.params.id);
      const b = adSchema.parse(req.body);
      const { rows } = await pool.query(
        `UPDATE home_ads SET title = $2, body = $3, image_url = $4, link_url = $5, enabled = $6, sort_order = $7,
                updated_by = $8, updated_at = now()
         WHERE id = $1 RETURNING *`,
        [id, b.title, b.body ?? null, b.imageUrl ?? null, b.linkUrl ?? null, b.enabled, b.sortOrder, req.user!.id]
      );
      if (!rows[0]) throw ApiError.notFound('Ad not found');
      await audit(req, 'home_ad.update', 'home_ad', id, rows[0]);
      res.json(serializeHomeAd(rows[0]));
    })
  );

  router.delete(
    '/manage/home-ads/:id',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const id = z.string().uuid().parse(req.params.id);
      const { rows } = await pool.query('DELETE FROM home_ads WHERE id = $1 RETURNING *', [id]);
      if (!rows[0]) throw ApiError.notFound('Ad not found');
      await audit(req, 'home_ad.delete', 'home_ad', id, undefined, rows[0]);
      res.status(204).send();
    })
  );

  const depositNumberSchema = z.object({
    method: z.enum(METHODS),
    number: z.string().min(3).max(40),
    label: z.string().max(80).nullish(),
    enabled: z.boolean().default(true),
  });

  router.get(
    '/manage/deposit-numbers',
    requireManageSettings,
    asyncHandler(async (_req, res) => {
      res.json(await listDepositNumbers({ enabledOnly: false }));
    })
  );

  router.post(
    '/manage/deposit-numbers',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const b = depositNumberSchema.parse(req.body);
      const { rows } = await pool.query(
        `INSERT INTO deposit_numbers (method, number, label, enabled, created_by, updated_by)
         VALUES ($1, $2, $3, $4, $5, $5)
         ON CONFLICT (method, number) DO NOTHING RETURNING *`,
        [b.method, b.number.trim(), b.label ?? null, b.enabled, req.user!.id]
      );
      if (!rows[0]) throw ApiError.conflict('That number is already listed for this method', 'DUPLICATE_DEPOSIT_NUMBER');
      await audit(req, 'deposit_number.create', 'deposit_number', rows[0].id, rows[0]);
      res.status(201).json(serializeDepositNumber(rows[0]));
    })
  );

  router.put(
    '/manage/deposit-numbers/:id',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const id = z.string().uuid().parse(req.params.id);
      const b = depositNumberSchema.parse(req.body);
      const { rows } = await pool.query(
        `UPDATE deposit_numbers SET method = $2, number = $3, label = $4, enabled = $5, updated_by = $6, updated_at = now()
         WHERE id = $1 RETURNING *`,
        [id, b.method, b.number.trim(), b.label ?? null, b.enabled, req.user!.id]
      );
      if (!rows[0]) throw ApiError.notFound('Deposit number not found');
      await audit(req, 'deposit_number.update', 'deposit_number', id, rows[0]);
      res.json(serializeDepositNumber(rows[0]));
    })
  );

  router.delete(
    '/manage/deposit-numbers/:id',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const id = z.string().uuid().parse(req.params.id);
      const { rows } = await pool.query('DELETE FROM deposit_numbers WHERE id = $1 RETURNING *', [id]);
      if (!rows[0]) throw ApiError.notFound('Deposit number not found');
      await audit(req, 'deposit_number.delete', 'deposit_number', id, undefined, rows[0]);
      res.status(204).send();
    })
  );

  router.get(
    '/manage/notifications',
    requireManageSettings,
    asyncHandler(async (_req, res) => {
      res.json(await listNotifications(100));
    })
  );

  router.post(
    '/manage/notifications',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const b = z.object({ title: z.string().min(1).max(120), body: z.string().min(1).max(1000) }).parse(req.body);
      const { rows } = await pool.query(
        'INSERT INTO notifications (title, body, created_by) VALUES ($1, $2, $3) RETURNING *',
        [b.title, b.body, req.user!.id]
      );
      await audit(req, 'notification.send', 'notification', rows[0].id, rows[0]);
      res.status(201).json(serializeNotification(rows[0]));
    })
  );

  const contactsSchema = z.object({
    whatsapp: z.string().max(200),
    facebook: z.string().max(200),
    telegram: z.string().max(200),
  });

  router.put(
    '/manage/contacts',
    requireManageSettings,
    asyncHandler(async (req, res) => {
      const b = contactsSchema.parse(req.body);
      const values: Record<(typeof CONTACT_KEYS)[number], string> = {
        contact_whatsapp: b.whatsapp.trim(),
        contact_facebook: b.facebook.trim(),
        contact_telegram: b.telegram.trim(),
      };
      for (const key of CONTACT_KEYS) {
        await pool.query(
          `INSERT INTO app_settings (key, value, updated_by) VALUES ($1, $2, $3)
           ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()`,
          [key, values[key], req.user!.id]
        );
      }
      await audit(req, 'contacts.update', 'app_settings', 'contacts', values);
      res.json(await getContacts());
    })
  );
}

export const MANAGE_SETTINGS = 'manage_settings';

const requireManageSettings = asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
  const { rows } = await pool.query('SELECT responsibilities FROM agent_profiles WHERE user_id = $1', [req.user!.id]);
  const responsibilities: string[] = rows[0]?.responsibilities ?? [];
  if (!responsibilities.includes(MANAGE_SETTINGS)) {
    throw ApiError.forbidden('Your account is not allowed to manage settings. Ask an admin for access.');
  }
  next();
});

function audit(req: Request, action: string, entityType: string, entityId: string, after?: unknown, before?: unknown) {
  return writeAudit({ actorId: req.user!.id, actorRole: 'agent', action, entityType, entityId, after, before });
}

function customerStatus(status: string) {
  return status === 'active' ? 'active' : 'blocked';
}

function serializeHistoryOrder(o: any) {
  return {
    kind: 'order' as const,
    id: o.id,
    orderCode: o.order_code,
    direction: o.direction,
    method: o.method,
    methodLabel: METHOD_LABELS[o.method as keyof typeof METHOD_LABELS] ?? o.method,
    status: o.status,
    amount: fromCents(o.amount_cents),
    counterparty: o.phone_number ?? o.winwin_id,
    reference: o.transaction_ref,
    customerId: o.customer_id,
    customerName: o.customer_name,
    customerPhone: o.customer_phone,
    createdAt: o.created_at,
    completedAt: o.completed_at,
  };
}

function toIsoDate(d: Date | string) {
  return (d instanceof Date ? d : new Date(d)).toISOString().slice(0, 10);
}

/** Inclusive [from, to] day range (UTC) for a report period. */
function reportRange(period: string, from?: string, to?: string) {
  const today = new Date();
  const shift = (days: number) => toIsoDate(new Date(today.getTime() - days * 86_400_000));
  switch (period) {
    case 'weekly':
      return { from: shift(6), to: shift(0) };
    case 'monthly':
      return { from: shift(29), to: shift(0) };
    case 'custom': {
      if (!from || !to) throw ApiError.badRequest('from and to are required for a custom range', 'VALIDATION_ERROR');
      if (from > to) throw ApiError.badRequest('from must be on or before to', 'VALIDATION_ERROR');
      const days = (Date.parse(to) - Date.parse(from)) / 86_400_000;
      if (days > 366) throw ApiError.badRequest('Custom range can be at most one year', 'VALIDATION_ERROR');
      return { from, to };
    }
    default:
      return { from: shift(0), to: shift(0) };
  }
}
