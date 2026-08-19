import { useState, type FormEvent } from 'react';
import { Loading, ErrorState } from './AsyncState';
import { StatusBadge } from './StatusBadge';
import { useFetch } from '../hooks/useFetch';
import {
  getPaymentIntegration,
  setIntegrationStatus,
  testIntegrationConnection,
  updateIntegrationCredentials,
} from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';
import { dateTime } from '../lib/format';
import type { IntegrationProvider } from '../api/types';

const TEST_RESULT_LABEL: Record<string, string> = {
  success: 'Success',
  failed: 'Failed',
  not_configured: 'Not configured',
};

export function IntegrationPanel({ provider, label }: { provider: IntegrationProvider; label: string }) {
  const { data, loading, error, reload } = useFetch(() => getPaymentIntegration(provider), [provider]);

  return (
    <div className="stack">
      {loading && <Loading />}
      {error && <ErrorState message={error} />}
      {data && (
        <>
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

          <CredentialsForm provider={provider} label={label} onSaved={reload} />
        </>
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
