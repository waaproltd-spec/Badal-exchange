import { useNavigate } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { useFetch } from '../hooks/useFetch';
import { listWallets } from '../api/endpoints';
import { money } from '../lib/format';

export function Wallets() {
  const navigate = useNavigate();
  const { data, loading, error } = useFetch(() => listWallets(), []);

  return (
    <Page title="Wallets" subtitle="Customer wallet balances">
      <div className="card">
        {loading && <Loading />}
        {error && <ErrorState message={error} />}
        {data && data.length === 0 && <EmptyState message="No wallets found." />}
        {data && data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Customer</th>
                  <th>Phone</th>
                  <th>Available balance</th>
                  <th>Pending balance</th>
                  <th>Total deposited</th>
                  <th>Total withdrawn</th>
                </tr>
              </thead>
              <tbody>
                {data.map((w) => (
                  <tr key={w.customerId} className="clickable" onClick={() => navigate(`/wallets/${w.customerId}`)}>
                    <td>{w.name ?? '—'}</td>
                    <td className="mono">{w.phone ?? '—'}</td>
                    <td>{money(w.availableBalance)}</td>
                    <td className="text-secondary">{money(w.pendingBalance)}</td>
                    <td className="text-secondary">{money(w.totalDeposit)}</td>
                    <td className="text-secondary">{money(w.totalWithdraw)}</td>
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
