import { Router } from 'express';
import { z } from 'zod';
import { pool } from '../db/pool';
import { asyncHandler } from '../lib/asyncHandler';
import { requireAuth, requireRole } from '../auth/middleware';
import { fromCents } from '../lib/money';
import { hashPassword } from '../lib/crypto';
import { writeAudit } from '../lib/audit';
import { ApiError } from '../lib/errors';
import {
  getIntegration,
  listIntegrations,
  upsertIntegrationCredentials,
  setIntegrationStatus,
  testIntegrationConnection,
  setAutomationMode,
  resetCircuitBreaker,
  IntegrationProvider,
} from '../services/paymentIntegrationService';
import { submitWinwinTransaction } from '../services/matchingService';
import { moneyLimiter } from '../auth/rateLimit';
import { requireIdempotencyKey } from '../lib/idempotency';
import { toCents } from '../lib/money';

export const adminRouter = Router();
adminRouter.use(requireAuth, requireRole('admin'));

function serializeOrder(o: any) {
  return {
    id: o.id,
    orderCode: o.order_code,
    direction: o.direction,
    method: o.method,
    status: o.status,
    customerId: o.customer_id,
    agentId: o.agent_id,
    phoneNumber: o.phone_number,
    winwinId: o.winwin_id,
    amount: fromCents(o.amount_cents),
    fee: fromCents(o.fee_cents),
    netAmount: fromCents(o.net_cents),
    transactionRef: o.transaction_ref,
    createdAt: o.created_at,
    completedAt: o.completed_at,
  };
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------
adminRouter.get(
  '/dashboard/summary',
  asyncHandler(async (_req, res) => {
    const [customers, walletTotals, today, pending, completedFailed] = await Promise.all([
      pool.query(`SELECT count(*)::int AS n FROM users WHERE role = 'customer'`),
      pool.query(`SELECT COALESCE(sum(available_cents),0) AS avail, COALESCE(sum(pending_cents),0) AS pend FROM wallets`),
      pool.query(
        `SELECT
           COALESCE(sum(CASE WHEN direction='deposit' AND status='completed' THEN net_cents ELSE 0 END),0) AS deposits_today,
           COALESCE(sum(CASE WHEN direction='withdraw' AND status='completed' THEN wallet_delta_cents ELSE 0 END),0) AS withdrawals_today
         FROM orders WHERE completed_at::date = now()::date`
      ),
      pool.query(
        `SELECT
           count(*) FILTER (WHERE direction='deposit' AND status='pending')::int AS pending_deposits,
           count(*) FILTER (WHERE direction='withdraw' AND status IN ('pending','processing'))::int AS pending_withdrawals
         FROM orders`
      ),
      pool.query(
        `SELECT count(*) FILTER (WHERE status='completed')::int AS completed, count(*) FILTER (WHERE status='failed')::int AS failed FROM orders`
      ),
    ]);

    res.json({
      totalCustomers: customers.rows[0].n,
      totalWalletBalance: fromCents(walletTotals.rows[0].avail),
      totalWalletPending: fromCents(walletTotals.rows[0].pend),
      todaysDeposits: fromCents(today.rows[0].deposits_today),
      todaysWithdrawals: fromCents(today.rows[0].withdrawals_today),
      pendingDeposits: pending.rows[0].pending_deposits,
      pendingWithdrawals: pending.rows[0].pending_withdrawals,
      completedTransactions: completedFailed.rows[0].completed,
      failedTransactions: completedFailed.rows[0].failed,
    });
  })
);

// ---------------------------------------------------------------------------
// Customers
// ---------------------------------------------------------------------------
adminRouter.get(
  '/customers',
  asyncHandler(async (req, res) => {
    const search = (req.query.q as string | undefined)?.trim();
    const params: unknown[] = [];
    let where = `WHERE u.role = 'customer'`;
    if (search) {
      params.push(`%${search}%`);
      where += ` AND (u.phone ILIKE $${params.length} OR u.name ILIKE $${params.length})`;
    }
    const { rows } = await pool.query(
      `SELECT u.id, u.name, u.phone, u.status, u.created_at,
              COALESCE(w.available_cents,0) AS available_cents,
              COALESCE(w.total_deposit_cents,0) AS total_deposit_cents,
              COALESCE(w.total_withdraw_cents,0) AS total_withdraw_cents
       FROM users u LEFT JOIN wallets w ON w.customer_id = u.id
       ${where}
       ORDER BY u.created_at DESC LIMIT 200`,
      params
    );
    res.json(
      rows.map((r) => ({
        id: r.id,
        name: r.name,
        phone: r.phone,
        status: r.status,
        walletBalance: fromCents(r.available_cents),
        totalDeposits: fromCents(r.total_deposit_cents),
        totalWithdrawals: fromCents(r.total_withdraw_cents),
        registeredAt: r.created_at,
      }))
    );
  })
);

adminRouter.get(
  '/customers/:id',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query(
      `SELECT u.*, w.available_cents, w.pending_cents, w.total_deposit_cents, w.total_withdraw_cents
       FROM users u LEFT JOIN wallets w ON w.customer_id = u.id WHERE u.id = $1 AND u.role='customer'`,
      [req.params.id]
    );
    if (!rows[0]) throw ApiError.notFound('Customer not found');
    const r = rows[0];
    res.json({
      id: r.id,
      name: r.name,
      phone: r.phone,
      status: r.status,
      wallet: {
        availableBalance: fromCents(r.available_cents ?? 0),
        pendingBalance: fromCents(r.pending_cents ?? 0),
        totalDeposit: fromCents(r.total_deposit_cents ?? 0),
        totalWithdraw: fromCents(r.total_withdraw_cents ?? 0),
      },
      registeredAt: r.created_at,
    });
  })
);

