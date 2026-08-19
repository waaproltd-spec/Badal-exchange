import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { StatusBadge } from '../components/StatusBadge';
import { useFetch } from '../hooks/useFetch';
import { listCustomers } from '../api/endpoints';
import { money, dateOnly } from '../lib/format';

export function Customers() {
  const [q, setQ] = useState('');
  const [searchTerm, setSearchTerm] = useState('');
  const navigate = useNavigate();
  const { data, loading, error } = useFetch(() => listCustomers(searchTerm || undefined), [searchTerm]);

  return (
    <Page
      title="Customers"
      subtitle="All registered wallet customers"
      actions={
        <input
          className="search-input"
          placeholder="Search by name or phone…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') setSearchTerm(q.trim());
          }}
        />
      }
    >
      <div className="card">
        {loading && <Loading />}
        {error && <ErrorState message={error} />}
        {data && data.length === 0 && <EmptyState message="No customers found." />}
        {data && data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Phone</th>
                  <th>Status</th>
                  <th>Wallet balance</th>
                  <th>Total deposits</th>
                  <th>Total withdrawals</th>
                  <th>Registered</th>
                </tr>
              </thead>
              <tbody>
                {data.map((c) => (
                  <tr key={c.id} className="clickable" onClick={() => navigate(`/customers/${c.id}`)}>
                    <td>{c.name ?? '—'}</td>
                    <td className="mono">{c.phone ?? '—'}</td>
                    <td>
                      <StatusBadge status={c.status} />
                    </td>
                    <td>{money(c.walletBalance)}</td>
                    <td>{money(c.totalDeposits)}</td>
                    <td>{money(c.totalWithdrawals)}</td>
                    <td className="text-secondary">{dateOnly(c.registeredAt)}</td>
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
