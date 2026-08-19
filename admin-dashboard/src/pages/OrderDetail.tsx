import { useNavigate, useParams } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState } from '../components/AsyncState';
import { StatusBadge } from '../components/StatusBadge';
import { useFetch } from '../hooks/useFetch';
import { getOrder } from '../api/endpoints';
import { money, dateTime, methodLabel } from '../lib/format';

export function OrderDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { data, loading, error } = useFetch(() => getOrder(id!), [id]);

  return (
    <Page title="Order detail">
      <button className="breadcrumb-back" onClick={() => navigate(-1)}>
        ← Back
      </button>

      {loading && <Loading />}
      {error && <ErrorState message={error} />}

      {data && (
        <div className="card card-pad">
          <div className="row-between" style={{ marginBottom: 18 }}>
            <div>
              <h3 style={{ fontSize: 17, fontWeight: 650 }} className="mono">
                {data.orderCode}
              </h3>
              <div className="text-secondary" style={{ marginTop: 4, textTransform: 'capitalize' }}>
                {data.direction} · {methodLabel(data.method)}
              </div>
            </div>
            <StatusBadge status={data.status} />
          </div>
          <div className="detail-grid">
            <div className="detail-item">
              <span className="detail-label">Amount</span>
              <span className="detail-value">{money(data.amount)}</span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Fee</span>
              <span className="detail-value">{money(data.fee)}</span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Net amount</span>
              <span className="detail-value">{money(data.netAmount)}</span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Transaction ref</span>
              <span className="detail-value mono" style={{ fontWeight: 500 }}>
                {data.transactionRef ?? '—'}
              </span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Customer</span>
              <span
                className="detail-value mono"
                style={{ fontWeight: 500, cursor: 'pointer' }}
                onClick={() => navigate(`/customers/${data.customerId}`)}
              >
                {data.customerId}
              </span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Agent</span>
              <span
                className="detail-value mono"
                style={{ fontWeight: 500, cursor: data.agentId ? 'pointer' : 'default' }}
                onClick={() => data.agentId && navigate(`/agents/${data.agentId}`)}
              >
                {data.agentId ?? '— unassigned —'}
              </span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Counterparty (phone / WinWin ID)</span>
              <span className="detail-value mono" style={{ fontWeight: 500 }}>
                {data.phoneNumber ?? data.winwinId ?? '—'}
              </span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Created</span>
              <span className="detail-value">{dateTime(data.createdAt)}</span>
            </div>
            <div className="detail-item">
              <span className="detail-label">Completed</span>
              <span className="detail-value">{dateTime(data.completedAt)}</span>
            </div>
          </div>
        </div>
      )}
    </Page>
  );
}
