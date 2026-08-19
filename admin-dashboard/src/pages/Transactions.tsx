import { useNavigate } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { useFetch } from '../hooks/useFetch';
import { listTransactions } from '../api/endpoints';
import { money, dateTime, titleCase } from '../lib/format';

export function Transactions() {
  const navigate = useNavigate();
  const { data, loading, error } = useFetch(() => listTransactions(), []);

  return (
    <Page title="Transactions" subtitle="Full wallet ledger across all customers">
      <div className="card">
        {loading && <Loading />}
        {error && <ErrorState message={error} />}
        {data && data.length === 0 && <EmptyState message="No transactions yet." />}
        {data && data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Type</th>
                  <th>Amount</th>
                  <th>Balance after</th>
                  <th>Reason</th>
                  <th>Customer</th>
                  <th>Order</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                {data.map((t) => (
                  <tr key={t.id}>
                    <td>{titleCase(t.type)}</td>
                    <td>{money(t.amount)}</td>
                    <td>{money(t.balanceAfter)}</td>
                    <td className="text-secondary">{t.reason}</td>
                    <td>
                      <span className="mono" style={{ cursor: 'pointer' }} onClick={() => navigate(`/customers/${t.customerId}`)}>
                        {t.customerId.slice(0, 8)}
                      </span>
                    </td>
                    <td>
                      {t.orderId ? (
                        <span className="mono" style={{ cursor: 'pointer' }} onClick={() => navigate(`/orders/${t.orderId}`)}>
                          {t.orderId.slice(0, 8)}
                        </span>
                      ) : (
                        '—'
                      )}
                    </td>
                    <td className="text-secondary">{dateTime(t.createdAt)}</td>
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
