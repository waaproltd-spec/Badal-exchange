import { useState, type FormEvent } from 'react';
import { Loading, ErrorState } from './AsyncState';
import { StatusBadge } from './StatusBadge';
import { useFetch } from '../hooks/useFetch';
import {
  getPaymentIntegration,
  setIntegrationStatus,
  testIntegrationConnection,
  updateIntegrationCredentials,
  setAutomationMode,
  resetCircuitBreaker,
  listAutomationRuns,
} from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';
import { dateTime } from '../lib/format';
import type { IntegrationProvider, PaymentIntegration } from '../api/types';

const TEST_RESULT_LABEL: Record<string, string> = {
  success: 'Success',
  failed: 'Failed',
  not_configured: 'Not configured',
};

const MOBCASH_BUSINESS_WEB_URL = 'https://businessweb-mobi.com/auth/login';

export function IntegrationPanel({ provider, label }: { provider: IntegrationProvider; label: string }) {
  const { data, loading, error, reload } = useFetch(() => getPaymentIntegration(provider), [provider]);
  const isMobCash = provider === 'mobcash_winwin';

  return (
    <div className="stack">
      {loading && <Loading />}
      {error && <ErrorState message={error} />}
      {data && (
        <>
          {isMobCash && <AutomationStatusBanner data={data} />}

          <div className="card card-pad">
            <div className="row-between" style={{ marginBottom: 16 }}>
              <div>
                <h3 style={{ fontSize: 15, fontWeight: 600 }}>{label} account status</h3>
                <div className="card-header-sub" style={{ marginTop: 3 }}>
                  {data.hasCredentials ? `Manager username: ${data.username ?? '—'}` : 'No credentials saved yet'}
                </div>
              </div>
              <div className="row">
                <StatusBadge status={data.status} />
                <StatusToggle provider={provider} status={data.status} onChanged={reload} />
              </div>
            </div>

            {isMobCash && (
              <a
                href={MOBCASH_BUSINESS_WEB_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="btn btn-sm"
                style={{ marginBottom: 16, display: 'inline-flex' }}
              >
                Open MobCash Business Web ↗
              </a>
            )}

            <div className="detail-grid">
              <div className="detail-item">
                <span className="detail-label">Last successful connection</span>
                <span className="detail-value">{dateTime(data.lastSuccessfulConnectionAt)}</span>
              </div>
              <div className="detail-item">
                <span className="detail-label">Last transaction</span>
                <span className="detail-value">{dateTime(data.lastTransactionAt)}</span>
              </div>
              <div className="detail-item">
                <span className="detail-label">Last test</span>
                <span className="detail-value">
                  {data.lastTestAt ? `${TEST_RESULT_LABEL[data.lastTestResult ?? ''] ?? data.lastTestResult} · ${dateTime(data.lastTestAt)}` : 'Never tested'}
                </span>
              </div>
              <div className="detail-item">
                <span className="detail-label">Last updated</span>
                <span className="detail-value">{dateTime(data.updatedAt)}</span>
              </div>
            </div>

            {data.lastTestMessage && (
              <div className="note-banner" style={{ marginTop: 16 }}>
                {data.lastTestMessage}
              </div>
            )}

            <TestConnectionButton provider={provider} onChanged={reload} />
          </div>

          {isMobCash && <AutomationControls provider={provider} data={data} onChanged={reload} />}
          {isMobCash && <AutomationRunLog provider={provider} />}

          <CredentialsForm provider={provider} label={label} onSaved={reload} />
        </>
      )}
    </div>
  );
}

function AutomationStatusBanner({ data }: { data: PaymentIntegration }) {
  if (data.circuitBreakerTrippedAt) {
    return (
      <div className="error-banner">
        Unofficial automation circuit breaker TRIPPED ({data.circuitBreakerReason ?? 'repeated failures'}) at{' '}
        {dateTime(data.circuitBreakerTrippedAt)}. Automatic processing has stopped. Review the run log below, fix the
        underlying issue, then reset the circuit breaker to resume.
      </div>
    );
  }
  if (data.automationMode !== 'automatic') {
    return (
      <div className="warning-banner">
        Unofficial automatic processing is OFF. WinWin deposits and withdrawals are confirmed manually: an authorized
        admin/agent operates the real MobCash Business Web portal directly and keys the confirmed result into the
        form below. This is the only officially-supported flow -- MobCash has no API.
      </div>
    );
  }
  if (data.dryRun) {
    return (
      <div className="warning-banner">
        Unofficial automatic processing is ON in DRY RUN mode: withdrawals are filled out but stopped before the
        final confirmation, and deposits are still only matched (never anything sent). No real money moves yet. This
        is Badal Exchange's own browser automation of the real portal, not a MobCash-provided integration. Review the
        run log below, then turn dry run off when you're confident it's working correctly.
      </div>
    );
  }
  return (
    <div className="success-banner">
      Unofficial automatic processing is LIVE. Backend-driven browser automation of MobCash Business Web is
      submitting real withdrawals and matching deposits without manual confirmation. This is not a MobCash-certified
      integration -- it can break if MobCash changes their site.
    </div>
  );
}

function AutomationControls({
  provider,
  data,
  onChanged,
}: {
  provider: IntegrationProvider;
  data: PaymentIntegration;
  onChanged: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function updateMode(mode: 'manual' | 'automatic', dryRun: boolean) {
    setBusy(true);
    setError(null);
    try {
      await setAutomationMode(provider, mode, dryRun);
      onChanged();
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to update automation mode.');
    } finally {
      setBusy(false);
    }
  }

  async function reset() {
    setBusy(true);
    setError(null);
    try {
      await resetCircuitBreaker(provider);
      onChanged();
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to reset circuit breaker.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="card card-pad">
      <h3 style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 6 }}>Unofficial automatic processing (browser automation)</h3>
      <p className="text-muted" style={{ fontSize: 12.5, marginBottom: 16 }}>
        MobCash/WinWin provides no public API, SDK, or partner integration. "Automatic" here means the backend logs
        into the real MobCash Business Web itself and drives the same deposit-matching and "Top up WebUser"
        withdrawal flow a human admin would otherwise operate by hand -- explicitly authorized in place of manual
        confirmation, and clearly not an official MobCash integration. It can break if MobCash changes their site, so
        it must be run in dry run and reviewed before going live.
      </p>

      <div className="detail-grid" style={{ marginBottom: 16 }}>
        <div className="detail-item">
          <span className="detail-label">Mode</span>
          <span className="detail-value">{data.automationMode === 'automatic' ? 'Automatic' : 'Manual'}</span>
        </div>
        <div className="detail-item">
          <span className="detail-label">Dry run</span>
          <span className="detail-value">{data.dryRun ? 'On (no real money moves)' : 'Off (live)'}</span>
        </div>
        <div className="detail-item">
          <span className="detail-label">Consecutive failures</span>
          <span className="detail-value">{data.consecutiveFailures} / 3</span>
        </div>
        <div className="detail-item">
          <span className="detail-label">Circuit breaker</span>
          <span className="detail-value">{data.circuitBreakerTrippedAt ? `Tripped ${dateTime(data.circuitBreakerTrippedAt)}` : 'OK'}</span>
        </div>
      </div>

      {error && <div className="error-banner" style={{ marginBottom: 12 }}>{error}</div>}

      <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
        {data.automationMode !== 'automatic' && (
          <button className="btn btn-primary" disabled={busy || !data.hasCredentials} onClick={() => updateMode('automatic', true)}>
            Enable automatic (dry run)
          </button>
        )}
        {data.automationMode === 'automatic' && data.dryRun && (
          <button className="btn btn-primary" disabled={busy || !!data.circuitBreakerTrippedAt} onClick={() => updateMode('automatic', false)}>
            Turn dry run OFF (go live)
          </button>
        )}
        {data.automationMode === 'automatic' && !data.dryRun && (
          <button className="btn btn-sm" disabled={busy} onClick={() => updateMode('automatic', true)}>
            Turn dry run back on
          </button>
        )}
        {data.automationMode === 'automatic' && (
          <button className="btn btn-sm" disabled={busy} onClick={() => updateMode('manual', true)}>
            Disable automation
          </button>
        )}
        {data.circuitBreakerTrippedAt && (
          <button className="btn btn-sm" disabled={busy} onClick={reset}>
            Reset circuit breaker
          </button>
        )}
      </div>
      {!data.hasCredentials && (
        <p className="text-muted" style={{ fontSize: 12, marginTop: 10 }}>
          Save manager credentials below before automation can be enabled.
        </p>
      )}
    </div>
  );
}

function AutomationRunLog({ provider }: { provider: IntegrationProvider }) {
  const { data, loading, error } = useFetch(() => listAutomationRuns(provider), [provider]);

  return (
    <div className="card card-pad">
      <h3 style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 6 }}>Automation run log</h3>
      <p className="text-muted" style={{ fontSize: 12.5, marginBottom: 16 }}>
        Every automated deposit-feed poll and withdrawal submission attempt, regardless of outcome. Use this to
        verify automation is actually working before relying on it.
      </p>
      {loading && <Loading />}
      {error && <ErrorState message={error} />}
      {data && data.length === 0 && <p className="text-muted" style={{ fontSize: 13 }}>No automation runs yet.</p>}
      {data && data.length > 0 && (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>When</th>
                <th>Type</th>
                <th>Status</th>
                <th>Order</th>
                <th>Message</th>
              </tr>
            </thead>
            <tbody>
              {data.map((run) => (
                <tr key={run.id}>
                  <td>{dateTime(run.finished_at)}</td>
                  <td>{run.run_type === 'deposit_poll' ? 'Deposit poll' : 'Withdrawal submit'}</td>
                  <td>
                    <StatusBadge status={run.status === 'dry_run' ? 'pending' : run.status} />
                  </td>
                  <td>{run.order_id ? <span className="mono">{run.order_id.slice(0, 8)}</span> : '—'}</td>
                  <td style={{ maxWidth: 420, whiteSpace: 'pre-wrap', fontSize: 12.5 }}>{run.message ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function StatusToggle({
  provider,
  status,
  onChanged,
}: {
  provider: IntegrationProvider;
  status: 'active' | 'inactive';
  onChanged: () => void;
}) {
  const [busy, setBusy] = useState(false);

  async function toggle() {
    setBusy(true);
    try {
      await setIntegrationStatus(provider, status === 'active' ? 'inactive' : 'active');
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <button className="btn btn-sm" disabled={busy} onClick={toggle}>
      {busy ? '…' : status === 'active' ? 'Set inactive' : 'Set active'}
    </button>
  );
}

function TestConnectionButton({ provider, onChanged }: { provider: IntegrationProvider; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);

  async function run() {
    setBusy(true);
    try {
      await testIntegrationConnection(provider);
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <button className="btn" style={{ marginTop: 16 }} disabled={busy} onClick={run}>
      {busy ? <span className="spinner" /> : null}
      {busy ? 'Testing…' : 'Test connection'}
    </button>
  );
}

function CredentialsForm({ provider, label, onSaved }: { provider: IntegrationProvider; label: string; onSaved: () => void }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(false);
    setSubmitting(true);
    try {
      await updateIntegrationCredentials(provider, { username: username.trim(), password });
      setUsername('');
      setPassword('');
      setSuccess(true);
      onSaved();
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to update credentials.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="card card-pad">
      <h3 style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 6 }}>Update credentials</h3>
      <p className="text-muted" style={{ fontSize: 12.5, marginBottom: 16 }}>
        {label} manager-account credentials are stored encrypted. The password is write-only -- it is never returned by the
        API, so this form always starts empty.
      </p>
      <form onSubmit={handleSubmit} className="stack" style={{ gap: 14 }}>
        <div className="grid grid-2">
          <div className="field">
            <label htmlFor={`${provider}-username`}>Username</label>
            <input
              id={`${provider}-username`}
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoComplete="off"
              required
            />
          </div>
          <div className="field">
            <label htmlFor={`${provider}-password`}>Password</label>
            <input
              id={`${provider}-password`}
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="new-password"
              placeholder="Enter a new password"
              required
            />
          </div>
        </div>
        {error && <div className="error-banner">{error}</div>}
        {success && <div className="note-banner">Credentials saved.</div>}
        <div>
          <button type="submit" className="btn btn-primary" disabled={submitting}>
            {submitting ? 'Saving…' : 'Save credentials'}
          </button>
        </div>
      </form>
    </div>
  );
}
