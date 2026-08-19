import { pool } from '../db/pool';
import { encryptSecret, decryptSecret } from '../lib/crypto';
import { ApiError } from '../lib/errors';
import { writeAudit } from '../lib/audit';
import { Role } from '../auth/jwt';

export type IntegrationProvider = 'evc_plus' | 'mobcash_winwin';

export interface IntegrationSummary {
  provider: IntegrationProvider;
  status: 'active' | 'inactive';
  configJson: Record<string, unknown>;
  hasCredentials: boolean;
  username: string | null; // username is shown (not secret), password never is
  lastTestAt: string | null;
  lastTestResult: string | null;
  lastTestMessage: string | null;
  lastSuccessfulConnectionAt: string | null;
  lastTransactionAt: string | null;
  updatedAt: string;
  // Browser-automation state (MobCash Business Web). No official API is
  // confirmed to exist, so "automatic" here means backend-driven browser
  // automation against the real portal -- see mobcashAutomation.ts.
  automationMode: 'manual' | 'automatic';
  dryRun: boolean;
  consecutiveFailures: number;
  circuitBreakerTrippedAt: string | null;
  circuitBreakerReason: string | null;
}

function toSummary(row: any): IntegrationSummary {
  let username: string | null = null;
  if (row.encrypted_username && row.username_iv && row.username_auth_tag) {
    try {
      username = decryptSecret({
        ciphertext: row.encrypted_username,
        iv: row.username_iv,
        authTag: row.username_auth_tag,
      });
    } catch {
      username = null;
    }
  }
  return {
    provider: row.provider,
    status: row.status,
    configJson: row.config_json ?? {},
    hasCredentials: row.has_credentials,
    username,
    lastTestAt: row.last_test_at,
    lastTestResult: row.last_test_result,
    lastTestMessage: row.last_test_message,
    lastSuccessfulConnectionAt: row.last_successful_connection_at,
    lastTransactionAt: row.last_transaction_at,
    updatedAt: row.updated_at,
    automationMode: row.automation_mode ?? 'manual',
    dryRun: row.dry_run ?? true,
    consecutiveFailures: row.consecutive_failures ?? 0,
    circuitBreakerTrippedAt: row.circuit_breaker_tripped_at ?? null,
    circuitBreakerReason: row.circuit_breaker_reason ?? null,
  };
}

export async function getIntegration(provider: IntegrationProvider): Promise<IntegrationSummary | null> {
  const { rows } = await pool.query('SELECT * FROM payment_integrations WHERE provider = $1', [provider]);
  if (!rows[0]) return null;
  return toSummary(rows[0]);
}

export async function listIntegrations(): Promise<IntegrationSummary[]> {
  const { rows } = await pool.query('SELECT * FROM payment_integrations ORDER BY provider');
  return rows.map(toSummary);
}

/**
 * Note: usernames are encrypted at rest alongside passwords for defense in
 * depth, but are returned to authorized admins in getIntegration() since
 * they are needed to identify which manager account is configured.
 * Passwords are NEVER decrypted for API output -- only used server-side by
 * the (currently unimplemented, pending an official API) provider adapter.
 */
export async function upsertIntegrationCredentials(
  provider: IntegrationProvider,
  username: string,
  password: string,
  configJson: Record<string, unknown>,
  actorId: string,
  actorRole: Role
): Promise<IntegrationSummary> {
  const encUser = encryptSecret(username);
  const encPass = encryptSecret(password);

  const before = await pool.query('SELECT provider, status, config_json FROM payment_integrations WHERE provider = $1', [provider]);

  const { rows } = await pool.query(
    `INSERT INTO payment_integrations (
       provider, status, config_json,
       encrypted_username, username_iv, username_auth_tag,
       encrypted_password, password_iv, password_auth_tag,
       has_credentials, updated_by, updated_at
     )
     VALUES ($1, 'inactive', $2, $3, $4, $5, $6, $7, $8, true, $9, now())
     ON CONFLICT (provider) DO UPDATE SET
       config_json = EXCLUDED.config_json,
       encrypted_username = EXCLUDED.encrypted_username,
       username_iv = EXCLUDED.username_iv,
       username_auth_tag = EXCLUDED.username_auth_tag,
       encrypted_password = EXCLUDED.encrypted_password,
       password_iv = EXCLUDED.password_iv,
       password_auth_tag = EXCLUDED.password_auth_tag,
       has_credentials = true,
       updated_by = EXCLUDED.updated_by,
       updated_at = now()
     RETURNING *`,
    [
      provider,
      JSON.stringify(configJson ?? {}),
      encUser.ciphertext,
      encUser.iv,
      encUser.authTag,
      encPass.ciphertext,
      encPass.iv,
      encPass.authTag,
      actorId,
    ]
  );

  await writeAudit({
    actorId,
    actorRole,
    action: 'payment_integration.update_credentials',
    entityType: 'payment_integration',
    entityId: provider,
    before: before.rows[0] ?? null,
    after: { provider, status: rows[0].status, configJson: rows[0].config_json, username_changed: true },
  });

  return toSummary(rows[0]);
}

