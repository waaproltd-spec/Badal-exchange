import { pool } from './db/pool';
import { runAutomatedWithdrawal, runAutomationSweep } from './services/automationOrchestrator';

/**
 * MobCash automation worker for the Supabase backend.
 *
 * Everything the apps use now runs inside Supabase. The one thing that
 * cannot is driving the MobCash Business Web portal with a headless browser
 * (Playwright), so this process does only that: connect to the Supabase
 * database (DATABASE_URL), and
 *   - every minute, run the same sweep the API server ran (deposit-feed poll
 *     plus any pending WinWin withdrawals), and
 *   - process a new WinWin withdrawal as soon as the database announces it
 *     (customer_create_withdrawal sends NOTIFY mobcash_withdrawal).
 * It does nothing unless a manager switched MobCash to automatic in the
 * Agent App (Account -> Payment Integrations), and dry-run stays on until
 * they turn it off. Run with `npm run worker` (BAARI_PROCESS=worker).
 */
const SWEEP_INTERVAL_MS = 60_000;

function logError(what: string, err: unknown) {
  console.error(what, err instanceof Error ? err.message : err);
}

async function listenForWithdrawals() {
  const client = await pool.connect();
  client.on('notification', (msg) => {
    if (msg.channel === 'mobcash_withdrawal' && msg.payload) {
      runAutomatedWithdrawal(msg.payload).catch((err) => logError(`Automated withdrawal ${msg.payload} failed`, err));
    }
  });
  client.on('error', (err) => {
    logError('Notification connection lost; reconnecting', err);
    client.release(true);
    setTimeout(() => listenForWithdrawals().catch((e) => logError('Reconnect failed', e)), 5_000);
  });
  await client.query('LISTEN mobcash_withdrawal');
}

async function main() {
  await listenForWithdrawals();
  const sweep = () => runAutomationSweep().catch((err) => logError('MobCash automation sweep failed', err));
  await sweep();
  setInterval(sweep, SWEEP_INTERVAL_MS);
  console.log('BAARI MobCash automation worker running');
}

main().catch((err) => {
  logError('Worker failed to start', err);
  process.exit(1);
});
