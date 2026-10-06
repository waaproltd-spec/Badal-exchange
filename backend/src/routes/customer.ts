import { Router } from 'express';
import { z } from 'zod';
import { pool, withTransaction } from '../db/pool';
import { asyncHandler } from '../lib/asyncHandler';
import { requireAuth, requireRole } from '../auth/middleware';
import { moneyLimiter } from '../auth/rateLimit';
import { requireIdempotencyKey } from '../lib/idempotency';
import { toCents, fromCents } from '../lib/money';
import { computeQuote, Direction } from '../services/rateFeeService';
import { createDepositOrder, createWithdrawOrder } from '../services/orderService';
import { lockWallet } from '../services/walletService';
import { ApiError } from '../lib/errors';
import { METHODS, Method, isMethod, isMobileMoney } from '../lib/methods';
import {
  assertMethodEnabled,
  getContacts,
  listDepositNumbers,
  listHomeAds,
  listNotifications,
  listPaymentMethods,
} from '../services/settingsService';

export const customerRouter = Router();
customerRouter.use(requireAuth, requireRole('customer'));

// ---------------------------------------------------------------------------
// Wallet
// ---------------------------------------------------------------------------
function serializeWallet(w: any) {
  return {
    availableBalance: fromCents(w.available_cents),
    pendingBalance: fromCents(w.pending_cents),
    totalDeposit: fromCents(w.total_deposit_cents),
    totalWithdraw: fromCents(w.total_withdraw_cents),
  };
}

customerRouter.get(
  '/wallet',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query('SELECT * FROM wallets WHERE customer_id = $1', [req.user!.id]);
    const wallet = rows[0] ?? (await withTransaction((c) => lockWallet(c, req.user!.id)));
    res.json(serializeWallet(wallet));
  })
);

// ---------------------------------------------------------------------------
// Quotes -- the backend is the only source of the rate/fee math the
// confirmation screen shows. Amounts are decimal strings on the wire.
// ---------------------------------------------------------------------------
const quoteSchema = z.object({
  direction: z.enum(['deposit', 'withdraw']),
  method: z.enum(METHODS),
  amount: z.string().or(z.number()),
});

customerRouter.post(
  '/quotes',
  asyncHandler(async (req, res) => {
    const body = quoteSchema.parse(req.body);
    const amountCents = toCents(body.amount);
    const quote = await computeQuote(pool, body.method as Method, body.direction as Direction, amountCents);
    res.json({
      quoteId: `${quote.rateId}:${quote.feeId ?? 'none'}:${quote.amountCents}`,
      method: quote.method,
      direction: quote.direction,
      amount: fromCents(quote.amountCents),
      rate: quote.rate,
      fee: fromCents(quote.feeCents),
      netAmount: fromCents(quote.netCents),
      walletDelta: fromCents(quote.walletDeltaCents),
    });
  })
);

function serializeOrder(o: any) {
  return {
    id: o.id,
    orderCode: o.order_code,
    direction: o.direction,
    method: o.method,
    status: o.status,
    statusMessage: STATUS_MESSAGES[o.status] ?? '',
    phoneNumber: o.phone_number,
    accountId: o.winwin_id,
    winwinId: o.winwin_id, // kept for app versions before multi-method support
    depositCode: o.deposit_code,
    amount: fromCents(o.amount_cents),
    fee: fromCents(o.fee_cents),
    netAmount: fromCents(o.net_cents),
    transactionRef: o.transaction_ref,
    failureReason: o.failure_reason,
    createdAt: o.created_at,
    completedAt: o.completed_at,
  };
}

const STATUS_MESSAGES: Record<string, string> = {
  pending: 'Your transaction is being verified.',
  processing: 'Your transaction is being processed.',
  completed: 'Transaction completed successfully.',
  failed: 'Transaction failed. Your balance was not charged.',
  cancelled: 'Transaction was cancelled.',
  expired: 'Transaction expired.',
};

// ---------------------------------------------------------------------------
// Deposits & withdrawals, for every payment method.
//
// Mobile-money methods take the customer's `phoneNumber` on that service;
// betting platforms take the customer's `accountId` there (`winwinId` is
// accepted as an alias for older app versions).
// ---------------------------------------------------------------------------
const orderBodySchema = z.object({
  phoneNumber: z.string().min(6).max(20).optional(),
  accountId: z.string().min(3).max(30).optional(),
  winwinId: z.string().min(3).max(30).optional(),
  amount: z.string().or(z.number()),
});

