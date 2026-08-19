import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { Page } from '../components/Page';
import { Loading, ErrorState, EmptyState } from '../components/AsyncState';
import { StatusBadge } from '../components/StatusBadge';
import { useFetch } from '../hooks/useFetch';
import { listAgents, createAgent, enableAgent, disableAgent } from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';
import { dateTime } from '../lib/format';

export function Agents() {
  const navigate = useNavigate();
  const { data, loading, error, reload } = useFetch(() => listAgents(), []);
  const [showForm, setShowForm] = useState(false);

  return (
    <Page
      title="Agents"
      subtitle="Field agents who verify deposits and process withdrawals"
      actions={
        <button className="btn btn-primary" onClick={() => setShowForm((s) => !s)}>
          {showForm ? 'Cancel' : '+ New agent'}
        </button>
      }
    >
      {showForm && <CreateAgentForm onCreated={() => { setShowForm(false); reload(); }} />}

      <div className="card">
        {loading && <Loading />}
        {error && <ErrorState message={error} />}
        {data && data.length === 0 && <EmptyState message="No agents yet." />}
        {data && data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Phone</th>
                  <th>Status</th>
                  <th>Responsibilities</th>
                  <th>Last seen</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {data.map((a) => (
                  <tr key={a.id} className="clickable" onClick={() => navigate(`/agents/${a.id}`)}>
                    <td>{a.name ?? '—'}</td>
                    <td className="mono">{a.phone ?? '—'}</td>
                    <td>
                      <StatusBadge status={a.status} />
                    </td>
                    <td className="text-secondary">{a.responsibilities?.length ? a.responsibilities.join(', ') : '—'}</td>
                    <td className="text-secondary">{dateTime(a.last_seen_at)}</td>
                    <td onClick={(e) => e.stopPropagation()}>
                      <AgentStatusToggle id={a.id} status={a.status} onChanged={reload} />
                    </td>
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

function AgentStatusToggle({ id, status, onChanged }: { id: string; status: string; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);

  async function toggle() {
    setBusy(true);
    try {
      if (status === 'active') await disableAgent(id);
      else await enableAgent(id);
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <button className={`btn btn-sm ${status === 'active' ? 'btn-danger' : ''}`} disabled={busy} onClick={toggle}>
      {busy ? '…' : status === 'active' ? 'Disable' : 'Enable'}
    </button>
  );
}

function CreateAgentForm({ onCreated }: { onCreated: () => void }) {
  const [phone, setPhone] = useState('');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [responsibilities, setResponsibilities] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await createAgent({
        phone: phone.trim(),
        name: name.trim(),
        password,
        responsibilities: responsibilities
          .split(',')
          .map((r) => r.trim())
          .filter(Boolean),
      });
      setPhone('');
      setName('');
      setPassword('');
      setResponsibilities('');
      onCreated();
    } catch (err) {
      setError(err instanceof ApiRequestError ? err.message : 'Failed to create agent.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="card card-pad">
      <h3 style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 16 }}>New agent</h3>
      <form onSubmit={handleSubmit} className="stack" style={{ gap: 14 }}>
        <div className="grid grid-2">
          <div className="field">
            <label htmlFor="agent-name">Full name</label>
            <input id="agent-name" value={name} onChange={(e) => setName(e.target.value)} required />
          </div>
          <div className="field">
            <label htmlFor="agent-phone">Phone number</label>
            <input id="agent-phone" value={phone} onChange={(e) => setPhone(e.target.value)} required />
          </div>
          <div className="field">
            <label htmlFor="agent-password">Temporary password</label>
            <input
              id="agent-password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              minLength={8}
              required
            />
          </div>
          <div className="field">
            <label htmlFor="agent-resp">Responsibilities (comma separated)</label>
            <input
              id="agent-resp"
              placeholder="evc_deposit, evc_withdraw"
              value={responsibilities}
              onChange={(e) => setResponsibilities(e.target.value)}
            />
          </div>
        </div>
        {error && <div className="error-banner">{error}</div>}
        <div>
          <button type="submit" className="btn btn-primary" disabled={submitting}>
            {submitting ? 'Creating…' : 'Create agent'}
          </button>
        </div>
      </form>
    </div>
  );
}