// ---------------------------------------------------------------------------
// Agents
// ---------------------------------------------------------------------------
const createAgentSchema = z.object({
  phone: z.string().min(6).max(20),
  name: z.string().min(1).max(100),
  password: z.string().min(8).max(72),
  responsibilities: z.array(z.string()).optional(),
});

adminRouter.get(
  '/agents',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT u.id, u.name, u.phone, u.status, u.created_at, ap.responsibilities, ap.last_seen_at, ap.last_device_id
       FROM users u LEFT JOIN agent_profiles ap ON ap.user_id = u.id
       WHERE u.role = 'agent' ORDER BY u.created_at DESC`
    );
    res.json(rows);
  })
);

adminRouter.post(
  '/agents',
  asyncHandler(async (req, res) => {
    const body = createAgentSchema.parse(req.body);
    const existing = await pool.query('SELECT 1 FROM users WHERE phone = $1', [body.phone]);
    if (existing.rows[0]) throw ApiError.conflict('Phone number already registered', 'PHONE_TAKEN');
    const passwordHash = await hashPassword(body.password);
    const { rows } = await pool.query(
      `INSERT INTO users (role, phone, name, password_hash) VALUES ('agent', $1, $2, $3) RETURNING id, name, phone, status`,
      [body.phone, body.name, passwordHash]
    );
    const agent = rows[0];
    await pool.query('INSERT INTO agent_profiles (user_id, responsibilities) VALUES ($1, $2)', [
      agent.id,
      body.responsibilities ?? [],
    ]);
    await writeAudit({ actorId: req.user!.id, actorRole: 'admin', action: 'agent.create', entityType: 'user', entityId: agent.id, after: agent });
    res.status(201).json(agent);
  })
);

async function setAgentStatus(req: any, res: any, status: 'active' | 'disabled') {
  const before = await pool.query(`SELECT id, status FROM users WHERE id = $1 AND role='agent'`, [req.params.id]);
  if (!before.rows[0]) throw ApiError.notFound('Agent not found');
  const { rows } = await pool.query(`UPDATE users SET status = $1, updated_at = now() WHERE id = $2 RETURNING id, status`, [
    status,
    req.params.id,
  ]);
  await writeAudit({
    actorId: req.user!.id,
    actorRole: 'admin',
    action: `agent.${status === 'active' ? 'enable' : 'disable'}`,
    entityType: 'user',
    entityId: req.params.id,
    before: before.rows[0],
    after: rows[0],
  });
  res.json(rows[0]);
}

adminRouter.post('/agents/:id/enable', asyncHandler((req, res) => setAgentStatus(req, res, 'active')));
adminRouter.post('/agents/:id/disable', asyncHandler((req, res) => setAgentStatus(req, res, 'disabled')));

adminRouter.get(
  '/agents/:id/transactions',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query(
      `SELECT * FROM orders WHERE agent_id = $1 ORDER BY updated_at DESC LIMIT 200`,
      [req.params.id]
    );
    res.json(rows.map(serializeOrder));
  })
);

adminRouter.get(
  '/agents/:id/devices',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query(
      `SELECT device_id, device_label, status, registered_at, last_seen_at FROM agent_devices WHERE agent_id = $1 ORDER BY last_seen_at DESC NULLS LAST`,
      [req.params.id]
    );
    res.json(rows);
  })
);

// ---------------------------------------------------------------------------
// Wallets
// ---------------------------------------------------------------------------
adminRouter.get(
  '/wallets',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT w.*, u.name, u.phone FROM wallets w JOIN users u ON u.id = w.customer_id ORDER BY w.updated_at DESC LIMIT 200`
    );
    res.json(
      rows.map((w) => ({
        customerId: w.customer_id,
        name: w.name,
        phone: w.phone,
        availableBalance: fromCents(w.available_cents),
        pendingBalance: fromCents(w.pending_cents),
        totalDeposit: fromCents(w.total_deposit_cents),
        totalWithdraw: fromCents(w.total_withdraw_cents),
      }))
    );
  })
);

