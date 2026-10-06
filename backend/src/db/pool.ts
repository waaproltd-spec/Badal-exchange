import fs from 'fs';
import { Pool, PoolClient, PoolConfig } from 'pg';
import { config } from '../config';

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);

/**
 * Resolves SSL settings from DATABASE_SSL rather than from an `sslmode`
 * query param: pg treats `sslmode=require` as full certificate
 * verification, which fails against Supabase's own CA chain.
 */
function buildPoolConfig(): PoolConfig {
  const url = new URL(config.databaseUrl);
  url.searchParams.delete('sslmode');

  let mode = config.databaseSsl;
  if (mode === 'auto') {
    mode = LOCAL_HOSTS.has(url.hostname) ? 'disable' : 'require';
  }

  let ssl: PoolConfig['ssl'] = false;
  if (mode === 'require') {
    ssl = { rejectUnauthorized: false };
  } else if (mode === 'verify') {
    const ca = config.databaseSslCa;
    // Accept either the PEM itself or a path to it.
    ssl = {
      rejectUnauthorized: true,
      ca: ca && !ca.includes('BEGIN CERTIFICATE') ? fs.readFileSync(ca, 'utf8') : ca,
    };
  }

  return {
    connectionString: url.toString(),
    ssl,
    max: config.databasePoolMax,
    idleTimeoutMillis: 30000,
  };
}

export const pool = new Pool(buildPoolConfig());

/** Run `fn` inside a single SQL transaction. Rolls back on any thrown error. */
export async function withTransaction<T>(
  fn: (client: PoolClient) => Promise<T>
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}
