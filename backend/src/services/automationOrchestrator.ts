import { pool } from '../db/pool';
import { getIntegration } from './paymentIntegrationService';
import { startProcessingWithdraw, completeWithdrawOrder, failOrder, createDepositOrder, completeDepositOrder } from './orderService';
import { submitMobCashWithdrawal, SYSTEM_ACTOR_ID } from './mobcashAutomation';
import { cashdeskBotDeposit, cashdeskBotPayout, isCashdeskBotConfigured } from './cashdeskBotService';
import { computeQuote } from './rateFeeService';
import { fromCents, toCents } from '../lib/money';
import { ApiError } from '../lib/errors';

const MAX_ATTEMPTS_PER_ORDER = 3;

/**
 * Serializes redemption attempts for the same (winwinId, code) pair on this
 * backend, so two near-simultaneous requests (double-tap, retry) can't both
 * race past the "already redeemed?" check before either has written a row.
 * Held for the life of the whole external-call-plus-DB-write below; released
 * automatically when the dedicated connection closes.
 */
async function withCodeLock<T>(winwinId: string, code: string, fn: () => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('SELECT pg_advisory_lock(hashtext($1)::bigint)', [`cashdeskbot_payout:${winwinId}:${code}`]);
    return await fn();
  } finally {
    await client.query('SELECT pg_advisory_unlock(hashtext($1)::bigint)', [`cashdeskbot_payout:${winwinId}:${code}`]).catch(() => {});
    client.release();
  }
}

async function mobCashAutomationIsUsable(): Promise<boolean> {
  const integration = await getIntegration('mobcash_winwin');
  if (!integration) return false;
  return integration.status === 'active' && integration.automationMode === 'automatic' && !integration.circuitBreakerTrippedAt;
}

/**
 * Claims a pending WinWin withdrawal order for automated processing, so two
 * concurrent triggers (or a manual agent and automation) for the same order
 * can never both proceed. Returns null if the order isn't eligible right now.
 */
async function claimPendingWinwinWithdrawal(orderId: string) {
  const { rows } = await pool.query('SELECT * FROM orders WHERE id = $1', [orderId]);
  const order = rows[0];
  if (!order || order.direction !== 'withdraw' || order.method !== 'winwin' || order.status !== 'pending') return null;

  if (order.automation_attempts >= MAX_ATTEMPTS_PER_ORDER) {
    await failOrder(orderId, `Automation exhausted ${MAX_ATTEMPTS_PER_ORDER} attempts -- needs manual review`, null, null);
    return null;
  }

  try {
    await startProcessingWithdraw(orderId, SYSTEM_ACTOR_ID, 'admin');
  } catch {
    return null; // already claimed by another run (manual or automated) -- nothing to do
  }

  await pool.query('UPDATE orders SET automation_attempts = automation_attempts + 1 WHERE id = $1', [orderId]);
  return order;
}

/**
 * Preferred automated path: fund the customer's 888STARZ/WinWin account via
 * CashdeskBot's official partner API (POST /Deposit/{userId}/Add) and only
 * finalize the wallet debit once CashdeskBot has accepted the request. The
 * wallet was already reserved (not deducted) when the order was created, so
 * a CashdeskBot failure here just releases that reservation -- the customer
 * is never charged for a deposit that didn't land.
 *
 * The customer-facing failure reason deliberately never names CashdeskBot --
 * the mobile apps only ever see "Deposit"/"Withdraw"; that vendor detail
 * belongs to admin-only tooling (audit log, server logs), never the order
 * row a customer can read.
 */
async function runCashdeskBotWithdrawal(orderId: string): Promise<void> {
  const order = await claimPendingWinwinWithdrawal(orderId);
  if (!order) return;

  try {
    const response = await cashdeskBotDeposit(order.winwin_id, {
      lng: 'en',
      summa: Number(fromCents(order.wallet_delta_cents)),
    });
    // Response schema is undocumented (see cashdeskBotService.ts) -- opportunistically
    // capture whatever reference/message id it hands back for the audit trail;
    // fall back to a synthetic reference if it returns none.
    const reference = response?.messageId ?? response?.id ?? response?.transactionId ?? `888starz-deposit:${orderId}`;
    await completeWithdrawOrder(orderId, String(reference), SYSTEM_ACTOR_ID, 'admin');
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('CashdeskBot withdrawal failed', orderId, message);
    await failOrder(orderId, 'Could not complete your 888STARZ deposit. Please try again or contact support.', SYSTEM_ACTOR_ID, 'admin');
  }
}

/** Legacy fallback: fragile MobCash Business Web browser automation, used only while CashdeskBot isn't configured. */
async function runMobCashWithdrawal(orderId: string): Promise<void> {
  if (!(await mobCashAutomationIsUsable())) return;

  const order = await claimPendingWinwinWithdrawal(orderId);
  if (!order) return;

  try {
    const result = await submitMobCashWithdrawal({
      orderId,
      winwinId: order.winwin_id,
      netCents: Number(order.wallet_delta_cents),
    });

    if (result.status === 'dry_run') {
      // Dry run must never finalize a real payout. Revert to pending so a
      // human (or a later live run) can act on it; the dry-run result is
      // fully visible in automation_runs for admin review.
      await pool.query(`UPDATE orders SET status = 'pending', updated_at = now() WHERE id = $1`, [orderId]);
      return;
    }

    await completeWithdrawOrder(orderId, result.reference, SYSTEM_ACTOR_ID, 'admin');
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await failOrder(orderId, `Automated MobCash submission failed: ${message}`, SYSTEM_ACTOR_ID, 'admin');
  }
}

export interface RedeemCashdeskBotPayoutInput {
  customerId: string;
  winwinId: string;
  code: string;
}

