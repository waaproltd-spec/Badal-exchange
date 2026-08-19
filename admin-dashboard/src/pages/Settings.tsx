import { useState, type FormEvent } from 'react';
import { Page } from '../components/Page';
import { updateWithdrawalLimits } from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';
import type { OrderMethod } from '../api/types';

export function Settings() {
  return (
    <Page title="Settings" subtitle="Low-level system configuration. Rates, fees and integrations live on their own pages.">
      <div className="note-banner">
        Most configuration lives in Exchange Rates, Fees and Payment Integrations. This page currently only exposes
        withdrawal limits (min/max amount per method) -- the API does not expose a way to read the currently active
        limits, only to set new ones, so no current value is shown below.
      </div>
      <div className="rate-grid">
        <LimitForm method="evc_plus" label="EVC Plus" />
        <LimitForm method="winwin" label="WinWin" />
      </div>
    </Page>
  );
}

function LimitForm({ method, label }: { method: OrderMethod; label: string }) {
  const [minAmount, setMinAmount] = useState('');
  const [maxAmount, setMaxAmount] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(false);
    const min = Number(minAmount);
    const max = Number(maxAmount);
    if (!Number.isFinite(min) || min < 0 || !Number.isFinite(max) || max < 0) {
      setError('Enter valid non-negative amounts.');
      return;
    }
    setSubmitting(true);
    try {
      await updateWithdrawalLimits({ method, minAmount: min, maxAmount: max });
      setSuccess(true);
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to update limits.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="rate-card">
      <span className="rate-card-title">{label} withdrawal limits</span>
      <form onSubmit={handleSubmit} className="stack" style={{ gap: 12 }}>
        <div className="field">
          <label htmlFor={`${method}-min`}>Minimum amount</label>
          <input id={`${method}-min`} value={minAmount} onChange={(e) => setMinAmount(e.target.value)} required />
        </div>
        <div className="field">
          <label htmlFor={`${method}-max`}>Maximum amount</label>
          <input id={`${method}-max`} value={maxAmount} onChange={(e) => setMaxAmount(e.target.value)} required />
        </div>
        {error && <div className="error-banner">{error}</div>}
        {success && <div className="note-banner">Limits updated.</div>}
        <div>
          <button type="submit" className="btn btn-primary btn-sm" disabled={submitting}>
            {submitting ? 'Saving…' : 'Save limits'}
          </button>
        </div>
      </form>
    </div>
  );
}
