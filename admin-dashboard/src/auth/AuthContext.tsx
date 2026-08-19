import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { adminLogin } from '../api/endpoints';
import { getAccessToken, setTokens, setUnauthorizedHandler, ApiRequestError } from '../api/client';
import type { AdminUser } from '../api/types';

const USER_KEY = 'badal_admin_user';

interface AuthContextValue {
  user: AdminUser | null;
  isAuthenticated: boolean;
  loading: boolean;
  login: (phone: string, password: string) => Promise<void>;
  logout: () => void;
}

const AuthContext = createContext<AuthContextValue | null>(null);

function loadStoredUser(): AdminUser | null {
  const raw = localStorage.getItem(USER_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as AdminUser;
  } catch {
    return null;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<AdminUser | null>(() => (getAccessToken() ? loadStoredUser() : null));
  const [loading, setLoading] = useState(false);

  const logout = useCallback(() => {
    setTokens(null);
    localStorage.removeItem(USER_KEY);
    setUser(null);
  }, []);

  useEffect(() => {
    setUnauthorizedHandler(() => {
      localStorage.removeItem(USER_KEY);
      setUser(null);
    });
  }, []);

  const login = useCallback(async (phone: string, password: string) => {
    setLoading(true);
    try {
      const res = await adminLogin(phone, password);
      setTokens({ accessToken: res.accessToken, refreshToken: res.refreshToken });
      localStorage.setItem(USER_KEY, JSON.stringify(res.user));
      setUser(res.user);
    } finally {
      setLoading(false);
    }
  }, []);

  const value = useMemo(
    () => ({ user, isAuthenticated: !!user, loading, login, logout }),
    [user, loading, login, logout]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}

export { ApiRequestError };
