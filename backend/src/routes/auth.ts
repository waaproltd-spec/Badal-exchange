import { Router } from 'express';
import { z } from 'zod';
import { pool, withTransaction } from '../db/pool';
import { asyncHandler } from '../lib/asyncHandler';
import { ApiError } from '../lib/errors';
import { hashPassword, verifyPassword } from '../lib/crypto';
import { signAccessToken, generateRefreshToken, hashRefreshToken, refreshTtlMs, Role } from '../auth/jwt';
import { authLimiter } from '../auth/rateLimit';
import { writeAudit } from '../lib/audit';

export const authRouter = Router();

async function issueTokens(userId: string, role: Role, status: 'active' | 'disabled') {
  const access = signAccessToken({ sub: userId, role, status });
  const { token: refresh, hash } = generateRefreshToken();
  const expiresAt = new Date(Date.now() + refreshTtlMs());
  await pool.query(
    'INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)',
    [userId, hash, expiresAt]
  );
  return { accessToken: access, refreshToken: refresh };
}

const registerSchema = z.object({
  phone: z.string().min(6).max(20),
  name: z.string().min(1).max(100),
  password: z.string().min(8).max(72),
});

authRouter.post(
  '/customer/register',
  authLimiter,
  asyncHandler(async (req, res) => {
    const body = registerSchema.parse(req.body);
    const passwordHash = await hashPassword(body.password);

    const user = await withTransaction(async (client) => {
      const existing = await client.query('SELECT 1 FROM users WHERE phone = $1', [body.phone]);
      if (existing.rows[0]) throw ApiError.conflict('Phone number already registered', 'PHONE_TAKEN');

      const { rows } = await client.query(
        `INSERT INTO users (role, phone, name, password_hash) VALUES ('customer', $1, $2, $3) RETURNING id, role, status`,
        [body.phone, body.name, passwordHash]
      );
      const created = rows[0];
      await client.query('INSERT INTO wallets (customer_id) VALUES ($1)', [created.id]);
      await writeAudit(
        { actorId: created.id, actorRole: 'customer', action: 'user.register', entityType: 'user', entityId: created.id },
        client
      );
      return created;
    });

    const tokens = await issueTokens(user.id, 'customer', user.status);
    res.status(201).json({ user: { id: user.id, role: user.role }, ...tokens });
  })
);

const loginSchema = z.object({
  phone: z.string().optional(),
  email: z.string().optional(),
  password: z.string(),
});

function makeLoginHandler(role: Role) {
  return asyncHandler(async (req: any, res: any) => {
    const body = loginSchema.parse(req.body);
    if (!body.phone && !body.email) throw ApiError.badRequest('phone or email is required');

    const { rows } = await pool.query(
      `SELECT * FROM users WHERE role = $1 AND (phone = $2 OR email = $3) LIMIT 1`,
      [role, body.phone ?? null, body.email ?? null]
    );
    const user = rows[0];
    if (!user) throw ApiError.unauthorized('Invalid credentials');

    const ok = await verifyPassword(body.password, user.password_hash);
    if (!ok) throw ApiError.unauthorized('Invalid credentials');
    if (user.status !== 'active') throw ApiError.forbidden('Account is disabled');

    const tokens = await issueTokens(user.id, role, user.status);
    await writeAudit({ actorId: user.id, actorRole: role, action: 'user.login', entityType: 'user', entityId: user.id });
    res.json({ user: { id: user.id, role, name: user.name }, ...tokens });
  });
}

authRouter.post('/customer/login', authLimiter, makeLoginHandler('customer'));
authRouter.post('/agent/login', authLimiter, makeLoginHandler('agent'));
authRouter.post('/admin/login', authLimiter, makeLoginHandler('admin'));

const refreshSchema = z.object({ refreshToken: z.string() });

authRouter.post(
  '/refresh',
  authLimiter,
  asyncHandler(async (req, res) => {
    const body = refreshSchema.parse(req.body);
    const hash = hashRefreshToken(body.refreshToken);
    const { rows } = await pool.query(
      `SELECT rt.*, u.role, u.status FROM refresh_tokens rt
       JOIN users u ON u.id = rt.user_id
       WHERE rt.token_hash = $1`,
      [hash]
    );
    const row = rows[0];
    if (!row || row.revoked_at || new Date(row.expires_at) < new Date()) {
      throw ApiError.unauthorized('Invalid or expired refresh token');
    }
    // rotate: revoke old, issue new
    await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE id = $1', [row.id]);
    const tokens = await issueTokens(row.user_id, row.role, row.status);
    res.json(tokens);
  })
);

authRouter.post(
  '/logout',
  asyncHandler(async (req, res) => {
    const body = refreshSchema.safeParse(req.body);
    if (body.success) {
      const hash = hashRefreshToken(body.data.refreshToken);
      await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE token_hash = $1', [hash]);
    }
    res.status(204).send();
  })
);
