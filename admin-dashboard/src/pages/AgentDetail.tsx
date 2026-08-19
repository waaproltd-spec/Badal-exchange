import { useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { StatusBadge } from '../components/StatusBadge';
import { useFetch } from '../hooks/useFetch';
import { getAgentDevices, getAgentTransactions } from '../api/endpoints';
import { money, dateTime, methodLabel } from '../lib/format';

type Tab = 'transactions' | 'devices';

export function AgentDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [tab, setTab] = useState<Tab>('transactions');

  const tx = useFetch(() => getAgentTransactions(id!), [id]);
  const devices = useFetch(() => getAgentDevices(id!), [id]);

  return (
    <Page title="Agent detail">
      <button className="breadcrumb-back" onClick={() => navigate('/agents')}>
        ← Back to agents
      </button>

      <div className="tabs">
        <button className={`tab ${tab === 'transactions' ? 'active' : ''}`} onClick={() => setTab('transactions')}>
          Transactions
        </button>
        <button className={`tab ${tab === 'devices' ? 'active' : ''}`} onClick={() => setTab('devices')}>
          Devices
        </button>
      </div>

      {tab === 'transactions' && (
        <div className="card">
          {tx.loading && <Loading />}
          {tx.error && <ErrorState message={tx.error} />}
          {tx.data && tx.data.length === 0 && <EmptyState message="No transactions handled by this agent yet." />}
          {tx.data && tx.data.length > 0 && (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Order</th>
                    <th>Direction</th>
                    <th>Method</th>
                    <th>Status</th>
                    <th>Amount</th>
                    <th>Fee</th>
                    <th>Created</th>
                  </tr>
                </thead>
                <tbody>
                  {tx.data.map((o) => (
                    <tr key={o.id} className="clickable" onClick={() => navigate(`/orders/${o.id}`)}>
                      <td className="mono">{o.orderCode}</td>
                      <td className="text-secondary" style={{ textTransform: 'capitalize' }}>
                        {o.direction}
                      </td>
                      <td>{methodLabel(o.method)}</td>
                      <td>
                        <StatusBadge status={o.status} />
                      </td>
                      <td>{money(o.amount)}</td>
                      <td>{money(o.fee)}</td>
                      <td className="text-secondary">{dateTime(o.createdAt)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {tab === 'devices' && (
        <div className="card">
          {devices.loading && <Loading />}
          {devices.error && <ErrorState message={devices.error} />}
          {devices.data && devices.data.length === 0 && <EmptyState message="No registered devices for this agent." />}
          {devices.data && devices.data.length > 0 && (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Device</th>
                    <th>Label</th>
                    <th>Status</th>
                    <th>Registered</th>
                    <th>Last seen</th>
                  </tr>
                </thead>
                <tbody>
                  {devices.data.map((d) => (
                    <tr key={d.device_id}>
                      <td className="mono">{d.device_id}</td>
                      <td className="text-secondary">{d.device_label ?? '—'}</td>
                      <td>
                        <StatusBadge status={d.status} />
                      </td>
                      <td className="text-secondary">{dateTime(d.registered_at)}</td>
                      <td className="text-secondary">{dateTime(d.last_seen_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </Page>
  );
}