function parseOrderBody(method: Method, raw: unknown) {
  const body = orderBodySchema.parse(raw);
  if (isMobileMoney(method)) {
    if (!body.phoneNumber) throw ApiError.badRequest('phoneNumber is required', 'VALIDATION_ERROR');
    return { phoneNumber: body.phoneNumber, amountCents: toCents(body.amount) };
  }
  const accountId = body.accountId ?? body.winwinId;
  if (!accountId) throw ApiError.badRequest('accountId is required', 'VALIDATION_ERROR');
  return { accountId, amountCents: toCents(body.amount) };
}

function methodParam(raw: string): Method {
  // 'evc' is the original EVC Plus route name.
  const method = raw === 'evc' ? 'evc_plus' : raw;
  if (!isMethod(method)) throw ApiError.notFound('Unknown payment method');
  return method;
}

customerRouter.post(
  '/deposits/:method',
  moneyLimiter,
  (req, res, next) => requireIdempotencyKey(`customer.deposits.${req.params.method}`)(req, res, next),
  asyncHandler(async (req, res) => {
    const method = methodParam(req.params.method);
    const { amountCents, ...counterparty } = parseOrderBody(method, req.body);
    await assertMethodEnabled(method);
    const quote = await computeQuote(pool, method, 'deposit', amountCents);
    const order = await createDepositOrder({
      customerId: req.user!.id,
      quote,
      ...counterparty,
      idempotencyKey: req.header('Idempotency-Key') ?? null,
    });
    res.status(201).json(serializeOrder(order));
  })
);

customerRouter.post(
  '/withdrawals/:method',
  moneyLimiter,
  (req, res, next) => requireIdempotencyKey(`customer.withdrawals.${req.params.method}`)(req, res, next),
  asyncHandler(async (req, res) => {
    const method = methodParam(req.params.method);
    const { amountCents, ...counterparty } = parseOrderBody(method, req.body);
    await assertMethodEnabled(method);
    const quote = await computeQuote(pool, method, 'withdraw', amountCents);
    const order = await createWithdrawOrder({
      customerId: req.user!.id,
      quote,
      ...counterparty,
      idempotencyKey: req.header('Idempotency-Key') ?? null,
    });
    res.status(201).json(serializeOrder(order));

    if (method === 'winwin') {
      // Fire-and-forget: if MobCash automation is on, try to process this
      // withdrawal immediately instead of waiting for the periodic sweep.
      // Never blocks or affects the customer's response either way -- the
      // response above already reflects the real, currently-pending state.
      import('../services/automationOrchestrator')
        .then((m) => m.runAutomatedWithdrawal(order.id))
        .catch((err) => console.error('Automated withdrawal trigger failed', order.id, err instanceof Error ? err.message : err));
    }
  })
);

// ---------------------------------------------------------------------------
// App content managed from the Agent App (read-only here).
// ---------------------------------------------------------------------------
customerRouter.get(
  '/payment-methods',
  asyncHandler(async (_req, res) => {
    const [methods, numbers] = await Promise.all([listPaymentMethods(), listDepositNumbers({ enabledOnly: true })]);
    res.json(
      methods
        .filter((m) => m.enabled)
        .map((m) => ({
          method: m.method,
          label: m.label,
          kind: m.kind,
          depositNumbers: numbers.filter((n) => n.method === m.method).map((n) => ({ number: n.number, label: n.label })),
        }))
    );
  })
);

customerRouter.get(
  '/home-ads',
  asyncHandler(async (_req, res) => {
    res.json(await listHomeAds({ enabledOnly: true }));
  })
);

customerRouter.get(
  '/notifications',
  asyncHandler(async (_req, res) => {
    res.json(await listNotifications(50));
  })
);

customerRouter.get(
  '/contacts',
  asyncHandler(async (_req, res) => {
    res.json(await getContacts());
  })
);

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------
customerRouter.get(
  '/orders',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query(
      'SELECT * FROM orders WHERE customer_id = $1 ORDER BY created_at DESC LIMIT 100',
      [req.user!.id]
    );
    res.json(rows.map(serializeOrder));
  })
);

customerRouter.get(
  '/orders/:id',
  asyncHandler(async (req, res) => {
    const { rows } = await pool.query('SELECT * FROM orders WHERE id = $1 AND customer_id = $2', [
      req.params.id,
      req.user!.id,
    ]);
    if (!rows[0]) throw ApiError.notFound('Order not found');
    res.json(serializeOrder(rows[0]));
  })
);
