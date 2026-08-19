import { PoolClient } from 'pg';
import { pool, withTransaction } from '../db/pool';
import { ApiError } from '../lib/errors';
import { generateDepositCode, generateOrderCode } from '../lib/crypto';
import { Quote } from './rateFeeService';
import { lockWallet, reserveFunds, releaseFunds, finalizeDebit, creditWallet } from './walletService';
import { writeAudit } from '../lib/audit';
import { Role } from '../auth/jwt';

export interface CreateDepositInput {
  customerId: string;
  quote: Quote;
  phoneNumber?: string;
  winwinId?: string;
  idempotencyKey?: string | null;
}

export interface CreateWithdrawInput {
  customerId: string;
  quote: Quote;
  phoneNumber?: string;
  winwinId?: string;
  idempotencyKey?: string | null;
}

async function uniqueOrderCode(client: PoolClient): Promise<string> {
  for (let i = 0; i < 5; i++) {
    const code = generateOrderCode();
    const { rows } = await client.query('SELECT 1 FROM orders WHERE order_code = $1', [code]);
    if (rows.length === 0) return code;
  }
  throw new Error('Could not generate a unique order code');
}

async function uniqueDepositCode(client: PoolClient): Promise<string> {
  for (let i = 0; i < 8; i++) {
    const code = generateDepositCode();
    const { rows } = await client.query('SELECT 1 FROM orders WHERE deposit_code = $1', [code]);
    if (rows.length === 0) return code;
  }
  throw new Error('Could not generate a unique deposit code');
}

/** Deposit orders never touch the wallet at creation time -- only after verification. */
export async function createDepositOrder(input: CreateDepositInput) {
  return withTransaction(async (client) => {
    const orderCode = await uniqueOrderCode(client);
    const depositCode = input.quote.method === 'winwin' ? await uniqueDepositCode(client) : null;

    const { rows } = await client.query(
      `INSERT INTO orders (
         order_code, customer_id, direction, method, status,
         phone_number, winwin_id, deposit_code,
         amount_cents, rate, fee_cents, net_cents, wallet_delta_cents,
         exchange_rate_id, fee_id, idempotency_key
       ) VALUES (
         $1, $2, 'deposit', $3, 'pending',
         $4, $5, $6,
         $7, $8, $9, $10, $11,
         $12, $13, $14
       ) RETURNING *`,
      [
        orderCode,
        input.customerId,
        input.quote.method,
        input.phoneNumber ?? null,
        input.winwinId ?? null,
        depositCode,
        input.quote.amountCents,
        input.quote.rate,
        input.quote.feeCents,
        input.quote.netCents,
        input.quote.walletDeltaCents,
        input.quote.rateId,
        input.quote.feeId,
        input.idempotencyKey ?? null,
      ]
    );
    const order = rows[0];
    await writeAudit(
      { actorId: input.customerId, actorRole: 'customer', action: 'order.create_deposit', entityType: 'order', entityId: order.id, after: order },
      client
    );
    return order;
  });
}

/** Withdrawal orders reserve funds immediately (lock them out of `available`) so the same balance can't be double-spent. */
export async function createWithdrawOrder(input: CreateWithdrawInput) {
  return withTransaction(async (client) => {
    // Duplicate-request protection: identical pending/processing withdrawal already in flight.
    const dupCheck = await client.query(
      `SELECT id FROM orders
       WHERE customer_id = $1 AND direction = 'withdraw' AND method = $2
         AND status IN ('pending','processing') AND amount_cents = $3
         AND COALESCE(phone_number, winwin_id, '') = COALESCE($4, $5, '')
       LIMIT 1`,
      [input.customerId, input.quote.method, input.quote.amountCents, input.phoneNumber ?? null, input.winwinId ?? null]
    );
    if (dupCheck.rows[0]) {
      throw ApiError.conflict('An identical withdrawal request is already in progress', 'DUPLICATE_WITHDRAWAL');
    }

    const wallet = await lockWallet(client, input.customerId);
    const orderCode = await uniqueOrderCode(client);

    const { rows } = await client.query(
      `INSERT INTO orders (
         order_code, customer_id, direction, method, status,
         phone_number, winwin_id,
         amount_cents, rate, fee_cents, net_cents, wallet_delta_cents,
         exchange_rate_id, fee_id, idempotency_key
       ) VALUES (
         $1, $2, 'withdraw', $3, 'pending',
         $4, $5,
         $6, $7, $8, $9, $10,
         $11, $12, $13
       ) RETURNING *`,
      [
        orderCode,
        input.customerId,
        input.quote.method,
        input.phoneNumber ?? null,
        input.winwinId ?? null,
        input.quote.amountCents,
        input.quote.rate,
        input.quote.feeCents,
        input.quote.netCents,
        input.quote.walletDeltaCents,
        input.quote.rateId,
        input.quote.feeId,
        input.idempotencyKey ?? null,
      ]
    );
    const order = rows[0];

    await reserveFunds(client, wallet, input.quote.walletDeltaCents, order.id, `Reserve for withdrawal ${order.order_code}`);

    await writeAudit(
      { actorId: input.customerId, actorRole: 'customer', action: 'order.create_withdraw', entityType: 'order', entityId: order.id, after: order },
      client
    );
    return order;
  });
}

