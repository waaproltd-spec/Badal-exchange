import { PoolClient } from 'pg';
import { pool } from '../db/pool';
import { ApiError } from '../lib/errors';
import { METHOD_LABELS, Method, methodCatalog } from '../lib/methods';

type Db = PoolClient | typeof pool;

export async function listPaymentMethods(db: Db = pool) {
  const { rows } = await db.query('SELECT method, enabled, updated_at FROM payment_methods');
  const byMethod = new Map(rows.map((r) => [r.method, r]));
  // Driven by METHODS so the order is stable and a method missing a row
  // (shouldn't happen after migration 006) still shows, enabled.
  return methodCatalog().map((m) => ({
    ...m,
    enabled: byMethod.get(m.method)?.enabled ?? true,
    updatedAt: byMethod.get(m.method)?.updated_at ?? null,
  }));
}

/** Refuses new orders for a method an agent/admin has switched OFF. */
export async function assertMethodEnabled(method: Method, db: Db = pool) {
  const { rows } = await db.query('SELECT enabled FROM payment_methods WHERE method = $1', [method]);
  if (rows[0] && rows[0].enabled === false) {
    throw ApiError.badRequest(`${METHOD_LABELS[method]} is currently unavailable`, 'METHOD_DISABLED');
  }
}

export async function listDepositNumbers(opts: { enabledOnly: boolean }, db: Db = pool) {
  const { rows } = await db.query(
    `SELECT * FROM deposit_numbers ${opts.enabledOnly ? 'WHERE enabled = true' : ''} ORDER BY method, created_at`
  );
  return rows.map(serializeDepositNumber);
}

export function serializeDepositNumber(r: any) {
  return { id: r.id, method: r.method, number: r.number, label: r.label, enabled: r.enabled, updatedAt: r.updated_at };
}

export async function listHomeAds(opts: { enabledOnly: boolean }, db: Db = pool) {
  const { rows } = await db.query(
    `SELECT * FROM home_ads ${opts.enabledOnly ? 'WHERE enabled = true' : ''} ORDER BY sort_order, created_at DESC`
  );
  return rows.map(serializeHomeAd);
}

export function serializeHomeAd(r: any) {
  return {
    id: r.id,
    title: r.title,
    body: r.body,
    imageUrl: r.image_url,
    linkUrl: r.link_url,
    enabled: r.enabled,
    sortOrder: r.sort_order,
    updatedAt: r.updated_at,
  };
}

export async function listNotifications(limit: number, db: Db = pool) {
  const { rows } = await db.query('SELECT * FROM notifications ORDER BY created_at DESC LIMIT $1', [limit]);
  return rows.map(serializeNotification);
}

export function serializeNotification(r: any) {
  return { id: r.id, title: r.title, body: r.body, createdAt: r.created_at };
}

export const CONTACT_KEYS = ['contact_whatsapp', 'contact_facebook', 'contact_telegram'] as const;

export async function getContacts(db: Db = pool) {
  const { rows } = await db.query('SELECT key, value FROM app_settings WHERE key = ANY($1)', [CONTACT_KEYS]);
  const map = Object.fromEntries(rows.map((r) => [r.key, r.value]));
  return {
    whatsapp: map.contact_whatsapp ?? '',
    facebook: map.contact_facebook ?? '',
    telegram: map.contact_telegram ?? '',
  };
}
