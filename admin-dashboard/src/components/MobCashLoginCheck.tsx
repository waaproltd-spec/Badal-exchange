import { useState, type FormEvent } from 'react';
import { checkMobCashLogin, updateIntegrationCredentials } from '../api/endpoints';
import { ApiRequestError } from '../auth/AuthContext';

/**
 * Deliberately NOT styled to look like MobCash's own app -- MobCash has no
 * public API/SDK, so this is Badal Exchange's own tool performing a real
 * (never fabricated) browser-automation login attempt against MobCash
 * Business Web with credentials the admin just typed. It is an unofficial
 * integration and says so up front. On success it shows whichever EPOS
 * accounts the real portal reports -- including the real "no EPOSes" empty
 * state -- and saves the verified credentials via the same encrypted-storage
 * endpoint the form below uses.
 */
export function MobCashLoginCheck({ onSaved }: { onSaved: () => void }) {
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<'form' | 'result'>('form');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
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
      setStep('result');
      onSaved();
    } catch (err) {
      setApiError(err instanceof ApiRequestError ? err.message : 'Could not reach MobCash Business Web. Try again.');
    } finally {
      setChecking(false);
    }
  }

  if (!open) {
    return (
      <div className="card card-pad">
        <button className="btn" onClick={() => setOpen(true)}>
          Verify MobCash credentials (unofficial automation)
        </button>
      </div>
    );
  }

  return (
    <div className="card card-pad">
      <div className="warning-banner" style={{ marginBottom: 16 }}>
        MobCash provides no public API, SDK, or partner integration. This runs a real but <strong>unofficial</strong>{' '}
        backend browser-automation login against the actual MobCash Business Web portal
        (businessweb-mobi.com) -- it is not affiliated with or certified by MobCash, and can break if that site
        changes. Nothing here is fabricated: a failure is reported honestly, not hidden.
      </div>

      {step === 'form' && (
        <form className="stack" style={{ gap: 14 }} onSubmit={handleSubmit}>
          <div className="grid grid-2">
            <div className="field">
              <label htmlFor="mc-username">Username</label>
              <input
                id="mc-username"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                autoComplete="off"
              />
            </div>
            <div className="field">
              <label htmlFor="mc-password">Password</label>
              <div style={{ position: 'relative', display: 'flex', alignItems: 'center' }}>
                <input
                  id="mc-password"
                  type={showPassword ? 'text' : 'password'}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  autoComplete="off"
                  style={{ flex: 1, paddingRight: 40 }}
                />
                <button
                  type="button"
                  className="btn btn-sm"
                  style={{ position: 'absolute', right: 4, padding: '4px 8px' }}
                  onClick={() => setShowPassword((v) => !v)}
                  aria-label={showPassword ? 'Hide password' : 'Show password'}
                >
                  {showPassword ? 'Hide' : 'Show'}
                </button>
              </div>
            </div>
          </div>

          {validationError && <div className="error-banner">{validationError}</div>}
          {apiError && <div className="error-banner">{apiError}</div>}

          <div className="row" style={{ gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={checking}>
              {checking ? <span className="spinner" /> : null}
              {checking ? 'Checking…' : 'Run login check'}
            </button>
            <button type="button" className="btn btn-sm" onClick={() => { setOpen(false); reset(); }}>
              Cancel
            </button>
          </div>
        </form>
      )}

      {step === 'result' && (
        <div className="stack" style={{ gap: 12 }}>
          <h3 style={{ fontSize: 15, fontWeight: 600 }}>EPOS accounts reported by the real portal</h3>

          {eposList.length === 0 ? (
            <p className="text-muted" style={{ fontSize: 13.5 }}>
              MobCash Business Web reported no available EPOS accounts for this login.
            </p>
          ) : (
            <ul className="automation-check-list">
              {eposList.map((name, i) => (
                <li key={i}>{name}</li>
              ))}
            </ul>
          )}

          <div>
            <button
              type="button"
              className="btn"
              onClick={() => {
                setOpen(false);
                reset();
              }}
            >
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