export async function setIntegrationStatus(
  provider: IntegrationProvider,
  status: 'active' | 'inactive',
  actorId: string,
  actorRole: Role
): Promise<IntegrationSummary> {
  const { rows } = await pool.query(
    `UPDATE payment_integrations SET status = $1, updated_by = $2, updated_at = now() WHERE provider = $3 RETURNING *`,
    [status, actorId, provider]
  );
  if (!rows[0]) throw ApiError.notFound('Integration not configured yet');
  await writeAudit({
    actorId,
    actorRole,
    action: 'payment_integration.set_status',
    entityType: 'payment_integration',
    entityId: provider,
    after: { status },
  });
  return toSummary(rows[0]);
}

/**
 * Turns backend-driven automation on/off and sets dry-run. Enabling
 * "automatic" requires credentials to already be on file. Dry-run cannot
 * be turned off in the same call that enables automation for the first
 * time -- an admin must do that as a separate, deliberate step after
 * reviewing dry-run output, so real money is never moved by an accidental
 * single click.
 */
export async function setAutomationMode(
  provider: IntegrationProvider,
  mode: 'manual' | 'automatic',
  dryRun: boolean,
  actorId: string,
  actorRole: Role
): Promise<IntegrationSummary> {
  const existing = await pool.query('SELECT * FROM payment_integrations WHERE provider = $1', [provider]);
  const row = existing.rows[0];
  if (!row) throw ApiError.notFound('Integration not configured yet');
  if (mode === 'automatic' && !row.has_credentials) {
    throw ApiError.badRequest('Save manager credentials before enabling automatic processing', 'CREDENTIALS_REQUIRED');
  }
  if (mode === 'automatic' && row.circuit_breaker_tripped_at && dryRun === false) {
    throw ApiError.conflict('Circuit breaker is tripped -- reset it before enabling live (non-dry-run) automation', 'CIRCUIT_BREAKER_TRIPPED');
  }

  const { rows } = await pool.query(
    `UPDATE payment_integrations
     SET automation_mode = $1, dry_run = $2, updated_by = $3, updated_at = now()
     WHERE provider = $4
     RETURNING *`,
    [mode, dryRun, actorId, provider]
  );

  await writeAudit({
    actorId,
    actorRole,
    action: 'payment_integration.set_automation_mode',
    entityType: 'payment_integration',
    entityId: provider,
    before: { automationMode: row.automation_mode, dryRun: row.dry_run },
    after: { automationMode: mode, dryRun },
  });

  return toSummary(rows[0]);
}

export async function resetCircuitBreaker(
  provider: IntegrationProvider,
  actorId: string,
  actorRole: Role
): Promise<IntegrationSummary> {
  const { rows } = await pool.query(
    `UPDATE payment_integrations
     SET circuit_breaker_tripped_at = NULL, circuit_breaker_reason = NULL, consecutive_failures = 0,
         updated_by = $1, updated_at = now()
     WHERE provider = $2
     RETURNING *`,
    [actorId, provider]
  );
  if (!rows[0]) throw ApiError.notFound('Integration not configured yet');
  await writeAudit({
    actorId,
    actorRole,
    action: 'payment_integration.reset_circuit_breaker',
    entityType: 'payment_integration',
    entityId: provider,
  });
  return toSummary(rows[0]);
}

