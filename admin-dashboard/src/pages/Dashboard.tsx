import { Page } from '../components/Page';
import { StatCard } from '../components/StatCard';
import { Loading, ErrorState } from '../components/AsyncState';
import { useFetch } from '../hooks/useFetch';
import { getDashboardSummary } from '../api/endpoints';
import { money } from '../lib/format';

export function Dashboard() {
  const { data, loading, error } = useFetch(() => getDashboardSummary(), []);

  return (
    <Page title="Dashboard" subtitle="Live overview of Badal Exchange activity">
      {loading && <Loading />}
      {error && <ErrorState message={error} />}
      {data && (
        <>
          <div className="grid grid-stats">
            <StatCard label="Total customers" value={data.totalCustomers.toLocaleString()} />
            <StatCard label="Total wallet balance" value={money(data.totalWalletBalance)} hint={`Pending: ${money(data.totalWalletPending)}`} />
            <StatCard label="Today's deposits" value={money(data.todaysDeposits)} />
            <StatCard label="Today's withdrawals" value={money(data.todaysWithdrawals)} />
          </div>
          <div className="grid grid-stats">
            <StatCard label="Pending deposits" value={data.pendingDeposits.toLocaleString()} />
            <StatCard label="Pending withdrawals" value={data.pendingWithdrawals.toLocaleString()} />
            <StatCard label="Completed transactions" value={data.completedTransactions.toLocaleString()} />
            <StatCard label="Failed transactions" value={data.failedTransactions.toLocaleString()} />
          </div>
        </>
      )}
    </Page>
  );
}
