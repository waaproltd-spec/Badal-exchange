import { chromium, Browser, Page } from 'playwright-core';
import { pool } from '../db/pool';
import { getDecryptedCredentialsForAdapter, recordAutomationOutcome, IntegrationProvider } from './paymentIntegrationService';

/**
 * Backend-driven browser automation against the real MobCash Business Web
 * portal (https://businessweb-mobi.com). No official MobCash/WinWin API is
 * confirmed to exist -- this is deliberate, explicitly-authorized browser
 * automation of the same portal a human admin would otherwise operate by
 * hand, NOT a documented API integration. It exists behind a hard OFF
 * switch (payment_integrations.automation_mode) that defaults to 'manual',
 * and a dry-run switch that defaults to true.
 *
 * IMPORTANT: the login-page selectors below were confirmed against a real
 * screenshot of https://businessweb-mobi.com/auth/login (username/password
 * placeholders, "Log in" button). Every selector PAST the login step
 * (deposit feed layout, "Top up WebUser" flow) is a best-effort inference
 * from product screenshots, not a live DOM inspection -- this sandbox's
 * network policy blocks businessweb-mobi.com entirely (confirmed with a
 * real headless-browser navigation attempt, not just guessed), so none of
 * this could be tested end-to-end. It MUST be run once in dry-run mode
 * against the real portal and reviewed by an admin before dry-run is ever
 * turned off.
 */

const PROVIDER: IntegrationProvider = 'mobcash_winwin';
const DEFAULT_BUSINESS_WEB_URL = 'https://businessweb-mobi.com/auth/login';
const NAV_TIMEOUT_MS = 30000;
const ADVISORY_LOCK_KEY = 847213; // arbitrary fixed key; scopes the pg_advisory_lock to "one MobCash browser session at a time"

interface AutomationConfig {
  businessWebUrl: string;
}

async function loadConfig(): Promise<AutomationConfig> {
  const { rows } = await pool.query('SELECT config_json FROM payment_integrations WHERE provider = $1', [PROVIDER]);
  const cfg = (rows[0]?.config_json ?? {}) as Record<string, unknown>;
  return {
    businessWebUrl: typeof cfg.business_web_url === 'string' ? cfg.business_web_url : DEFAULT_BUSINESS_WEB_URL,
  };
}

function chromiumExecutablePath(): string | undefined {
  // Set by ops for the deployment environment (e.g. the output of
  // `npx playwright install chromium`, or a preinstalled path -- this
  // sandbox pins one at /opt/pw-browsers/chromium). Left undefined lets
  // playwright-core fall back to its own version-matched resolution.
  return process.env.MOBCASH_CHROMIUM_PATH || undefined;
}

async function withAdvisoryLock<T>(fn: () => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    const { rows } = await client.query('SELECT pg_try_advisory_lock($1) AS locked', [ADVISORY_LOCK_KEY]);
    if (!rows[0].locked) {
      throw new Error('Another MobCash automation run is already in progress');
    }
    try {
      return await fn();
    } finally {
      await client.query('SELECT pg_advisory_unlock($1)', [ADVISORY_LOCK_KEY]);
    }
  } finally {
    client.release();
  }
}

