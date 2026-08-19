import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { submitWinwinConfirmation } from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';
import type { WinwinConfirmationResult } from '../api/types';

const EMPTY = { winwinId: '', depositCode: '', amount: '', mobcashRef: '' };

export function WinwinConfirmationForm() {
  const navigate = useNavigate();
  const [form, setForm] = useState(EMPTY);
  const [result, setResult] = useState<WinwinConfirmationResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  function update<K extends keyof typeof form>(key: K, value: string) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setResult(null);
    setSubmitting(true);
    try {
      const res = await submitWinwinConfirmation({
        winwinId: form.winwinId.trim(),
        depositCode: form.depositCode.trim() || undefined,
        amount: form.amount.trim(),
        mobcashRef: form.mobcashRef.trim(),
        occurredAt: new Date().toISOString(),
      });
      setResult(res);
      if (res.status === 'matched') setForm(EMPTY);
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to submit confirmation.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="card card-pad">
      <h3 style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 6 }}>Manual WinWin confirmation</h3>
      <p className="text-muted" style={{ fontSize: 12.5, marginBottom: 16 }}>
        Use this after you have personally observed a real, completed "Top up WebUser" deposit in the actual WinWin
        manager app. Badal Exchange matches it against a pending WinWin deposit order by deposit code, WinWin ID and
        amount, and only then credits the customer's wallet. The MobCash reference is used to dedupe -- submitting the
        same reference twice is safe and will not double-credit anyone.
      </p>

      <form onSubmit={handleSubmit} className="stack" style={{ gap: 14 }}>
        <div className="grid grid-2">
          <div className="field">
            <label htmlFor="winwin-id">WinWin ID</label>
            <input id="winwin-id" value={form.winwinId} onChange={(e) => update('winwinId', e.target.value)} required />
          </div>
          <div className="field">
            <label htmlFor="deposit-code">Deposit code (optional)</label>
            <input id="deposit-code" value={form.depositCode} onChange={(e) => update('depositCode', e.target.value)} />
          </div>
          <div className="field">
            <label htmlFor="ww-amount">Amount</label>
            <input
              id="ww-amount"
              inputMode="decimal"
              placeholder="0.00"
              value={form.amount}
              onChange={(e) => update('amount', e.target.value)}
              required
            />
          </div>
          <div className="field">
            <label htmlFor="mobcash-ref">MobCash reference</label>
            <input id="mobcash-ref" value={form.mobcashRef} onChange={(e) => update('mobcashRef', e.target.value)} required />
          </div>
        </div>

        {error && <div className="error-banner">{error}</div>}

        {result && result.status === 'matched' && (
          <div className="success-banner">
            Matched -- the customer's wallet has been credited.
            {result.orderId && (
              <>
                {' '}
                Order:{' '}
                <span className="mono" style={{ cursor: 'pointer', textDecoration: 'underline' }} onClick={() => navigate(`/orders/${result.orderId}`)}>
                  {result.orderId}
                </span>
              </>
            )}
          </div>
        )}
        {result && result.status === 'unmatched' && (
          <div className="warning-banner">
            No pending WinWin deposit order matches those details. Double-check the WinWin ID, deposit code and amount
            and try again.
          </div>
        )}
        {result && result.status === 'duplicate' && (
          <div className="muted-banner">
            This MobCash reference was already submitted before. Nothing was double-credited.
          </div>
        )}

        <div>
          <button type="submit" className="btn btn-primary" disabled={submitting}>
            {submitting ? 'Submitting…' : 'Submit confirmation'}
          </button>
        </div>
      </form>
    </div>
  );
}
