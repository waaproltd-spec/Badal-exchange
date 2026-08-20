import { Router } from 'express';
import { z } from 'zod';
import { pool, withTransaction } from '../db/pool';
import { asyncHandler } from '../lib/asyncHandler';
import { requireAuth, requireRole } from '../auth/middleware';
import { moneyLimiter } from '../auth/rateLimit';
import { requireIdempotencyKey } from '../lib/idempotency';
import { toCents, fromCents } from '../lib/money';
import { computeQuote, Method, Direction } from '../services/rateFeeService';
import { createDepositOrder, createWithdrawOrder } from '../services/orderService';
import { redeemCashdeskBotPayout } from '../services/automationOrchestrator';
import { getIntegration } from '../services/paymentIntegrationService';
import { lockWallet } from '../services/walletService';
import { ApiError } from '../lib/errors';

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
  method: z.enum(['evc_plus', 'winwin']),
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
    winwinId: o.winwin_id,
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
// Deposits
// ---------------------------------------------------------------------------
const evcDepositSchema = z.object({ phoneNumber: z.string().min(6).max(20), amount: z.string().or(z.number()) });
const winwinDepositSchema = z.object({ winwinId: z.string().min(3).max(30), amount: z.string().or(z.number()) });
// Badal Deposit -> 888STARZ -> CashdeskBot Payout -> Badal Wallet. The
// customer types the 4-digit withdrawal code 888STARZ generated for them --
// never an amount; the wallet is credited with exactly what CashdeskBot
// confirms once the code is redeemed.
const winwinPayoutRedeemSchema = z.object({
  winwinId: z.string().min(3).max(30),
  code: z.string().regex(/^\d{4}$/, 'Enter the 4-digit code from 888STARZ'),
});

/**
 * Non-secret: just the "Dial to Pay" USSD template (e.g. "*712*<number>*{amount}#"),
 * never credentials. Returns null if an admin hasn't configured one yet --
 * the app hides the auto-dial step in that case rather than dialing nothing.
 */
customerRouter.get(
  '/deposits/evc/ussd-template',
  asyncHandler(async (_req, res) => {
    const integration = await getIntegration('evc_plus');
    const template = (integration?.configJson?.ussd_template as string | undefined) ?? null;
    res.json({ ussdTemplate: template });
  })
);

customerRouter.post(
  '/deposits/evc',
  moneyLimiter,
  requireIdempotencyKey('customer.deposits.evc'),
  asyncHandler(async (req, res) => {
    const body = evcDepositSchema.parse(req.body);
    const amountCents = toCents(body.amount);
    const quote = await computeQuote(pool, 'evc_plus', 'deposit', amountCents);
    const order = await createDepositOrder({
      customerId: req.user!.id,
      quote,
      phoneNumber: body.phoneNumber,
      idempotencyKey: req.header('Idempotency-Key') ?? null,
    });
    res.status(201).json(serializeOrder(order));
  })
);

customerRouter.post(
  '/deposits/winwin',
  moneyLimiter,
  requireIdempotencyKey('customer.deposits.winwin'),
  asyncHandler(async (req, res) => {
    const body = winwinPayoutRedeemSchema.parse(req.body);
    const order = await redeemCashdeskBotPayout({
      customerId: req.user!.id,
      winwinId: body.winwinId,
      code: body.code,
    });
    res.status(201).json(serializeOrder(order));
  })
);

// ---------------------------------------------------------------------------
// Withdrawals
// ---------------------------------------------------------------------------
customerRouter.post(
  '/withdrawals/evc',
  moneyLimiter,
  requireIdempotencyKey('customer.withdrawals.evc'),
  asyncHandler(async (req, res) => {
    const body = evcDepositSchema.parse(req.body);
    const amountCents = toCents(body.amount);
    const quote = await computeQuote(pool, 'evc_plus', 'withdraw', amountCents);
    const order = await createWithdrawOrder({
      customerId: req.user!.id,
      quote,
      phoneNumber: body.phoneNumber,
      idempotencyKey: req.header('Idempotency-Key') ?? null,
    });
    res.status(201).json(serializeOrder(order));
  })
);

customerRouter.post(
  '/withdrawals/winwin',
  moneyLimiter,
  requireIdempotencyKey('customer.withdrawals.winwin'),
  asyncHandler(async (req, res) => {
    const body = winwinDepositSchema.parse(req.body);
    const amountCents = toCents(body.amount);
    const quote = await computeQuote(pool, 'winwin', 'withdraw', amountCents);
    const order = await createWithdrawOrder({
      customerId: req.user!.id,
      quote,
      winwinId: body.winwinId,
      idempotencyKey: req.header('Idempotency-Key') ?? null,
    });
    res.status(201).json(serializeOrder(order));

    // Fire-and-forget: try to process this withdrawal immediately instead of
    // waiting for the periodic sweep -- CashdeskBot's official partner API
    // when configured, MobCash browser automation as a fallback otherwise.
    // Never blocks or affects the customer's response either way -- the
    // response above already reflects the real, currently-pending state.
    import('../services/automationOrchestrator')
      .then((m) => m.runAutomatedWithdrawal(order.id))
      .catch((err) => console.error('Automated withdrawal trigger failed', order.id, err instanceof Error ? err.message : err));
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
