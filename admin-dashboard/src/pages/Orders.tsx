import { useState } from 'react';
import { Page } from '../components/Page';
import { OrdersTable } from '../components/OrdersTable';
import { StatusFilter } from '../components/StatusFilter';
import { useFetch } from '../hooks/useFetch';
import { listOrders } from '../api/endpoints';
import type { OrderStatus } from '../api/types';

export function Orders() {
  const [status, setStatus] = useState<OrderStatus | ''>('');
  const { data, loading, error } = useFetch(() => listOrders(status || undefined), [status]);

  return (
    <Page title="Orders" subtitle="Every deposit and withdrawal order" actions={<StatusFilter value={status} onChange={setStatus} />}>
      <OrdersTable data={data} loading={loading} error={error} />
    </Page>
  );
}
