import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { useFetch } from '../hooks/useFetch';
import { listAuditLogs } from '../api/endpoints';
import { dateTime, titleCase } from '../lib/format';

export function AuditLogs() {
  const { data, loading, error } = useFetch(() => listAuditLogs(), []);

  return (
    <Page title="Audit Logs" subtitle="Every admin/agent mutation and wallet-affecting state transition">
      <div className="card">
        {loading && <Loading />}
        {error && <ErrorState message={error} />}
        {data && data.length === 0 && <EmptyState message="No audit events recorded yet." />}
        {data && data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Action</th>
                  <th>Entity</th>
                  <th>Actor</th>
                  <th>Details</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                {data.map((log) => (
                  <tr key={log.id}>
                    <td>{titleCase(log.action)}</td>
                    <td className="text-secondary">
                      {log.entity_type}
                      {log.entity_id ? <span className="mono"> · {log.entity_id.slice(0, 8)}</span> : null}
                    </td>
                    <td className="text-secondary" style={{ textTransform: 'capitalize' }}>
                      {log.actor_role ?? '—'}
                      {log.actor_id ? <span className="mono"> · {log.actor_id.slice(0, 8)}</span> : null}
                    </td>
                    <td>
                      {log.after_json || log.before_json ? (
                        <details>
                          <summary style={{ cursor: 'pointer', color: 'var(--text-secondary)', fontSize: 12.5 }}>view</summary>
                          <pre
                            className="mono"
                            style={{
                              whiteSpace: 'pre-wrap',
                              wordBreak: 'break-all',
                              maxWidth: 360,
                              marginTop: 6,
                            }}
                          >
                            {JSON.stringify({ before: log.before_json, after: log.after_json }, null, 2)}
                          </pre>
                        </details>
                      ) : (
                        <span className="text-muted">—</span>
                      )}
                    </td>
                    <td className="text-secondary">{dateTime(log.created_at)}</td>
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