adminRouter.get(
  '/wallets/:customerId/ledger',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query(
      `SELECT le.* FROM ledger_entries le
       JOIN wallets w ON w.id = le.wallet_id
       WHERE w.customer_id = $1 ORDER BY le.created_at DESC LIMIT 200`,
      [req.params.customerId]
    );
    res.json(
      rows.map((l) => ({
        id: l.id,
        orderId: l.order_id,
        type: l.entry_type,
        amount: fromCents(l.amount_cents),
        balanceAfter: fromCents(l.balance_after_cents),
        reason: l.reason,
        createdAt: l.created_at,
      }))
    );
  })
);

// ---------------------------------------------------------------------------
// Deposits / Withdrawals / Orders / Transactions (ledger)
// ---------------------------------------------------------------------------
function listOrdersHandler(direction: 'deposit' | 'withdraw' | null) {
  return asyncHandler(async (req: any, res: any) => {
    const status = req.query.status as string | undefined;
    const params: unknown[] = [];
    const clauses: string[] = [];
    if (direction) {
      params.push(direction);
      clauses.push(`direction = $${params.length}`);
    }
    if (status) {
      params.push(status);
      clauses.push(`status = $${params.length}`);
    }
    const where = clauses.length ? `WHERE ${clauses.join(' AND ')}` : '';
    const { rows } = await pool.query(`SELECT * FROM orders ${where} ORDER BY created_at DESC LIMIT 300`, params);
    res.json(rows.map(serializeOrder));
  });
}

adminRouter.get('/deposits', listOrdersHandler('deposit'));
adminRouter.get('/withdrawals', listOrdersHandler('withdraw'));
adminRouter.get('/orders', listOrdersHandler(null));

adminRouter.get(
  '/orders/:id',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query('SELECT * FROM orders WHERE id = $1', [req.params.id]);
    if (!rows[0]) throw ApiError.notFound('Order not found');
    res.json(serializeOrder(rows[0]));
  })
);

adminRouter.get(
  '/transactions',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT le.*, w.customer_id FROM ledger_entries le JOIN wallets w ON w.id = le.wallet_id ORDER BY le.created_at DESC LIMIT 300`
    );
    res.json(
      rows.map((l) => ({
        id: l.id,
        customerId: l.customer_id,
        orderId: l.order_id,
        type: l.entry_type,
        amount: fromCents(l.amount_cents),
        balanceAfter: fromCents(l.balance_after_cents),
        reason: l.reason,
        createdAt: l.created_at,
      }))
    );
  })
);

// ---------------------------------------------------------------------------
// Exchange rates
// ---------------------------------------------------------------------------
const rateSchema = z.object({
  method: z.enum(['evc_plus', 'winwin']),
  direction: z.enum(['deposit', 'withdraw']),
  rate: z.number().positive(),
});

adminRouter.get(
  '/exchange-rates',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT DISTINCT ON (method, direction) * FROM exchange_rates WHERE active = true ORDER BY method, direction, created_at DESC`
    );
    res.json(rows);
  })
);

