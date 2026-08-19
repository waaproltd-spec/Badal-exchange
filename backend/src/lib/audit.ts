import { PoolClient } from 'pg';
import { pool } from '../db/pool';
import { Role } from '../auth/jwt';

export interface AuditEntry {
  actorId: string | null;
  actorRole: Role | null;
  action: string;
  entityType: string;
  entityId?: string | null;
  before?: unknown;
  after?: unknown;
  ip?: string | null;
}

export async function writeAudit(entry: AuditEntry, client?: PoolClient): Promise<void> {
  const db = client ?? pool;
  await db.query(
    `INSERT INTO audit_logs (actor_id, actor_role, action, entity_type, entity_id, before_json, after_json, ip)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
    [
      entry.actorId,
      entry.actorRole,
      entry.action,
      entry.entityType,
      entry.entityId ?? null,
      entry.before !== undefined ? JSON.stringify(entry.before) : null,
      entry.after !== undefined ? JSON.stringify(entry.after) : null,
      entry.ip ?? null,
    ]
  );
}
