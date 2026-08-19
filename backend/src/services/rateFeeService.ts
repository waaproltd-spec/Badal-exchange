import { PoolClient } from 'pg';
import { pool } from '../db/pool';
import { ApiError } from '../lib/errors';
import { applyFee } from '../lib/money';

export type Method = 'evc_plus' | 'winwin';
export type Direction = 'deposit' | 'withdraw';

export interface ActiveRate {
  id: string;
  rate: number;
}
export interface ActiveFee {
  id: string;
  fee_type: 'flat' | 'percent';
  value: number;
}
export interface Limits {
  min_cents: number;
  max_cents: number;
}

async function getActiveRate(db: PoolClient | typeof pool, method: Method, direction: Direction): Promise<ActiveRate> {
  const { rows } = await db.query(
    `SELECT id, rate FROM exchange_rates WHERE method = $1 AND direction = $2 AND active = true
     ORDER BY created_at DESC LIMIT 1`,
    [method, direction]
  );
  if (!rows[0]) throw ApiError.badRequest(`No active exchange rate configured for ${method}/${direction}`, 'RATE_NOT_CONFIGURED');
  return { id: rows[0].id, rate: Number(rows[0].rate) };
}

async function getActiveFee(db: PoolClient | typeof pool, method: Method, direction: Direction): Promise<ActiveFee> {
  const { rows } = await db.query(
    `SELECT id, fee_type, value FROM fees WHERE method = $1 AND direction = $2 AND active = true
     ORDER BY created_at DESC LIMIT 1`,
    [method, direction]
  );
  if (!rows[0]) return { id: '', fee_type: 'flat', value: 0 };
  return { id: rows[0].id, fee_type: rows[0].fee_type, value: Number(rows[0].value) };
}

export async function getWithdrawalLimits(db: PoolClient | typeof pool, method: Method): Promise<Limits> {
  const { rows } = await db.query('SELECT min_cents, max_cents FROM withdrawal_limits WHERE method = $1', [method]);
  if (!rows[0]) return { min_cents: 100, max_cents: 100000000 };
  return { min_cents: Number(rows[0].min_cents), max_cents: Number(rows[0].max_cents) };
}

export interface Quote {
  method: Method;
  direction: Direction;
  amountCents: number;
  rate: number;
  rateId: string;
  feeId: string | null;
  feeCents: number;
  netCents: number; // deposit: credited to wallet. withdraw: paid out to customer.
  walletDeltaCents: number; // deposit: same as netCents. withdraw: amountCents + feeCents (reserved/debited from wallet).
}

/**
 * Computes the exchange rate + fee snapshot for a deposit or withdrawal.
 * This is the ONLY place amounts are calculated -- the mobile apps never
 * calculate money; they only display what the backend returns here.
 */
export async function computeQuote(
  db: PoolClient | typeof pool,
  method: Method,
  direction: Direction,
  amountCents: number
): Promise<Quote> {
  if (amountCents <= 0) throw ApiError.badRequest('Amount must be greater than zero', 'INVALID_AMOUNT');

  const rate = await getActiveRate(db, method, direction);
  const fee = await getActiveFee(db, method, direction);

  if (direction === 'deposit') {
    const feeCents = applyFee(amountCents, fee.fee_type, fee.value);
    const grossWalletCents = Math.round(amountCents * rate.rate);
    const netCents = Math.max(0, grossWalletCents - feeCents);
    return {
      method,
      direction,
      amountCents,
      rate: rate.rate,
      rateId: rate.id,
      feeId: fee.id || null,
      feeCents,
      netCents,
      walletDeltaCents: netCents,
    };
  } else {
    const limits = await getWithdrawalLimits(db, method);
    if (amountCents < limits.min_cents) {
      throw ApiError.badRequest(`Minimum withdrawal is ${limits.min_cents / 100}`, 'BELOW_MIN_WITHDRAWAL');
    }
    if (amountCents > limits.max_cents) {
      throw ApiError.badRequest(`Maximum withdrawal is ${limits.max_cents / 100}`, 'ABOVE_MAX_WITHDRAWAL');
    }
    const feeCents = applyFee(amountCents, fee.fee_type, fee.value);
    const payoutCents = Math.round(amountCents * rate.rate);
    const walletDeltaCents = amountCents + feeCents; // total deducted from wallet
    return {
      method,
      direction,
      amountCents,
      rate: rate.rate,
      rateId: rate.id,
      feeId: fee.id || null,
      feeCents,
      netCents: payoutCents, // amount customer receives
      walletDeltaCents,
    };
  }
}
