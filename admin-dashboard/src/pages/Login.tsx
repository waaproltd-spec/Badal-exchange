import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth, ApiRequestError } from '../auth/AuthContext';

export function Login() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const [phone, setPhone] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await login(phone, password);
      navigate('/', { replace: true });
    } catch (err) {
      if (err instanceof ApiRequestError) setError(err.message);
      else setError('Unable to sign in. Please try again.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="login-shell">
      <div className="login-card">
        <div className="login-brand">
          <div className="login-mark">BX</div>
          <div className="login-title">Badal Exchange</div>
          <div className="login-sub">Admin / Manager Dashboard</div>
        </div>

        <form className="login-form" onSubmit={handleSubmit}>
          <div className="field">
            <label htmlFor="phone">Phone number</label>
            <input
              id="phone"
              type="text"
              inputMode="tel"
              autoComplete="tel"
              placeholder="2526XXXXXXXX"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
              required
            />
          </div>
          <div className="field">
            <label htmlFor="password">Password</label>
            <input
              id="password"
              type="password"
              autoComplete="current-password"
              placeholder="••••••••"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>

          {error && <div className="error-banner">{error}</div>}

          <button type="submit" className="btn btn-primary" disabled={submitting} style={{ marginTop: 4 }}>
            {submitting ? <span className="spinner" /> : null}
            {submitting ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
      </div>
    </div>
  );
}
