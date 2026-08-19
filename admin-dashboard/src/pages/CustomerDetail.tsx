import { useNavigate, useParams } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState } from '../components/AsyncState';
import { StatusBadge } from '../components/StatusBadge';
import { useFetch } from '../hooks/useFetch';
import { getCustomer } from '../api/endpoints';
import { money, dateTime } from '../lib/format';

export function CustomerDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { data, loading, error } = useFetch(() => getCustomer(id!), [id]);

  return (
    <Page title="Customer detail">
      <button className="breadcrumb-back" onClick={() => navigate('/customers')}>
        ← Back to customers
      </button>

      {loading && <Loading />}
      {error && <ErrorState message={error} />}

      {data && (
        <>
          <div className="card card-pad">
            <div className="row-between" style={{ marginBottom: 18 }}>
              <div>
                <h3 style={{ fontSize: 17, fontWeight: 650 }}>{data.name ?? 'Unnamed customer'}</h3>
                <div className="text-secondary mono" style={{ marginTop: 4 }}>
                  {data.phone ?? '—'}
                </div>
              </div>
              <StatusBadge status={data.status} />
            </div>
            <div className="detail-grid">
              <div className="detail-item">
                <span className="detail-label">Registered</span>
                <span className="detail-value">{dateTime(data.registeredAt)}</span>
              </div>
              <div className="detail-item">
                <span className="detail-label">Customer ID</span>
                <span className="detail-value mono" style={{ fontWeight: 500 }}>
                  {data.id}
                </span>
              </div>
            </div>
          </div>

          <div className="card card-pad">
            <h3 style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 16 }}>Wallet</h3>
            <div className="detail-grid">
              <div className="detail-item">
                <span className="detail-label">Available balance</span>
                <span className="detail-value">{money(data.wallet.availableBalance)}</span>
              </div>
              <div className="detail-item">
                <span className="detail-label">Pending balance</span>
                <span className="detail-value">{money(data.wallet.pendingBalance)}</span>
              </div>
              <div className="detail-item">
                <span className="detail-label">Total deposited</span>
                <span className="detail-value">{money(data.wallet.totalDeposit)}</span>
              </div>
              <div className="detail-item">
                <span className="detail-label">Total withdrawn</span>
                <span className="detail-value">{money(data.wallet.totalWithdraw)}</span>
              </div>
            </div>
            <button className="btn btn-sm" style={{ marginTop: 16 }} onClick={() => navigate(`/wallets/${data.id}`)}>
              View ledger
            </button>
          </div>
        </>
      )}
    </Page>
  );
}
