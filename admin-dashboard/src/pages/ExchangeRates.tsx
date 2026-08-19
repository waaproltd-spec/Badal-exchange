import { useState } from 'react';
import { Page } from '../components/Page';
import { Loading, ErrorState } from '../components/AsyncState';
import { useFetch } from '../hooks/useFetch';
import { getExchangeRates, updateExchangeRate } from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';
import { dateTime, methodLabel } from '../lib/format';
import type { ExchangeRate, OrderDirection, OrderMethod } from '../api/types';

const COMBOS: { method: OrderMethod; direction: OrderDirection }[] = [
  { method: 'evc_plus', direction: 'deposit' },
  { method: 'evc_plus', direction: 'withdraw' },
  { method: 'winwin', direction: 'deposit' },
  { method: 'winwin', direction: 'withdraw' },
];

export function ExchangeRates() {
  const { data, loading, error, reload } = useFetch(() => getExchangeRates(), []);

  return (
    <Page title="Exchange Rates" subtitle="Active rate applied to new orders, per method and direction">
      <div className="note-banner">
        Updating a rate creates a new snapshot -- past orders keep the rate that was active when they were placed, so
        history never changes. Only future orders use the new rate.
      </div>

      {loading && <Loading />}
      {error && <ErrorState message={error} />}
      {data && (
        <div className="rate-grid">
          {COMBOS.map((combo) => (
            <RateCard
              key={`${combo.method}-${combo.direction}`}
              combo={combo}
              current={data.find((r) => r.method === combo.method && r.direction === combo.direction) ?? null}
              onSaved={reload}
            />
          ))}
        </div>
      )}
    </Page>
  );
}

function RateCard({
  combo,
  current,
  onSaved,
}: {
  combo: { method: OrderMethod; direction: OrderDirection };
  current: ExchangeRate | null;
  onSaved: () => void;
}) {
  const [value, setValue] = useState(current?.rate ?? '');
  const [editing, setEditing] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    const num = Number(value);
    if (!Number.isFinite(num) || num <= 0) {
      setError('Enter a positive number.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      await updateExchangeRate({ method: combo.method, direction: combo.direction, rate: num });
      setEditing(false);
      onSaved();
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to update rate.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="rate-card">
      <div className="rate-card-head">
        <span className="rate-card-title">
          {methodLabel(combo.method)} · {combo.direction === 'deposit' ? 'Deposit' : 'Withdraw'}
        </span>
      </div>

      {!editing && (
        <>
          <span className="rate-card-value">{current ? current.rate : '—'}</span>
          <span className="text-muted" style={{ fontSize: 12 }}>
            {current ? `Set ${dateTime(current.created_at)}` : 'No active rate configured'}
          </span>
          <div>
            <button className="btn btn-sm" onClick={() => { setValue(current?.rate ?? ''); setEditing(true); }}>
              Update
            </button>
          </div>
        </>
      )}

      {editing && (
        <>
          <input className="search-input" style={{ width: '100%' }} value={value} onChange={(e) => setValue(e.target.value)} />
          {error && <div className="error-banner">{error}</div>}
          <div className="row">
            <button className="btn btn-primary btn-sm" disabled={submitting} onClick={save}>
              {submitting ? 'Saving…' : 'Save'}
            </button>
            <button className="btn btn-sm" disabled={submitting} onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        </>
      )}
    </div>
  );
}