adminRouter.put(
  '/exchange-rates',
  asyncHandler(async (req, res) => {
    const body = rateSchema.parse(req.body);
    // Snapshot model: deactivate the old active rate, insert a new one.
    // Past orders keep referencing the old row via exchange_rate_id, so
    // history never changes.
    await pool.query(`UPDATE exchange_rates SET active = false WHERE method = $1 AND direction = $2 AND active = true`, [
      body.method,
      body.direction,
    ]);
    const { rows } = await pool.query(
      `INSERT INTO exchange_rates (method, direction, rate, created_by) VALUES ($1, $2, $3, $4) RETURNING *`,
      [body.method, body.direction, body.rate, req.user!.id]
    );
    await writeAudit({ actorId: req.user!.id, actorRole: 'admin', action: 'exchange_rate.update', entityType: 'exchange_rate', entityId: rows[0].id, after: rows[0] });
    res.status(201).json(rows[0]);
  })
);

// ---------------------------------------------------------------------------
// Fees
// ---------------------------------------------------------------------------
const feeSchema = z.object({
  method: z.enum(['evc_plus', 'winwin']),
  direction: z.enum(['deposit', 'withdraw']),
  feeType: z.enum(['flat', 'percent']),
  value: z.number().min(0),
});

adminRouter.get(
  '/fees',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT DISTINCT ON (method, direction) * FROM fees WHERE active = true ORDER BY method, direction, created_at DESC`
    );
    res.json(rows);
  })
);

adminRouter.put(
  '/fees',
  asyncHandler(async (req, res) => {
    const body = feeSchema.parse(req.body);
    await pool.query(`UPDATE fees SET active = false WHERE method = $1 AND direction = $2 AND active = true`, [
      body.method,
      body.direction,
    ]);
    const { rows } = await pool.query(
      `INSERT INTO fees (method, direction, fee_type, value, created_by) VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [body.method, body.direction, body.feeType, body.value, req.user!.id]
    );
    await writeAudit({ actorId: req.user!.id, actorRole: 'admin', action: 'fee.update', entityType: 'fee', entityId: rows[0].id, after: rows[0] });
    res.status(201).json(rows[0]);
  })
);

const limitsSchema = z.object({ method: z.enum(['evc_plus', 'winwin']), minAmount: z.number().min(0), maxAmount: z.number().min(0) });

adminRouter.put(
  '/withdrawal-limits',
  asyncHandler(async (req, res) => {
    const body = limitsSchema.parse(req.body);
    const minCents = Math.round(body.minAmount * 100);
    const maxCents = Math.round(body.maxAmount * 100);
    const { rows } = await pool.query(
      `INSERT INTO withdrawal_limits (method, min_cents, max_cents) VALUES ($1, $2, $3)
       ON CONFLICT (method) DO UPDATE SET min_cents = EXCLUDED.min_cents, max_cents = EXCLUDED.max_cents, updated_at = now()
       RETURNING *`,
      [body.method, minCents, maxCents]
    );
    await writeAudit({ actorId: req.user!.id, actorRole: 'admin', action: 'withdrawal_limits.update', entityType: 'withdrawal_limits', entityId: body.method, after: rows[0] });
    res.json(rows[0]);
  })
);

