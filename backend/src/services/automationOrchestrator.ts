import { pool } from '../db/pool';
import { getIntegration } from './paymentIntegrationService';
import { startProcessingWithdraw, completeWithdrawOrder, failOrder } from './orderService';
import { pollMobCashDeposits, submitMobCashWithdrawal, SYSTEM_ACTOR_ID } from './mobcashAutomation';

const MAX_ATTEMPTS_PER_ORDER = 3;

async function automationIsUsable(): Promise<boolean> {
  const integration = await getIntegration('mobcash_winwin');
  if (!integration) return false;
  return integration.status === 'active' && integration.automationMode === 'automatic' && !integration.circuitBreakerTrippedAt;
}

/**
 * Called right after a WinWin withdrawal order is created (fire-and-forget
 * from the route handler) and again by the periodic sweep for anything
 * left behind by a crash. Reuses the exact same state-transition functions
 * the manual agent flow uses (startProcessingWithdraw /
 * completeWithdrawOrder / failOrder), so the wallet-affecting guarantees
 * (row locking, reserve/release, idempotent transitions) are identical --
 * automation is just a different *caller* of the same trusted machinery,
 * never a shortcut around it.
 */
export async function runAutomatedWithdrawal(orderId: string): Promise<void> {
  if (!(await automationIsUsable())) return;

  const { rows } = await pool.query('SELECT * FROM orders WHERE id = $1', [orderId]);
  const order = rows[0];
  if (!order || order.direction !== 'withdraw' || order.method !== 'winwin' || order.status !== 'pending') return;

  if (order.automation_attempts >= MAX_ATTEMPTS_PER_ORDER) {
    await failOrder(orderId, `Automation exhausted ${MAX_ATTEMPTS_PER_ORDER} attempts -- needs manual review`, null, null);
    return;
  }

  // Claims the order (atomic: throws if it's no longer pending, which is
  // exactly the duplicate-submission guard -- two concurrent triggers for
  // the same order can never both reach submitMobCashWithdrawal).
  try {
    await startProcessingWithdraw(orderId, SYSTEM_ACTOR_ID, 'admin');
  } catch {
    return; // already claimed by another run (manual or automated) -- nothing to do
  }

  await pool.query('UPDATE orders SET automation_attempts = automation_attempts + 1 WHERE id = $1', [orderId]);

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

/** Periodic poll for new WinWin deposits, plus a sweep for stuck pending withdrawals. */
export async function runAutomationSweep(): Promise<void> {
  if (!(await automationIsUsable())) return;

  await pollMobCashDeposits().catch((err) => {
    console.error('MobCash deposit poll failed', err instanceof Error ? err.message : err);
  });

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
