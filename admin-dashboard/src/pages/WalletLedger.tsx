import { useNavigate, useParams } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { useFetch } from '../hooks/useFetch';
import { getWalletLedger } from '../api/endpoints';
import { money, dateTime, titleCase } from '../lib/format';

export function WalletLedger() {
  const { customerId } = useParams<{ customerId: string }>();
  const navigate = useNavigate();
  const { data, loading, error } = useFetch(() => getWalletLedger(customerId!), [customerId]);

  return (
    <Page title="Wallet ledger" subtitle={customerId}>
      <button className="breadcrumb-back" onClick={() => navigate(-1)}>
        ← Back
      </button>

      <div className="card">
        {loading && <Loading />}
        {error && <ErrorState message={error} />}
        {data && data.length === 0 && <EmptyState message="No ledger entries for this wallet yet." />}
        {data && data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Type</th>
                  <th>Amount</th>
                  <th>Balance after</th>
                  <th>Reason</th>
                  <th>Order</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                {data.map((l) => (
                  <tr key={l.id}>
                    <td>{titleCase(l.type)}</td>
                    <td>{money(l.amount)}</td>
                    <td>{money(l.balanceAfter)}</td>
                    <td className="text-secondary">{l.reason}</td>
                    <td>
                      {l.orderId ? (
                        <span className="mono" style={{ cursor: 'pointer' }} onClick={() => navigate(`/orders/${l.orderId}`)}>
                          {l.orderId.slice(0, 8)}
                        </span>
                      ) : (
                        '—'
                      )}
                    </td>
                    <td className="text-secondary">{dateTime(l.createdAt)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </Page>
  );
}
