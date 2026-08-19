import { PoolClient } from 'pg';
import { ApiError } from '../lib/errors';

export interface WalletRow {
  id: string;
  customer_id: string;
  available_cents: string;
  pending_cents: string;
  total_deposit_cents: string;
  total_withdraw_cents: string;
}

/**
 * Locks the customer's wallet row (SELECT ... FOR UPDATE) for the duration
 * of the caller's transaction, so two concurrent requests against the same
 * wallet serialize instead of racing. Must be called inside withTransaction().
 * Creates the wallet lazily if it does not exist yet.
 */
export async function lockWallet(client: PoolClient, customerId: string): Promise<WalletRow> {
  const existing = await client.query<WalletRow>(
    'SELECT * FROM wallets WHERE customer_id = $1 FOR UPDATE',
    [customerId]
  );
  if (existing.rows[0]) return existing.rows[0];

  const created = await client.query<WalletRow>(
    `INSERT INTO wallets (customer_id) VALUES ($1)
     ON CONFLICT (customer_id) DO UPDATE SET customer_id = EXCLUDED.customer_id
     RETURNING *`,
    [customerId]
  );
  // Re-lock in case of a concurrent-insert race.
  const locked = await client.query<WalletRow>(
    'SELECT * FROM wallets WHERE customer_id = $1 FOR UPDATE',
    [customerId]
  );
  return locked.rows[0] ?? created.rows[0];
}

async function insertLedgerEntry(
  client: PoolClient,
  walletId: string,
  orderId: string | null,
  entryType: 'credit' | 'debit' | 'reserve' | 'release',
  amountCents: number,
  balanceAfterCents: number,
  reason: string
) {
  await client.query(
    `INSERT INTO ledger_entries (wallet_id, order_id, entry_type, amount_cents, balance_after_cents, reason)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [walletId, orderId, entryType, amountCents, balanceAfterCents, reason]
  );
}

/** Deposit completion: credit wallet with the verified net amount. */
export async function creditWallet(
  client: PoolClient,
  wallet: WalletRow,
  amountCents: number,
  orderId: string,
  reason: string
): Promise<WalletRow> {
  const result = await client.query<WalletRow>(
    `UPDATE wallets
     SET available_cents = available_cents + $1,
         total_deposit_cents = total_deposit_cents + $1,
         updated_at = now()
     WHERE id = $2
     RETURNING *`,
    [amountCents, wallet.id]
  );
  const updated = result.rows[0];
  await insertLedgerEntry(client, wallet.id, orderId, 'credit', amountCents, Number(updated.available_cents), reason);
  return updated;
}

/** Withdrawal request accepted: move funds out of `available` into `pending` (locked, not yet gone). */
export async function reserveFunds(
  client: PoolClient,
  wallet: WalletRow,
  amountCents: number,
  orderId: string,
  reason: string
): Promise<WalletRow> {
  if (Number(wallet.available_cents) < amountCents) {
    throw ApiError.badRequest('Insufficient wallet balance', 'INSUFFICIENT_BALANCE');
  }
  const result = await client.query<WalletRow>(
    `UPDATE wallets
     SET available_cents = available_cents - $1,
         pending_cents = pending_cents + $1,
         updated_at = now()
     WHERE id = $2
     RETURNING *`,
    [amountCents, wallet.id]
  );
  const updated = result.rows[0];
  await insertLedgerEntry(client, wallet.id, orderId, 'reserve', amountCents, Number(updated.available_cents), reason);
  return updated;
}

/** Withdrawal payout confirmed by the provider: finalize the deduction permanently. */
export async function finalizeDebit(
  client: PoolClient,
  wallet: WalletRow,
  amountCents: number,
  orderId: string,
  reason: string
): Promise<WalletRow> {
  const result = await client.query<WalletRow>(
    `UPDATE wallets
     SET pending_cents = pending_cents - $1,
         total_withdraw_cents = total_withdraw_cents + $1,
         updated_at = now()
     WHERE id = $2
     RETURNING *`,
    [amountCents, wallet.id]
  );
  const updated = result.rows[0];
  await insertLedgerEntry(client, wallet.id, orderId, 'debit', amountCents, Number(updated.available_cents), reason);
  return updated;
}

/** Withdrawal payout failed: release the reservation, restoring the customer's available balance. */
export async function releaseFunds(
  client: PoolClient,
  wallet: WalletRow,
  amountCents: number,
  orderId: string,
  reason: string
): Promise<WalletRow> {
  const result = await client.query<WalletRow>(
    `UPDATE wallets
     SET pending_cents = pending_cents - $1,
         available_cents = available_cents + $1,
         updated_at = now()
     WHERE id = $2
     RETURNING *`,
    [amountCents, wallet.id]
  );
  const updated = result.rows[0];
  await insertLedgerEntry(client, wallet.id, orderId, 'release', amountCents, Number(updated.available_cents), reason);
  return updated;
}