// ---------------------------------------------------------------------------
// Audit logs
// ---------------------------------------------------------------------------
adminRouter.get(
  '/audit-logs',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(`SELECT * FROM audit_logs ORDER BY created_at DESC LIMIT 300`);
    res.json(rows);
  })
);

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------
adminRouter.get(
  '/reports/daily',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT
         created_at::date AS day,
         direction, method, status,
         count(*)::int AS count,
         COALESCE(sum(amount_cents),0) AS amount_cents
       FROM orders
       WHERE created_at > now() - interval '30 days'
       GROUP BY 1,2,3,4 ORDER BY 1 DESC`
    );
    res.json(rows.map((r) => ({ ...r, amount: fromCents(r.amount_cents), amount_cents: undefined })));
  })
);

// ---------------------------------------------------------------------------
// Payment Integrations (EVC Plus, MobCash/WinWin)
// ---------------------------------------------------------------------------
const providerParam = z.enum(['evc_plus', 'mobcash_winwin']);

adminRouter.get(
  '/payment-integrations',
  asyncHandler(async (_req, res) => {
    res.json(await listIntegrations());
  })
);

adminRouter.get(
  '/payment-integrations/:provider',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const integration = await getIntegration(provider);
    res.json(integration ?? { provider, status: 'inactive', configJson: {}, hasCredentials: false, username: null });
  })
);

const credentialsSchema = z.object({
  username: z.string().min(1).max(200),
  password: z.string().min(1).max(200),
  config: z.record(z.unknown()).optional(),
});

adminRouter.put(
  '/payment-integrations/:provider/credentials',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const body = credentialsSchema.parse(req.body);
    const result = await upsertIntegrationCredentials(
      provider,
      body.username,
      body.password,
      body.config ?? {},
      req.user!.id,
      'admin'
    );
    res.json(result);
  })
);

const statusSchema = z.object({ status: z.enum(['active', 'inactive']) });

adminRouter.put(
  '/payment-integrations/:provider/status',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const body = statusSchema.parse(req.body);
    const result = await setIntegrationStatus(provider, body.status, req.user!.id, 'admin');
    res.json(result);
  })
);

adminRouter.post(
  '/payment-integrations/:provider/test-connection',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const result = await testIntegrationConnection(provider, req.user!.id, 'admin');
    res.json(result);
  })
);

// ---------------------------------------------------------------------------
// Manual WinWin/MobCash confirmation (admin/manager oversight path). Same
// verified-match semantics as the agent endpoint: the admin has observed a
// real, completed transaction in the actual WinWin manager app and keys the
// result in here; the backend matches it against the pending order by
// deposit code + WinWin ID + amount and dedupes by MobCash reference before
// crediting the wallet. Never auto-generated, never trusted from the app.
// ---------------------------------------------------------------------------
const winwinSchema = z.object({
  winwinId: z.string().min(3).max(30),
  depositCode: z.string().min(3).max(10).optional(),
  amount: z.string().or(z.number()),
  mobcashRef: z.string().min(3).max(100),
  occurredAt: z.string(),
});

adminRouter.post(
  '/winwin-transactions',
  moneyLimiter,
  requireIdempotencyKey('admin.winwin_transactions'),
  asyncHandler(async (req, res) => {
    const body = winwinSchema.parse(req.body);
    const result = await submitWinwinTransaction({
      submittedBy: req.user!.id,
      winwinId: body.winwinId,
      depositCode: body.depositCode,
      amountCents: toCents(body.amount),
      mobcashRef: body.mobcashRef,
      occurredAt: body.occurredAt,
    });
    res.status(result.status === 'duplicate' ? 200 : 201).json(result);
  })
);

// ---------------------------------------------------------------------------
// MobCash browser-automation controls. No official MobCash/WinWin API is
// confirmed to exist -- "automatic" here means backend-driven browser
// automation of the real MobCash Business Web portal, explicitly
// authorized in place of the default manual-confirmation flow. See
// mobcashAutomation.ts for the full safety-rail rationale.
// ---------------------------------------------------------------------------
const automationSchema = z.object({
  mode: z.enum(['manual', 'automatic']),
  dryRun: z.boolean(),
});

adminRouter.put(
  '/payment-integrations/:provider/automation',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const body = automationSchema.parse(req.body);
    const result = await setAutomationMode(provider, body.mode, body.dryRun, req.user!.id, 'admin');
    res.json(result);
  })
);

adminRouter.post(
  '/payment-integrations/:provider/reset-circuit-breaker',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const result = await resetCircuitBreaker(provider, req.user!.id, 'admin');
    res.json(result);
  })
);

adminRouter.get(
  '/payment-integrations/:provider/automation-runs',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const { rows } = await pool.query(
      `SELECT id, run_type, order_id, status, message, (screenshot_base64 IS NOT NULL) AS has_screenshot, started_at, finished_at
       FROM automation_runs WHERE provider = $1 ORDER BY finished_at DESC LIMIT 100`,
      [provider]
    );
    res.json(rows);
  })
);

adminRouter.get(
  '/payment-integrations/:provider/automation-runs/:runId/screenshot',
  asyncHandler(async (req, res) => {
    const provider = providerParam.parse(req.params.provider) as IntegrationProvider;
    const { rows } = await pool.query(
      `SELECT screenshot_base64 FROM automation_runs WHERE id = $1 AND provider = $2`,
      [req.params.runId, provider]
    );
    if (!rows[0]?.screenshot_base64) throw ApiError.notFound('No screenshot for this run');
    res.json({ screenshotBase64: rows[0].screenshot_base64 });
  })
);
