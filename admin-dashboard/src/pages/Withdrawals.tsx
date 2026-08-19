import { useState } from 'react';
import { Page } from '../components/Page';
import { OrdersTable } from '../components/OrdersTable';
import { StatusFilter } from '../components/StatusFilter';
import { useFetch } from '../hooks/useFetch';
import { listWithdrawals } from '../api/endpoints';
import type { OrderStatus } from '../api/types';

export function Withdrawals() {
  const [status, setStatus] = useState<OrderStatus | ''>('');
  const { data, loading, error } = useFetch(() => listWithdrawals(status || undefined), [status]);

  return (
    <Page title="Withdrawals" subtitle="Payouts from customer wallets to EVC Plus / WinWin" actions={<StatusFilter value={status} onChange={setStatus} />}>
      <OrdersTable data={data} loading={loading} error={error} showDirection={false} />
    </Page>
  );
}