/** Internal bookkeeping called by the automation orchestrator after each run. */
export async function recordAutomationOutcome(provider: IntegrationProvider, success: boolean): Promise<{ tripped: boolean }> {
  if (success) {
    await pool.query(
      `UPDATE payment_integrations SET consecutive_failures = 0, last_successful_connection_at = now() WHERE provider = $1`,
      [provider]
    );
    return { tripped: false };
  }

  const MAX_CONSECUTIVE_FAILURES = 3;
  const { rows } = await pool.query(
    `UPDATE payment_integrations SET consecutive_failures = consecutive_failures + 1 WHERE provider = $1 RETURNING consecutive_failures`,
    [provider]
  );
  const failures = rows[0]?.consecutive_failures ?? 0;
  if (failures >= MAX_CONSECUTIVE_FAILURES) {
    await pool.query(
      `UPDATE payment_integrations
       SET circuit_breaker_tripped_at = now(),
           circuit_breaker_reason = $1
       WHERE provider = $2 AND circuit_breaker_tripped_at IS NULL`,
      [`${MAX_CONSECUTIVE_FAILURES} consecutive automation failures`, provider]
    );
    await writeAudit({
      actorId: null,
      actorRole: null,
      action: 'payment_integration.circuit_breaker_tripped',
      entityType: 'payment_integration',
      entityId: provider,
      after: { consecutiveFailures: failures },
    });
    return { tripped: true };
  }
  return { tripped: false };
}

/**
 * Server-internal only -- decrypts stored credentials for use by a real
 * provider adapter (HTTP call, signed request, etc). NEVER call this from
 * a route handler that returns its result to a client; it exists only for
 * adapter implementations that make outbound calls on the backend itself.
 */
export async function getDecryptedCredentialsForAdapter(
  provider: IntegrationProvider
): Promise<{ username: string; password: string } | null> {
  const { rows } = await pool.query('SELECT * FROM payment_integrations WHERE provider = $1', [provider]);
  const row = rows[0];
  if (!row || !row.has_credentials) return null;
  return {
    username: decryptSecret({ ciphertext: row.encrypted_username, iv: row.username_iv, authTag: row.username_auth_tag }),
    password: decryptSecret({ ciphertext: row.encrypted_password, iv: row.password_iv, authTag: row.password_auth_tag }),
  };
}

/**
 * Honest connection test. Badal Exchange does not screen-scrape or
 * automate a login against the WinWin manager app -- that is explicitly
 * disallowed as a production payment mechanism. Until an officially
 * documented MobCash/WinWin API is confirmed and its adapter implemented,
 * this reports that no automated check is possible and surfaces whether
 * credentials are on file, so admins know the manual-confirmation flow
 * (agent/admin keys in results observed in the real WinWin app) is active.
 */
export async function testIntegrationConnection(
  provider: IntegrationProvider,
  actorId: string,
  actorRole: Role
): Promise<IntegrationSummary> {
  const existing = await pool.query('SELECT * FROM payment_integrations WHERE provider = $1', [provider]);
  if (!existing.rows[0]) throw ApiError.notFound('Integration not configured yet');

  const hasCreds = existing.rows[0].has_credentials as boolean;
  const apiBaseUrl = (existing.rows[0].config_json ?? {}).api_base_url as string | undefined;

  let result: 'success' | 'failed' | 'not_configured';
  let message: string;

  if (!hasCreds) {
    result = 'not_configured';
    message = 'No credentials saved yet.';
  } else if (!apiBaseUrl) {
    result = 'not_configured';
    message =
      provider === 'mobcash_winwin'
        ? 'No officially documented MobCash/WinWin API is configured. Deposits/withdrawals are verified via authorized agent/admin manual confirmation, not an automated connection.'
        : 'No API base URL configured for this integration yet.';
  } else {
    // A future verified provider adapter would perform a real authenticated
    // reachability check here. We deliberately do not fabricate a result.
    result = 'not_configured';
    message = 'API base URL is set, but no verified provider adapter is implemented yet.';
  }

  const { rows } = await pool.query(
    `UPDATE payment_integrations
     SET last_test_at = now(), last_test_result = $1, last_test_message = $2
     WHERE provider = $3
     RETURNING *`,
    [result, message, provider]
  );

  await writeAudit({
    actorId,
    actorRole,
    action: 'payment_integration.test_connection',
    entityType: 'payment_integration',
    entityId: provider,
    after: { result, message },
  });

  return toSummary(rows[0]);
}
