import { useState } from 'react';
import { Page } from '../components/Page';
import { Loading, ErrorState } from '../components/AsyncState';
import { useFetch } from '../hooks/useFetch';
import { getFees, updateFee } from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';
import { dateTime, methodLabel } from '../lib/format';
import type { Fee, OrderDirection, OrderMethod } from '../api/types';

const COMBOS: { method: OrderMethod; direction: OrderDirection }[] = [
  { method: 'evc_plus', direction: 'deposit' },
  { method: 'evc_plus', direction: 'withdraw' },
  { method: 'winwin', direction: 'deposit' },
  { method: 'winwin', direction: 'withdraw' },
];

export function Fees() {
  const { data, loading, error, reload } = useFetch(() => getFees(), []);

  return (
    <Page title="Fees" subtitle="Active fee applied to new orders, per method and direction">
      <div className="note-banner">
        Updating a fee creates a new snapshot -- past orders keep the fee that was active when they were placed. Only
        future orders use the new fee. Flat fees are a dollar amount; percent fees are 0-100.
      </div>

      {loading && <Loading />}
      {error && <ErrorState message={error} />}
      {data && (
        <div className="rate-grid">
          {COMBOS.map((combo) => (
            <FeeCard
              key={`${combo.method}-${combo.direction}`}
              combo={combo}
              current={data.find((f) => f.method === combo.method && f.direction === combo.direction) ?? null}
              onSaved={reload}
            />
          ))}
        </div>
      )}
    </Page>
  );
}

function FeeCard({
  combo,
  current,
  onSaved,
}: {
  combo: { method: OrderMethod; direction: OrderDirection };
  current: Fee | null;
  onSaved: () => void;
}) {
  const [feeType, setFeeType] = useState<'flat' | 'percent'>(current?.fee_type ?? 'flat');
  const [value, setValue] = useState(current?.value ?? '');
  const [editing, setEditing] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    const num = Number(value);
    if (!Number.isFinite(num) || num < 0) {
      setError('Enter a non-negative number.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      await updateFee({ method: combo.method, direction: combo.direction, feeType, value: num });
      setEditing(false);
      onSaved();
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to update fee.');
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
          <span className="rate-card-value">
            {current ? (current.fee_type === 'percent' ? `${current.value}%` : `$${current.value}`) : '—'}
          </span>
          <span className="text-muted" style={{ fontSize: 12 }}>
            {current ? `${current.fee_type === 'percent' ? 'Percent' : 'Flat'} · set ${dateTime(current.created_at)}` : 'No active fee configured'}
          </span>
          <div>
            <button
              className="btn btn-sm"
              onClick={() => {
                setFeeType(current?.fee_type ?? 'flat');
                setValue(current?.value ?? '');
                setEditing(true);
              }}
            >
              Update
            </button>
          </div>
        </>
      )}

      {editing && (
        <>
          <div className="row">
            <select className="search-input" style={{ width: 120 }} value={feeType} onChange={(e) => setFeeType(e.target.value as 'flat' | 'percent')}>
              <option value="flat">Flat ($)</option>
              <option value="percent">Percent (%)</option>
            </select>
            <input className="search-input" style={{ flex: 1 }} value={value} onChange={(e) => setValue(e.target.value)} />
          </div>
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
