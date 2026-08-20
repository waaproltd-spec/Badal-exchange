import { Router } from 'express';
import { z } from 'zod';
import { pool } from '../db/pool';
import { asyncHandler } from '../lib/asyncHandler';
import { requireAuth, requireRole } from '../auth/middleware';
import { moneyLimiter } from '../auth/rateLimit';
import { requireIdempotencyKey } from '../lib/idempotency';
import { fromCents, toCents } from '../lib/money';
import { submitSmsTransaction, submitWinwinTransaction } from '../services/matchingService';
import { startProcessingWithdraw, completeWithdrawOrder, failOrder } from '../services/orderService';
import { getIntegration } from '../services/paymentIntegrationService';
import { ApiError } from '../lib/errors';

export const agentRouter = Router();
agentRouter.use(requireAuth, requireRole('agent'));

function serializeOrder(o: any) {
  return {
    id: o.id,
    orderCode: o.order_code,
    direction: o.direction,
    method: o.method,
    status: o.status,
    customerId: o.customer_id,
    phoneNumber: o.phone_number,
    winwinId: o.winwin_id,
    depositCode: o.deposit_code,
    amount: fromCents(o.amount_cents),
    fee: fromCents(o.fee_cents),
    netAmount: fromCents(o.net_cents),
    walletDelta: fromCents(o.wallet_delta_cents),
    transactionRef: o.transaction_ref,
    createdAt: o.created_at,
    completedAt: o.completed_at,
  };
}

// ---------------------------------------------------------------------------
// Device registration (SMS reading only permitted from a registered,
// authorized agent device).
// ---------------------------------------------------------------------------
const deviceSchema = z.object({ deviceId: z.string().min(4).max(200), deviceLabel: z.string().max(100).optional() });

agentRouter.post(
  '/devices/register',
  asyncHandler(async (req, res) => {
    const body = deviceSchema.parse(req.body);
    await pool.query(
      `INSERT INTO agent_devices (agent_id, device_id, device_label)
       VALUES ($1, $2, $3)
       ON CONFLICT (agent_id, device_id) DO UPDATE SET last_seen_at = now(), status = 'active'`,
      [req.user!.id, body.deviceId, body.deviceLabel ?? null]
    );
    await pool.query('UPDATE agent_profiles SET last_device_id = $1, last_seen_at = now() WHERE user_id = $2', [
      body.deviceId,
      req.user!.id,
    ]);
    res.status(204).send();
  })
);

// ---------------------------------------------------------------------------
// Dashboard lists
// ---------------------------------------------------------------------------
agentRouter.get(
  '/deposits/pending',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT * FROM orders WHERE direction = 'deposit' AND status = 'pending' ORDER BY created_at ASC LIMIT 200`
    );
    res.json(rows.map(serializeOrder));
  })
);

agentRouter.get(
  '/withdrawals/pending',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(
      `SELECT * FROM orders WHERE direction = 'withdraw' AND status IN ('pending','processing') ORDER BY created_at ASC LIMIT 200`
    );
    res.json(rows.map(serializeOrder));
  })
);

agentRouter.get(
  '/orders/completed',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(`SELECT * FROM orders WHERE status = 'completed' ORDER BY completed_at DESC LIMIT 200`);
    res.json(rows.map(serializeOrder));
  })
);

agentRouter.get(
  '/orders/failed',
  asyncHandler(async (_req, res) => {
    const { rows } = await pool.query(`SELECT * FROM orders WHERE status = 'failed' ORDER BY updated_at DESC LIMIT 200`);
    res.json(rows.map(serializeOrder));
  })
);

// ---------------------------------------------------------------------------
// EVC Plus payment SMS submission (extracted fields only, never raw SMS body).
// ---------------------------------------------------------------------------
const smsSchema = z.object({
  provider: z.string().min(2).max(50),
  sender: z.string().min(4).max(20).optional(),
  receiver: z.string().min(4).max(20).optional(),
  amount: z.string().or(z.number()),
  transactionRef: z.string().min(3).max(100),
  occurredAt: z.string(),
  deviceId: z.string().max(200).optional(),
});

agentRouter.post(
  '/sms-transactions',
  moneyLimiter,
  requireIdempotencyKey('agent.sms_transactions'),
  asyncHandler(async (req, res) => {
    const body = smsSchema.parse(req.body);
    const result = await submitSmsTransaction({
      agentId: req.user!.id,
      deviceId: body.deviceId,
      provider: body.provider,
      sender: body.sender,
      receiver: body.receiver,
      amountCents: toCents(body.amount),
      transactionRef: body.transactionRef,
      occurredAt: body.occurredAt,
    });
    res.status(result.status === 'duplicate' ? 200 : 201).json(result);
  })
);

// ---------------------------------------------------------------------------
// WinWin/MobCash confirmation submission (agent/admin observed the real
// transaction in the WinWin manager app and keys the result in here).
// ---------------------------------------------------------------------------
const winwinSchema = z.object({
  winwinId: z.string().min(3).max(30),
  depositCode: z.string().min(3).max(10).optional(),
  amount: z.string().or(z.number()),
  mobcashRef: z.string().min(3).max(100),
  occurredAt: z.string(),
});

agentRouter.post(
  '/winwin-transactions',
  moneyLimiter,
  requireIdempotencyKey('agent.winwin_transactions'),
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
// Withdrawal processing
// ---------------------------------------------------------------------------

/**
 * Non-secret: just the "Dial to Pay" payout USSD template (e.g.
 * "*712*{number}*{amount}#"), never credentials or a PIN -- the agent enters
 * their own PIN in the native EVC Plus USSD prompt the dial opens, never
 * inside this app. Null if an admin hasn't configured one yet.
 */
agentRouter.get(
  '/evc-payout-template',
  asyncHandler(async (_req, res) => {
    const integration = await getIntegration('evc_plus');
    const template = (integration?.configJson?.payout_ussd_template as string | undefined) ?? null;
    res.json({ ussdTemplate: template });
  })
);

agentRouter.post(
  '/withdrawals/:orderId/start',
  asyncHandler(async (req, res) => {
    const order = await startProcessingWithdraw(req.params.orderId, req.user!.id, 'agent');
    res.json(serializeOrder(order));
  })
);

const completeSchema = z.object({ transactionRef: z.string().min(3).max(100) });

agentRouter.post(
  '/withdrawals/:orderId/complete',
  requireIdempotencyKey('agent.withdrawals.complete'),
  asyncHandler(async (req, res) => {
    const body = completeSchema.parse(req.body);
    const order = await completeWithdrawOrder(req.params.orderId, body.transactionRef, req.user!.id, 'agent');
    res.json(serializeOrder(order));
  })
);

const failSchema = z.object({ reason: z.string().min(3).max(300) });

agentRouter.post(
  '/withdrawals/:orderId/fail',
  asyncHandler(async (req, res) => {
    const body = failSchema.parse(req.body);
    const order = await failOrder(req.params.orderId, body.reason, req.user!.id, 'agent');
    res.json(serializeOrder(order));
  })
);

agentRouter.get(
  '/profile',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query(
      `SELECT u.id, u.name, u.phone, u.status, ap.responsibilities, ap.last_seen_at
       FROM users u LEFT JOIN agent_profiles ap ON ap.user_id = u.id WHERE u.id = $1`,
      [req.user!.id]
    );
    if (!rows[0]) throw ApiError.notFound('Agent not found');
    res.json(rows[0]);
  })
);