async function logPayoutAttempt(input: {
  customerId: string;
  winwinId: string;
  code: string;
  success: boolean;
  amountCents: number | null;
  messageId: string | null;
  message: string | null;
  orderId: string | null;
}): Promise<void> {
  await pool.query(
    `INSERT INTO cashdeskbot_payouts (customer_id, winwin_id, code, success, amount_cents, cashdeskbot_message_id, message, order_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
    [input.customerId, input.winwinId, input.code, input.success, input.amountCents, input.messageId, input.message, input.orderId]
  );
}

/**
 * Badal Deposit -> 888STARZ -> CashdeskBot Payout -> Badal Wallet.
 *
 * The customer redeems a one-time withdrawal code 888STARZ generated on its
 * side. CashdeskBot's POST /Deposit/{userId}/Payout is the only source of
 * truth for both whether the code is good *and* how much it's worth -- the
 * wallet is credited with exactly what CashdeskBot confirms, never a
 * customer-typed amount. A failed or already-used code never creates an
 * order and never touches the wallet.
 */
export async function redeemCashdeskBotPayout(input: RedeemCashdeskBotPayoutInput) {
  if (!isCashdeskBotConfigured()) {
    throw ApiError.badRequest('888STARZ deposit is not available right now. Please try again later.', 'CASHDESKBOT_NOT_CONFIGURED');
  }

  const winwinId = input.winwinId.trim();
  const code = input.code.trim();

  return withCodeLock(winwinId, code, async () => {
    const dup = await pool.query(
      `SELECT 1 FROM cashdeskbot_payouts WHERE winwin_id = $1 AND code = $2 AND success = true LIMIT 1`,
      [winwinId, code]
    );
    if (dup.rows[0]) {
      throw ApiError.conflict('This 888STARZ code has already been used.', 'DUPLICATE_CODE');
    }

    let result: Awaited<ReturnType<typeof cashdeskBotPayout>>;
    try {
      result = await cashdeskBotPayout(winwinId, { lng: 'en', code });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error('CashdeskBot payout call failed', winwinId, message);
      throw ApiError.badRequest('Could not confirm your 888STARZ code. Please try again or contact support.', 'CASHDESKBOT_PAYOUT_ERROR');
    }

    if (!result.success) {
      await logPayoutAttempt({
        customerId: input.customerId,
        winwinId,
        code,
        success: false,
        amountCents: null,
        messageId: result.messageId,
        message: result.message,
        orderId: null,
      });
      throw ApiError.badRequest('That 888STARZ code could not be confirmed. Please check the code and try again.', 'CASHDESKBOT_PAYOUT_FAILED');
    }

    const amountCents = result.summa != null ? toCents(result.summa) : 0;
    if (amountCents <= 0) {
      await logPayoutAttempt({
        customerId: input.customerId,
        winwinId,
        code,
        success: false,
        amountCents: null,
        messageId: result.messageId,
        message: result.message ?? 'CashdeskBot returned no confirmed amount',
        orderId: null,
      });
      throw ApiError.badRequest('That 888STARZ code could not be confirmed. Please try again or contact support.', 'CASHDESKBOT_INVALID_AMOUNT');
    }

    const quote = await computeQuote(pool, 'winwin', 'deposit', amountCents);
    const order = await createDepositOrder({ customerId: input.customerId, quote, winwinId, skipDepositCode: true });
    const reference = result.messageId ?? `888starz-payout:${order.id}`;
    const completed = await completeDepositOrder(order.id, String(reference), SYSTEM_ACTOR_ID, 'admin');

    await logPayoutAttempt({
      customerId: input.customerId,
      winwinId,
      code,
      success: true,
      amountCents,
      messageId: result.messageId,
      message: result.message,
      orderId: order.id,
    });

    return completed;
  });
}

/**
 * Called right after a WinWin withdrawal order is created (fire-and-forget
 * from the route handler) and again by the periodic sweep for anything left
 * behind by a crash. Reuses the exact same state-transition functions the
 * manual agent flow uses (startProcessingWithdraw / completeWithdrawOrder /
 * failOrder), so the wallet-affecting guarantees (row locking, reserve/
 * release, idempotent transitions) are identical -- automation is just a
 * different *caller* of the same trusted machinery, never a shortcut around
 * it.
 *
 * WinWin/MobCash browser automation (runMobCashWithdrawal, below) is
 * deliberately never called from here -- it has no official API or
 * credentials, and per product decision it stays OFF until it does. The
 * function itself is left in place (not deleted) so it's a one-line change
 * to bring back once that changes; until then the only automated path is
 * CashdeskBot's official partner API, and any order it can't process (not
 * configured, or method isn't 'winwin') just stays pending for manual/admin
 * review -- it is never picked up by MobCash automation as a fallback.
 */
export async function runAutomatedWithdrawal(orderId: string): Promise<void> {
  if (!isCashdeskBotConfigured()) return;
  await runCashdeskBotWithdrawal(orderId);
}

/** Sweep for stuck pending withdrawals that CashdeskBot can retry. MobCash's deposit poll is not run -- see runAutomatedWithdrawal. */
export async function runAutomationSweep(): Promise<void> {
  if (!isCashdeskBotConfigured()) return;

  const { rows } = await pool.query(
    `SELECT id FROM orders WHERE direction = 'withdraw' AND method = 'winwin' AND status = 'pending'
     AND automation_attempts < $1 ORDER BY created_at ASC LIMIT 10`,
    [MAX_ATTEMPTS_PER_ORDER]
  );
  for (const row of rows) {
    await runAutomatedWithdrawal(row.id).catch((err) => {
      console.error('Automated withdrawal run failed', row.id, err instanceof Error ? err.message : err);
    });
  }
}
