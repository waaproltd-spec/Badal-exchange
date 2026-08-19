import { Request, Response, NextFunction } from 'express';
import { pool } from '../db/pool';
import { newIdempotencyRequestHash } from './crypto';
import { ApiError } from './errors';
import { asyncHandler } from './asyncHandler';

/**
 * Requires an `Idempotency-Key` header on money-moving endpoints. A retried
 * request with the same key + same body replays the original response
 * instead of re-running the handler (so a flaky network retry from a
 * mobile app can never create a duplicate order or duplicate ledger entry).
 */
export function requireIdempotencyKey(endpoint: string) {
  return asyncHandler(async (req: Request, res: Response, next: NextFunction) => {
    const key = req.header('Idempotency-Key');
    if (!key) {
      throw ApiError.badRequest('Idempotency-Key header is required', 'IDEMPOTENCY_KEY_REQUIRED');
    }
    const requestHash = newIdempotencyRequestHash({ endpoint, userId: req.user?.id, body: req.body });

    const inserted = await pool.query(
      `INSERT INTO idempotency_keys (key, user_id, endpoint, request_hash)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (key) DO NOTHING
       RETURNING key`,
      [key, req.user?.id ?? null, endpoint, requestHash]
    );

    if (inserted.rowCount === 0) {
      const existing = await pool.query(
        'SELECT request_hash, status_code, response_json FROM idempotency_keys WHERE key = $1',
        [key]
      );
      const row = existing.rows[0];
      if (!row || row.request_hash !== requestHash) {
        throw ApiError.conflict('Idempotency-Key was already used with a different request', 'IDEMPOTENCY_KEY_REUSED');
      }
      if (row.status_code === null) {
        throw ApiError.conflict('This request is already being processed', 'REQUEST_IN_PROGRESS');
      }
      res.status(row.status_code).json(row.response_json);
      return;
    }

    // Capture the handler's response and persist it against the key.
    const originalJson = res.json.bind(res);
    res.json = ((body: unknown) => {
      pool
        .query('UPDATE idempotency_keys SET status_code = $1, response_json = $2 WHERE key = $3', [
          res.statusCode,
          JSON.stringify(body),
          key,
        ])
        .catch((err) => console.error('idempotency persist failed', err));
      return originalJson(body);
    }) as typeof res.json;

    next();
  });
}
