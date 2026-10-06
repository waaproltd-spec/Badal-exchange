import { Request, Response, NextFunction } from 'express';
import { verifyAccessToken, Role } from './jwt';
import { ApiError } from '../lib/errors';
import { pool } from '../db/pool';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: { id: string; role: Role };
    }
  }
}

export function requireAuth(req: Request, _res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    return next(ApiError.unauthorized('Missing bearer token'));
  }
  try {
    const payload = verifyAccessToken(header.slice('Bearer '.length));
    if (payload.status !== 'active') {
      return next(ApiError.forbidden('Account is disabled'));
    }
    req.user = { id: payload.sub, role: payload.role };
    next();
  } catch {
    next(ApiError.unauthorized('Invalid or expired token'));
  }
}

export function requireRole(...roles: Role[]) {
  return (req: Request, _res: Response, next: NextFunction) => {
    if (!req.user) return next(ApiError.unauthorized());
    if (!roles.includes(req.user.role)) return next(ApiError.forbidden());
    next();
  };
}

/** Agent responsibility that grants access to every management function. */
export const MANAGE_SETTINGS = 'manage_settings';

/**
 * Management (formerly admin-dashboard-only) endpoints. Allowed for admin
 * accounts, and for agents an admin or another manager granted the
 * 'manage_settings' responsibility -- the Agent App is the management
 * interface. Checked against the database on every request, so revoking
 * the responsibility (or disabling the agent) takes effect immediately.
 */
export const requireManagement = (req: Request, _res: Response, next: NextFunction) => {
  if (!req.user) return next(ApiError.unauthorized());
  if (req.user.role === 'admin') return next();
  if (req.user.role !== 'agent') return next(ApiError.forbidden());
  pool
    .query(
      `SELECT ap.responsibilities, u.status FROM agent_profiles ap JOIN users u ON u.id = ap.user_id WHERE ap.user_id = $1`,
      [req.user.id]
    )
    .then(({ rows }) => {
      const row = rows[0];
      const responsibilities: string[] = row?.responsibilities ?? [];
      if (!row || row.status !== 'active' || !responsibilities.includes(MANAGE_SETTINGS)) {
        return next(ApiError.forbidden('Your account is not allowed to manage settings. Ask an admin for access.'));
      }
      next();
    })
    .catch(next);
};
