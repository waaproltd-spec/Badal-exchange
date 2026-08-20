import { pool } from '../db/pool';
import { getIntegration } from './paymentIntegrationService';
import { startProcessingWithdraw, completeWithdrawOrder, failOrder } from './orderService';
import { pollMobCashDeposits, submitMobCashWithdrawal, SYSTEM_ACTOR_ID } from './mobcashAutomation';
import { cashdeskBotDeposit, isCashdeskBotConfigured } from './cashdeskBotService';
import { fromCents } from '../lib/money';

const MAX_ATTEMPTS_PER_ORDER = 3;

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
    await cashdeskBotDeposit(order.winwin_id, {
      lng: 'en',
      summa: Number(fromCents(order.wallet_delta_cents)),
    });
    await completeWithdrawOrder(orderId, `888starz-deposit:${orderId}`, SYSTEM_ACTOR_ID, 'admin');
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

/**
 * Called right after a WinWin withdrawal order is created (fire-and-forget
 * from the route handler) and again by the periodic sweep for anything left
 * behind by a crash. Reuses the exact same state-transition functions the
 * manual agent flow uses (startProcessingWithdraw / completeWithdrawOrder /
 * failOrder), so the wallet-affecting guarantees (row locking, reserve/
 * release, idempotent transitions) are identical -- automation is just a
 * different *caller* of the same trusted machinery, never a shortcut around
 * it. CashdeskBot (the official partner API) is preferred whenever it's
 * configured; MobCash browser automation remains only as a fallback.
 */
export async function runAutomatedWithdrawal(orderId: string): Promise<void> {
  if (isCashdeskBotConfigured()) {
    await runCashdeskBotWithdrawal(orderId);
    return;
  }
  await runMobCashWithdrawal(orderId);
}

/** Periodic poll for new WinWin deposits, plus a sweep for stuck pending withdrawals. */
export async function runAutomationSweep(): Promise<void> {
  const mobCashUsable = await mobCashAutomationIsUsable();
  const cashdeskUsable = isCashdeskBotConfigured();
  if (!mobCashUsable && !cashdeskUsable) return;

  if (mobCashUsable) {
    await pollMobCashDeposits().catch((err) => {
      console.error('MobCash deposit poll failed', err instanceof Error ? err.message : err);
    });
  }

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