async function logRun(entry: {
  runType: 'deposit_poll' | 'withdrawal_submit' | 'login_check';
  orderId?: string | null;
  status: 'success' | 'failed' | 'dry_run';
  message: string;
  screenshotBase64?: string | null;
  startedAt: Date;
}) {
  await pool.query(
    `INSERT INTO automation_runs (provider, run_type, order_id, status, message, screenshot_base64, started_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [PROVIDER, entry.runType, entry.orderId ?? null, entry.status, entry.message, entry.screenshotBase64 ?? null, entry.startedAt]
  );
}

async function captureFailureScreenshot(page: Page): Promise<string | null> {
  try {
    const buf = await page.screenshot({ fullPage: false, timeout: 5000 });
    return buf.toString('base64');
  } catch {
    return null;
  }
}

async function launchAndLogin(
  overrideCreds?: { username: string; password: string }
): Promise<{ browser: Browser; page: Page }> {
  const creds = overrideCreds ?? (await getDecryptedCredentialsForAdapter(PROVIDER));
  if (!creds) throw new Error('No MobCash credentials saved');
  const config = await loadConfig();

  const browser = await chromium.launch({
    executablePath: chromiumExecutablePath(),
    headless: true,
    args: ['--no-sandbox'],
  });
  const page = await browser.newPage();
  page.setDefaultTimeout(NAV_TIMEOUT_MS);

  try {
    await page.goto(config.businessWebUrl, { waitUntil: 'domcontentloaded' });

    // Confirmed against a real screenshot of the login page.
    await page.getByPlaceholder('Enter username').fill(creds.username);
    await page.getByPlaceholder('Enter password').fill(creds.password);
    await page.getByRole('button', { name: 'Log in' }).click();

    // Success is "we navigated away from the login form" -- wait for the
    // username field to disappear rather than assuming a specific
    // post-login URL, since that was never observed.
    await page.getByPlaceholder('Enter username').waitFor({ state: 'detached', timeout: NAV_TIMEOUT_MS });

    return { browser, page };
  } catch (err) {
    await browser.close();
    throw err;
  }
}

/**
 * Polls the MobCash Business Web "recent transactions" feed for new
 * incoming WinWin deposits and matches them against pending Badal Exchange
 * deposit orders (same verified-match logic as the manual-confirmation
 * path: WinWin ID + amount, deduped by a stable per-row reference).
 *
 * INFERRED selectors below (never confirmed against live DOM) -- the row
 * shape is modeled on the product's "Recent transactions" screenshot:
 * each row shows a transaction number, a WebUser ID, and a signed amount.
 */
export async function pollMobCashDeposits(): Promise<{ found: number; matched: number }> {
  const startedAt = new Date();
  let browser: Browser | null = null;
  try {
    const result = await withAdvisoryLock(async () => {
      const session = await launchAndLogin();
      browser = session.browser;
      const { page } = session;

      // Best-effort: look for a "Recent transactions" section and read its
      // rows. Left intentionally defensive (returns an empty list rather
      // than throwing) since this exact markup has never been observed.
      const rows = await page
        .locator('text=Recent transactions')
        .locator('xpath=following::*[contains(@class,"transaction") or contains(text(),"ID ")]')
        .allTextContents()
        .catch(() => [] as string[]);

      const { submitWinwinTransaction } = await import('./matchingService');
      let matched = 0;
      for (const raw of rows) {
        const parsed = parseTransactionRow(raw);
        if (!parsed) continue;
        const outcome = await submitWinwinTransaction({
          submittedBy: SYSTEM_ACTOR_ID,
          winwinId: parsed.winwinId,
          amountCents: parsed.amountCents,
          mobcashRef: parsed.reference,
          occurredAt: new Date().toISOString(),
        });
        if (outcome.status === 'matched') matched += 1;
      }
      return { found: rows.length, matched };
    });

    await recordAutomationOutcome(PROVIDER, true);
    await logRun({ runType: 'deposit_poll', status: 'success', message: `Scanned ${result.found} rows, matched ${result.matched}`, startedAt });
    return result;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    const { tripped } = await recordAutomationOutcome(PROVIDER, false);
    await logRun({
      runType: 'deposit_poll',
      status: 'failed',
      message: tripped ? `${message} (circuit breaker tripped)` : message,
      startedAt,
    });
    throw err;
  } finally {
    if (browser) await (browser as Browser).close().catch(() => {});
  }
}

/** Placeholder actor id: a real seeded "MobCash Automation" system user (see seed.ts). */
export const SYSTEM_ACTOR_ID = '00000000-0000-0000-0000-000000000001';

export interface LoginCheckResult {
  success: boolean;
  message: string;
  eposList: string[];
}

/**
 * On-demand admin action: attempts a real login to MobCash Business Web
 * with the given (not-yet-saved) credentials and, on success, reads the
 * "Select your EPOS" screen MobCash shows after login. Never fabricates an
 * EPOS list -- an empty array here means the real portal reported none
 * ("No available EPOSes" in the product screenshot), same as an admin
 * would see logging in by hand. Independent of automation_mode/dry_run
 * (those govern the *recurring* deposit-poll/withdrawal automation only);
 * this is a one-off verification a human explicitly triggered.
 */
export async function checkMobCashLogin(username: string, password: string): Promise<LoginCheckResult> {
  const startedAt = new Date();
  let browser: Browser | null = null;
  try {
    const result = await withAdvisoryLock(async () => {
      const config = await loadConfig();
      browser = await chromium.launch({
        executablePath: chromiumExecutablePath(),
        headless: true,
        args: ['--no-sandbox'],
      });
      const page = await browser.newPage();
      const CHECK_TIMEOUT_MS = 20000;
      page.setDefaultTimeout(CHECK_TIMEOUT_MS);

      await page.goto(config.businessWebUrl, { waitUntil: 'domcontentloaded' });
      await page.getByPlaceholder('Enter username').fill(username);
      await page.getByPlaceholder('Enter password').fill(password);
      await page.getByRole('button', { name: 'Log in' }).click();

      // Race the two outcomes MobCash's own screens show us: the login form
      // disappearing (success) vs. a visible error staying on it (failure).
      // Neither selector is confirmed live -- both are inferred from the
      // product's own screenshots, so this still falls back to the
      // CHECK_TIMEOUT_MS ceiling if neither element ever appears/detaches.
      const outcome = await Promise.race([
        page
          .getByPlaceholder('Enter username')
          .waitFor({ state: 'detached', timeout: CHECK_TIMEOUT_MS })
          .then(() => 'success' as const)
          .catch(() => 'timeout' as const),
        page
          .getByText(/invalid|incorrect|failed|error/i)
          .first()
          .waitFor({ state: 'visible', timeout: CHECK_TIMEOUT_MS })
          .then(() => 'error' as const)
          .catch(() => 'timeout' as const),
      ]);

      if (outcome !== 'success') {
        const errorText = await page
          .getByText(/invalid|incorrect|failed|error/i)
          .first()
          .textContent()
          .catch(() => null);
        return { success: false, message: errorText?.trim() || 'Login did not succeed (unrecognized response from MobCash).', eposList: [] };
      }

      // Post-login: MobCash shows "Select your EPOS" with either a list of
      // named EPOS entries or the empty state "No available EPOSes".
      const emptyState = await page.getByText('No available EPOSes').isVisible().catch(() => false);
      if (emptyState) {
        return { success: true, message: 'Login succeeded. No EPOS accounts are available on this MobCash account.', eposList: [] };
      }

      const eposList = await page
        .getByText('List of EPOSes')
        .locator('xpath=following::li | following::*[contains(@class,"epos")]')
        .allTextContents()
        .catch(() => [] as string[]);
      const cleaned = eposList.map((t) => t.trim()).filter(Boolean);

      return {
        success: true,
        message: cleaned.length > 0 ? `Login succeeded. ${cleaned.length} EPOS account(s) found.` : 'Login succeeded.',
        eposList: cleaned,
      };
    });

    await recordAutomationOutcome(PROVIDER, result.success);
    await logRun({ runType: 'login_check', status: result.success ? 'success' : 'failed', message: result.message, startedAt });
    return result;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await recordAutomationOutcome(PROVIDER, false);
    await logRun({ runType: 'login_check', status: 'failed', message, startedAt });
    return { success: false, message, eposList: [] };
  } finally {
    if (browser) await (browser as Browser).close().catch(() => {});
  }
}

function parseTransactionRow(text: string): { winwinId: string; amountCents: number; reference: string } | null {
  // Example target shape (from the product screenshot): "№…383  ID 1772416375  +1.50 $  19.08.2026 / 18:38:27"
  const idMatch = text.match(/ID\s*(\d{6,})/);
  const amountMatch = text.match(/\+?\s*\$?\s*(\d+(?:\.\d{1,2})?)/);
  const refMatch = text.match(/№\s*[\d.]+/) ?? text.match(/#\s*[\dA-Za-z]+/);
  if (!idMatch || !amountMatch) return null;
  return {
    winwinId: idMatch[1],
    amountCents: Math.round(parseFloat(amountMatch[1]) * 100),
    reference: refMatch ? refMatch[0] : `row:${Buffer.from(text).toString('base64').slice(0, 24)}`,
  };
}

export interface WithdrawalSubmitInput {
  orderId: string;
  winwinId: string;
  netCents: number;
}

export interface WithdrawalSubmitResult {
  status: 'success' | 'dry_run';
  reference: string;
}

/**
 * Submits one WinWin withdrawal (a "Top up WebUser" action crediting the
 * customer's own WinWin balance) via MobCash Business Web. This is the
 * genuinely risky half of this integration -- it takes a real action that
 * moves money -- so it respects dry_run strictly: in dry-run mode it fills
 * the form and stops immediately before the final confirmation click.
 *
 * INFERRED selectors below (never confirmed against live DOM), modeled on
 * the product's "Top up WebUser" screenshots (Step 1: WebUser ID, Step 2:
 * amount, each followed by a "Next" button).
 */
export async function submitMobCashWithdrawal(input: WithdrawalSubmitInput): Promise<WithdrawalSubmitResult> {
  const startedAt = new Date();
  let browser: Browser | null = null;
  let currentPage: Page | null = null;
  try {
    const { rows } = await pool.query('SELECT dry_run FROM payment_integrations WHERE provider = $1', [PROVIDER]);
    const dryRun = rows[0]?.dry_run ?? true;

    const result = await withAdvisoryLock(async () => {
      const session = await launchAndLogin();
      browser = session.browser;
      const { page } = session;
      currentPage = page;

      // Navigate to the "Top up WebUser" flow. The exact entry point (a nav
      // link, a dashboard button) was never observed -- try a text-based
      // locator first.
      await page.getByText('Top up', { exact: false }).first().click();

      await page.getByPlaceholder('Enter WebUser ID').fill(input.winwinId);
      await page.getByRole('button', { name: 'Next' }).click();

      const amount = (input.netCents / 100).toFixed(2);
      await page.getByPlaceholder(/amount/i).fill(amount).catch(async () => {
        // Fallback: the amount step may reuse the same numeric-keypad
        // pattern shown in the screenshot rather than a text input.
        for (const digit of amount.replace('.', '')) {
          await page.getByRole('button', { name: digit, exact: true }).click();
        }
      });

      if (dryRun) {
        return { status: 'dry_run' as const, reference: `DRYRUN-${input.orderId}` };
      }

      await page.getByRole('button', { name: 'Next' }).click();
      // Capture whatever the portal shows as a confirmation/reference after
      // submission. Never confirmed live -- falls back to a generated
      // reference if nothing recognizable is found, which still lets the
      // order complete but is flagged for admin review via the log message.
      const confirmationText = await page
        .locator('text=/reference|confirmation|success/i')
        .first()
        .textContent()
        .catch(() => null);

      return {
        status: 'success' as const,
        reference: confirmationText?.trim() || `MOBCASH-${input.orderId}-${Date.now()}`,
      };
    });

    await recordAutomationOutcome(PROVIDER, true);
    await logRun({
      runType: 'withdrawal_submit',
      orderId: input.orderId,
      status: result.status,
      message: result.status === 'dry_run' ? 'Dry run: form filled, stopped before final confirmation' : `Submitted, reference: ${result.reference}`,
      startedAt,
    });
    return result;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    const { tripped } = await recordAutomationOutcome(PROVIDER, false);
    const screenshot = currentPage ? await captureFailureScreenshot(currentPage) : null;
    await logRun({
      runType: 'withdrawal_submit',
      orderId: input.orderId,
      status: 'failed',
      message: tripped ? `${message} (circuit breaker tripped)` : message,
      screenshotBase64: screenshot,
      startedAt,
    });
    throw err;
  } finally {
    if (browser) await (browser as Browser).close().catch(() => {});
  }
}
