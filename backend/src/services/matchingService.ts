import { pool } from '../db/pool';
import { completeDepositOrder } from './orderService';

export interface SmsSubmission {
  agentId: string;
  deviceId?: string;
  provider: string;
  sender?: string;
  receiver?: string;
  amountCents: number;
  transactionRef: string;
  occurredAt: string;
}

export type MatchResult =
  | { status: 'duplicate' }
  | { status: 'matched'; orderId: string }
  | { status: 'unmatched' };

/**
 * EVC Plus deposit verification. The agent app extracts only the minimal
 * fields from an authorized payment SMS (never the raw message body) and
 * posts them here. The provider transaction ref is the dedupe key -- the
 * same SMS/payment can never credit a wallet twice.
 */
export async function submitSmsTransaction(input: SmsSubmission): Promise<MatchResult> {
  const inserted = await pool.query(
    `INSERT INTO sms_transactions (agent_id, device_id, provider, sender, receiver, amount_cents, transaction_ref, occurred_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
     ON CONFLICT (provider, transaction_ref) DO NOTHING
     RETURNING id`,
    [input.agentId, input.deviceId ?? null, input.provider, input.sender ?? null, input.receiver ?? null, input.amountCents, input.transactionRef, input.occurredAt]
  );
  if (inserted.rowCount === 0) {
    return { status: 'duplicate' };
  }
  const smsId = inserted.rows[0].id;

  const candidate = await pool.query(
    `SELECT id FROM orders
     WHERE direction = 'deposit' AND method = 'evc_plus' AND status = 'pending'
       AND phone_number = $1 AND amount_cents = $2
     ORDER BY created_at ASC LIMIT 1`,
    [input.sender, input.amountCents]
  );

  if (!candidate.rows[0]) {
    await pool.query(`UPDATE sms_transactions SET match_status = 'unmatched' WHERE id = $1`, [smsId]);
    return { status: 'unmatched' };
  }

  const orderId = candidate.rows[0].id;
  await completeDepositOrder(orderId, input.transactionRef, input.agentId, 'agent');
  await pool.query(
    `UPDATE sms_transactions SET match_status = 'matched', matched_order_id = $1 WHERE id = $2`,
    [orderId, smsId]
  );
  return { status: 'matched', orderId };
}

export interface WinwinSubmission {
  submittedBy: string;
  winwinId: string;
  depositCode?: string;
  amountCents: number;
  mobcashRef: string;
  occurredAt: string;
}

/**
 * WinWin/MobCash deposit confirmation. Submitted by an authorized agent or
 * admin after observing the real, completed transaction in the WinWin
 * manager app -- never generated automatically and never trusted from the
 * customer app.
 */
export async function submitWinwinTransaction(input: WinwinSubmission): Promise<MatchResult> {
  const inserted = await pool.query(
    `INSERT INTO winwin_transactions (submitted_by, winwin_id, deposit_code, amount_cents, mobcash_ref, occurred_at)
     VALUES ($1,$2,$3,$4,$5,$6)
     ON CONFLICT (mobcash_ref) DO NOTHING
     RETURNING id`,
    [input.submittedBy, input.winwinId, input.depositCode ?? null, input.amountCents, input.mobcashRef, input.occurredAt]
  );
  if (inserted.rowCount === 0) {
    return { status: 'duplicate' };
  }
  const txnId = inserted.rows[0].id;

  const candidate = await pool.query(
    `SELECT id FROM orders
     WHERE direction = 'deposit' AND method = 'winwin' AND status = 'pending'
       AND winwin_id = $1 AND deposit_code = $2 AND amount_cents = $3
     ORDER BY created_at ASC LIMIT 1`,
    [input.winwinId, input.depositCode ?? null, input.amountCents]
  );

  if (!candidate.rows[0]) {
    await pool.query(`UPDATE winwin_transactions SET match_status = 'unmatched' WHERE id = $1`, [txnId]);
    return { status: 'unmatched' };
  }

  const orderId = candidate.rows[0].id;
  await completeDepositOrder(orderId, input.mobcashRef, input.submittedBy, 'agent');
  await pool.query(
    `UPDATE winwin_transactions SET match_status = 'matched', matched_order_id = $1 WHERE id = $2`,
    [orderId, txnId]
  );
  return { status: 'matched', orderId };
}
