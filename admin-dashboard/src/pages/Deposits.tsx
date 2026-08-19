import { useState } from 'react';
import { Page } from '../components/Page';
import { OrdersTable } from '../components/OrdersTable';
import { StatusFilter } from '../components/StatusFilter';
import { useFetch } from '../hooks/useFetch';
import { listDeposits } from '../api/endpoints';
import type { OrderStatus } from '../api/types';

export function Deposits() {
  const [status, setStatus] = useState<OrderStatus | ''>('');
  const { data, loading, error } = useFetch(() => listDeposits(status || undefined), [status]);

  return (
    <Page title="Deposits" subtitle="EVC Plus and WinWin deposits into customer wallets" actions={<StatusFilter value={status} onChange={setStatus} />}>
      <OrdersTable data={data} loading={loading} error={error} showDirection={false} />
    </Page>
  );
}