async function lockOrder(client: PoolClient, orderId: string) {
  const { rows } = await client.query('SELECT * FROM orders WHERE id = $1 FOR UPDATE', [orderId]);
  if (!rows[0]) throw ApiError.notFound('Order not found');
  return rows[0];
}

/** Deposit verified (SMS-matched or WinWin/MobCash-confirmed): credit the wallet and complete the order. */
export async function completeDepositOrder(
  orderId: string,
  transactionRef: string,
  agentId: string,
  actorRole: Role
) {
  return withTransaction(async (client) => {
    const order = await lockOrder(client, orderId);
    if (order.direction !== 'deposit') throw ApiError.badRequest('Not a deposit order');
    if (order.status !== 'pending') {
      throw ApiError.conflict(`Order is already ${order.status}`, 'INVALID_ORDER_STATE');
    }
    await client.query(
      `UPDATE orders SET status = 'processing', agent_id = $1, transaction_ref = $2, processing_at = now(), updated_at = now() WHERE id = $3`,
      [agentId, transactionRef, orderId]
    );

    const wallet = await lockWallet(client, order.customer_id);
    await creditWallet(client, wallet, Number(order.net_cents), orderId, `Deposit ${order.order_code} verified (${transactionRef})`);

    const { rows } = await client.query(
      `UPDATE orders SET status = 'completed', completed_at = now(), updated_at = now() WHERE id = $1 RETURNING *`,
      [orderId]
    );
    const updated = rows[0];
    await writeAudit(
      { actorId: agentId, actorRole, action: 'order.complete_deposit', entityType: 'order', entityId: orderId, before: order, after: updated },
      client
    );
    return updated;
  });
}

export async function failOrder(orderId: string, reason: string, actorId: string | null, actorRole: Role | null) {
  return withTransaction(async (client) => {
    const order = await lockOrder(client, orderId);
    if (order.status === 'completed' || order.status === 'failed') {
      throw ApiError.conflict(`Order is already ${order.status}`, 'INVALID_ORDER_STATE');
    }

    if (order.direction === 'withdraw' && (order.status === 'pending' || order.status === 'processing')) {
      const wallet = await lockWallet(client, order.customer_id);
      await releaseFunds(client, wallet, Number(order.wallet_delta_cents), orderId, `Withdrawal ${order.order_code} failed: ${reason}`);
    }

    const { rows } = await client.query(
      `UPDATE orders SET status = 'failed', failure_reason = $1, updated_at = now() WHERE id = $2 RETURNING *`,
      [reason, orderId]
    );
    const updated = rows[0];
    await writeAudit(
      { actorId, actorRole, action: 'order.fail', entityType: 'order', entityId: orderId, before: order, after: updated },
      client
    );
    return updated;
  });
}

export async function startProcessingWithdraw(orderId: string, agentId: string, actorRole: Role) {
  return withTransaction(async (client) => {
    const order = await lockOrder(client, orderId);
    if (order.direction !== 'withdraw') throw ApiError.badRequest('Not a withdrawal order');
    if (order.status !== 'pending') throw ApiError.conflict(`Order is already ${order.status}`, 'INVALID_ORDER_STATE');

    const { rows } = await client.query(
      `UPDATE orders SET status = 'processing', agent_id = $1, processing_at = now(), updated_at = now() WHERE id = $2 RETURNING *`,
      [agentId, orderId]
    );
    const updated = rows[0];
    await writeAudit(
      { actorId: agentId, actorRole, action: 'order.start_processing_withdraw', entityType: 'order', entityId: orderId, before: order, after: updated },
      client
    );
    return updated;
  });
}

/** Payout confirmed by the provider (EVC agent SMS/USSD receipt, or MobCash manager result): finalize the wallet deduction. */
export async function completeWithdrawOrder(orderId: string, transactionRef: string, agentId: string, actorRole: Role) {
  return withTransaction(async (client) => {
    const order = await lockOrder(client, orderId);
    if (order.direction !== 'withdraw') throw ApiError.badRequest('Not a withdrawal order');
    if (order.status !== 'processing' && order.status !== 'pending') {
      throw ApiError.conflict(`Order is already ${order.status}`, 'INVALID_ORDER_STATE');
    }

    const wallet = await lockWallet(client, order.customer_id);
    await finalizeDebit(client, wallet, Number(order.wallet_delta_cents), orderId, `Withdrawal ${order.order_code} paid out (${transactionRef})`);

    const { rows } = await client.query(
      `UPDATE orders SET status = 'completed', agent_id = $1, transaction_ref = $2, completed_at = now(), updated_at = now() WHERE id = $3 RETURNING *`,
      [agentId, transactionRef, orderId]
    );
    const updated = rows[0];
    await writeAudit(
      { actorId: agentId, actorRole, action: 'order.complete_withdraw', entityType: 'order', entityId: orderId, before: order, after: updated },
      client
    );
    return updated;
  });
}

export async function getOrderById(orderId: string) {
  const { rows } = await pool.query('SELECT * FROM orders WHERE id = $1', [orderId]);
  if (!rows[0]) throw ApiError.notFound('Order not found');
  return rows[0];
}
