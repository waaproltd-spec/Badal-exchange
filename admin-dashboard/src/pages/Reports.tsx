import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { StatusBadge } from '../components/StatusBadge';
import { useFetch } from '../hooks/useFetch';
import { getDailyReports } from '../api/endpoints';
import { money, dateOnly, methodLabel } from '../lib/format';

export function Reports() {
  const { data, loading, error } = useFetch(() => getDailyReports(), []);

  return (
    <Page title="Reports" subtitle="Daily order volume for the last 30 days, grouped by direction, method and status">
      <div className="card">
        {loading && <Loading />}
        {error && <ErrorState message={error} />}
        {data && data.length === 0 && <EmptyState message="No order activity in the last 30 days." />}
        {data && data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Day</th>
                  <th>Direction</th>
                  <th>Method</th>
                  <th>Status</th>
                  <th>Count</th>
                  <th>Amount</th>
                </tr>
              </thead>
              <tbody>
                {data.map((r, i) => (
                  <tr key={i}>
                    <td>{dateOnly(r.day)}</td>
                    <td className="text-secondary" style={{ textTransform: 'capitalize' }}>
                      {r.direction}
                    </td>
                    <td>{methodLabel(r.method)}</td>
                    <td>
                      <StatusBadge status={r.status} />
                    </td>
                    <td>{r.count}</td>
                    <td>{money(r.amount)}</td>
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
