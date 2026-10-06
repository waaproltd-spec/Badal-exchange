import { pool } from '../db/pool';
import { completeDepositOrder } from './orderService';
import { methodForSmsProvider, PlatformMethod } from '../lib/methods';

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
 * Mobile-money deposit verification (EVC Plus, Golis, Telesom, eDahab). The
 * agent app extracts only the minimal fields from an authorized payment SMS
 * (never the raw message body), or an agent keys in a payment they saw, and
 * posts them here. `provider` names the mobile-money method. The provider
 * transaction ref is the dedupe key -- the same payment can never credit a
 * wallet twice, whether it arrived by SMS or was entered by hand.
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
  const method = methodForSmsProvider(input.provider);

  const candidate = await pool.query(
    `SELECT id FROM orders
     WHERE direction = 'deposit' AND method = $3 AND status = 'pending'
       AND phone_number = $1 AND amount_cents = $2
     ORDER BY created_at ASC LIMIT 1`,
    [input.sender, input.amountCents, method]
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
  /** Betting platform the top-up happened on. Defaults to WinWin. */
  method?: PlatformMethod;
  /** The customer's account ID on that platform. */
  winwinId: string;
  depositCode?: string;
  amountCents: number;
  mobcashRef: string;
  occurredAt: string;
}

/**
 * Betting-platform deposit confirmation (WinWin/MobCash, 1XBET, MELBET, ...).
 * Submitted by an authorized agent or admin after observing the real,
 * completed top-up in that platform's cashier/manager tools -- never
 * generated automatically and never trusted from the customer app.
 */
export async function submitWinwinTransaction(input: WinwinSubmission): Promise<MatchResult> {
  const method = input.method ?? 'winwin';
  const inserted = await pool.query(
    `INSERT INTO winwin_transactions (submitted_by, winwin_id, deposit_code, amount_cents, mobcash_ref, occurred_at, method)
     VALUES ($1,$2,$3,$4,$5,$6,$7)
     ON CONFLICT (method, mobcash_ref) DO NOTHING
     RETURNING id`,
    [input.submittedBy, input.winwinId, input.depositCode ?? null, input.amountCents, input.mobcashRef, input.occurredAt, method]
  );
  if (inserted.rowCount === 0) {
    return { status: 'duplicate' };
  }
  const txnId = inserted.rows[0].id;

  // A human-typed confirmation usually carries our deposit code (stronger
  // match); an automated feed scrape of "recent transactions" typically
  // does not, since the code is something we display to the customer, not
  // something WinWin/MobCash echoes back in a transaction row. When no
  // code is given, fall back to matching by WinWin ID + amount alone --
  // still safe because it's scoped to this specific customer's pending
  // order, not a blind amount match across all customers.
  const candidate = await pool.query(
    `SELECT id FROM orders
     WHERE direction = 'deposit' AND method = $4 AND status = 'pending'
       AND winwin_id = $1 AND amount_cents = $2
       AND ($3::text IS NULL OR deposit_code = $3)
     ORDER BY created_at ASC LIMIT 1`,
    [input.winwinId, input.amountCents, input.depositCode ?? null, method]
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
