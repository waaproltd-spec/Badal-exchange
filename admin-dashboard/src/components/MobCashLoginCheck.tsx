import { useState, type FormEvent } from 'react';
import { checkMobCashLogin, updateIntegrationCredentials } from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';

/**
 * Real login verification against MobCash Business Web: the admin types
 * credentials, we attempt an actual browser-automation login (never
 * fabricated), and on success show whichever EPOS accounts the real
 * portal reports -- including the real "No available EPOSes" empty state.
 * This does not replace the existing encrypted credential storage; on a
 * successful login it also saves the verified credentials via the same
 * update-credentials endpoint the form above uses.
 */
export function MobCashLoginCheck({ onSaved }: { onSaved: () => void }) {
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<'form' | 'epos'>('form');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [rememberMe, setRememberMe] = useState(true);
  const [validationError, setValidationError] = useState<string | null>(null);
  const [apiError, setApiError] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);
  const [eposList, setEposList] = useState<string[]>([]);

  function reset() {
    setStep('form');
    setUsername('');
    setPassword('');
    setValidationError(null);
    setApiError(null);
    setEposList([]);
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setValidationError(null);
    setApiError(null);

    if (!username.trim() || !password.trim()) {
      setValidationError('Username and password are both required.');
      return;
    }

    setChecking(true);
    try {
      const result = await checkMobCashLogin(username.trim(), password);
      if (!result.success) {
        setApiError(result.message);
        return;
      }
      // Verified working -- persist as the configured credentials.
      await updateIntegrationCredentials('mobcash_winwin', { username: username.trim(), password });
      setEposList(result.eposList);
      setStep('epos');
      onSaved();
    } catch (err) {
      setApiError(err instanceof ApiRequestError ? err.message : 'Could not reach MobCash. Try again.');
    } finally {
      setChecking(false);
    }
  }

  if (!open) {
    return (
      <div className="card card-pad">
        <button className="btn" onClick={() => setOpen(true)}>
          Verify MobCash login
        </button>
      </div>
    );
  }

  return (
    <div className="mobcash-shell">
      {step === 'form' && (
        <form className="mobcash-card" onSubmit={handleSubmit}>
          <div className="mobcash-brand">
            <div className="mobcash-logo">
              <svg width="34" height="34" viewBox="0 0 24 24" fill="none">
                <path
                  d="M4 8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v1a1.5 1.5 0 0 0 0 3v1a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-1a1.5 1.5 0 0 0 0-3V8Z"
                  fill="currentColor"
                />
                <line x1="12" y1="6" x2="12" y2="9" stroke="#12131a" strokeWidth="1.6" strokeLinecap="round" />
                <line x1="12" y1="10.6" x2="12" y2="13.4" stroke="#12131a" strokeWidth="1.6" strokeLinecap="round" />
                <line x1="12" y1="15" x2="12" y2="18" stroke="#12131a" strokeWidth="1.6" strokeLinecap="round" />
              </svg>
            </div>
            <div className="mobcash-title">MobCash</div>
            <div className="mobcash-sub">Make money with us</div>
          </div>

          <div className="field">
            <label htmlFor="mc-username">Username</label>
            <input
              id="mc-username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="Enter username"
              autoComplete="off"
            />
          </div>

          <div className="field">
            <label htmlFor="mc-password">Password</label>
            <div className="mobcash-password-row">
              <input
                id="mc-password"
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="Enter password"
                autoComplete="off"
              />
              <button
                type="button"
                className="mobcash-eye"
                onClick={() => setShowPassword((v) => !v)}
                aria-label={showPassword ? 'Hide password' : 'Show password'}
              >
                {showPassword ? '🙈' : '👁'}
              </button>
            </div>
          </div>

          <label className="mobcash-remember">
            <input type="checkbox" checked={rememberMe} onChange={(e) => setRememberMe(e.target.checked)} />
            Remember me
          </label>

          {validationError && <div className="error-banner">{validationError}</div>}
          {apiError && <div className="error-banner">{apiError}</div>}

          <button type="submit" className="btn btn-primary mobcash-login-btn" disabled={checking}>
            {checking ? <span className="spinner" /> : null}
            {checking ? 'Logging in…' : 'Log in'}
          </button>

          <button type="button" className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => { setOpen(false); reset(); }}>
            Cancel
          </button>
        </form>
      )}

      {step === 'epos' && (
        <div className="mobcash-card">
          <div className="mobcash-epos-title">Select your EPOS</div>

          {eposList.length === 0 ? (
            <div className="mobcash-epos-empty">
              <div className="mobcash-epos-empty-icon">✕</div>
              <div className="mobcash-epos-empty-title">List of EPOSes</div>
              <div className="mobcash-epos-empty-sub">No available EPOSes</div>
            </div>
          ) : (
            <ul className="mobcash-epos-list">
              {eposList.map((name, i) => (
                <li key={i}>{name}</li>
              ))}
            </ul>
          )}

          <button
            type="button"
            className="btn btn-primary mobcash-login-btn"
            onClick={() => {
              setOpen(false);
              reset();
            }}
          >
            Close
          </button>
        </div>
      )}
    </div>
  );
}
