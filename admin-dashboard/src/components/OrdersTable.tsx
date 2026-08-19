import { useNavigate } from 'react-router-dom';
import { Loading, ErrorState, EmptyState } from './AsyncState';
import { StatusBadge } from './StatusBadge';
import { money, dateTime, methodLabel } from '../lib/format';
import type { Order } from '../api/types';

export function OrdersTable({
  data,
  loading,
  error,
  showDirection = true,
}: {
  data: Order[] | null;
  loading: boolean;
  error: string | null;
  showDirection?: boolean;
}) {
  const navigate = useNavigate();

  return (
    <div className="card">
      {loading && <Loading />}
      {error && <ErrorState message={error} />}
      {data && data.length === 0 && <EmptyState message="No orders found." />}
      {data && data.length > 0 && (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Order</th>
                {showDirection && <th>Direction</th>}
                <th>Method</th>
                <th>Status</th>
                <th>Amount</th>
                <th>Fee</th>
                <th>Net</th>
                <th>Counterparty</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              {data.map((o) => (
                <tr key={o.id} className="clickable" onClick={() => navigate(`/orders/${o.id}`)}>
                  <td className="mono">{o.orderCode}</td>
                  {showDirection && (
                    <td className="text-secondary" style={{ textTransform: 'capitalize' }}>
                      {o.direction}
                    </td>
                  )}
                  <td>{methodLabel(o.method)}</td>
                  <td>
                    <StatusBadge status={o.status} />
                  </td>
                  <td>{money(o.amount)}</td>
                  <td className="text-secondary">{money(o.fee)}</td>
                  <td>{money(o.netAmount)}</td>
                  <td className="mono">{o.phoneNumber ?? o.winwinId ?? '—'}</td>
                  <td className="text-secondary">{dateTime(o.createdAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
