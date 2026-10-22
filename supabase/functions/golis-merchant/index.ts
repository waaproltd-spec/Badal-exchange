// Sahal (Golis) merchant transaction feed, stage 1: READ ONLY
// (migrations/*_merchant_feed.sql). Woken every minute by the database with
// the platform worker secret while the feed is not stopped.
//
// It talks to the merchant portal exactly as the portal's own web page does
// (mymerchant.golis.so, js/bundle.js): POST /api/account/login with
// {userNature, type, username, currency, password}; resultCode 2001 is
// signed in, 1001 / 6083 ask for a second code, 6054 for a new password;
// POST /api/account/transactions with {userNature, sessionId}; 4005 / 7777
// mean the session ended. Anything but a plain sign-in stops the feed until
// a manager retries, so the merchant phone is never flooded with codes.
//
// The transactions are only stored; nothing is matched or credited.
//
// Secrets: GOLIS_MERCHANT_USERNAME, GOLIS_MERCHANT_PASSWORD
//          [, GOLIS_MERCHANT_CURRENCY (else the portal's USD entry), GOLIS_MERCHANT_BASE_URL]
const PROVIDER = 'golis';
const BASE = (Deno.env.get('GOLIS_MERCHANT_BASE_URL') || 'https://mymerchant.golis.so').replace(/\/$/, '');

async function rpc(fn: string, args: Record<string, unknown>) {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (!key.startsWith('sb_')) headers.Authorization = `Bearer ${key}`;
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(args),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`${fn}: ${data?.message ?? res.status}`);
  return data;
}

async function portal(path: string, body: Record<string, unknown>) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ userNature: 'MERCHANT', ...body }),
    signal: AbortSignal.timeout(20_000),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${path}: HTTP ${res.status}, not JSON`);
  }
}

/** The arrays of objects in a reply, largest first (where the rows are). */
function rowArrays(data: unknown): Record<string, unknown>[][] {
  const found: Record<string, unknown>[][] = [];
  const walk = (v: unknown, depth: number) => {
    if (depth > 3 || v == null || typeof v !== 'object') return;
    if (Array.isArray(v)) {
      if (v.length > 0 && v.every((x) => x && typeof x === 'object' && !Array.isArray(x))) found.push(v as Record<string, unknown>[]);
      return;
    }
    for (const x of Object.values(v)) walk(x, depth + 1);
  };
  walk(data, 0);
  return found.sort((a, b) => b.length - a.length);
}

/** A reply's shape without its values: keys only, for the status message. */
const shape = (data: unknown) =>
  data && typeof data === 'object' ? Object.keys(data as object).slice(0, 20).join(',') : typeof data;

async function sha256(s: string) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** The portal's own id for a row, else a fingerprint of the whole row. */
async function rowId(row: Record<string, unknown>) {
  const key = Object.keys(row).find((k) => /^(transaction_?id|trans_?id|txn_?id|tid)$/i.test(k));
  const v = key ? String(row[key] ?? '').trim() : '';
  return v || `sha256:${await sha256(JSON.stringify(row))}`;
}

async function currency(): Promise<string> {
  const fixed = Deno.env.get('GOLIS_MERCHANT_CURRENCY');
  if (fixed) return fixed;
  // The page may load the list with GET; try POST first, then GET.
  let data = await portal('/api/account/currencies', {});
  if (rowArrays(data).length === 0) {
    const res = await fetch(`${BASE}/api/account/currencies`, { headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(20_000) });
    data = await res.json().catch(() => data);
  }
  for (const rows of rowArrays(data)) {
    const usd = rows.find((c) => Object.values(c).some((v) => /^(usd|840|us)$/i.test(String(v ?? '').trim())));
    if (usd) {
      const code = usd.CURRENCYCODE ?? usd.currencyCode ?? usd.code;
      if (code != null) return String(code);
    }
  }
  throw new Error(`no USD entry in /api/account/currencies (reply: ${shape(data)}${(data as any)?.replyMessage ? ` \"${String((data as any).replyMessage).slice(0, 80)}\"` : ''})`);
}

type Report = { state: string; code?: string | null; message?: string | null; session?: string | null; rows?: unknown[] };
const report = (r: Report) =>
  rpc('merchant_feed_report', {
    p_provider: PROVIDER,
    p_state: r.state,
    p_result_code: r.code ?? null,
    p_message: r.message ?? null,
    p_session_id: r.session ?? null,
    p_rows: r.rows ?? [],
  });

async function run() {
  const username = Deno.env.get('GOLIS_MERCHANT_USERNAME');
  const password = Deno.env.get('GOLIS_MERCHANT_PASSWORD');
  if (!username || !password) {
    return report({ state: 'not_configured', message: 'Set GOLIS_MERCHANT_USERNAME and GOLIS_MERCHANT_PASSWORD' });
  }
  const feed = await rpc('merchant_feed_get', { p_provider: PROVIDER });
  if (feed?.state === 'stopped') return { skipped: 'stopped' };

  let session: string | null = feed?.sessionId ?? null;
  let tx = session ? await portal('/api/account/transactions', { sessionId: session }) : null;
  if (!tx || ['4005', '7777'].includes(String(tx.resultCode))) {
    const login = await portal('/api/account/login', {
      type: 'MERCHANT', username, password, currency: await currency(),
    });
    const code = String(login?.resultCode ?? '');
    if (code !== '2001' || !login.sessionId) {
      // A code, a password change or a refusal: stop until a manager retries.
      const why: Record<string, string> = {
        '1001': 'The portal asks for a second sign-in code',
        '6083': 'The portal asks for an SMS code',
        '6054': 'The portal asks for a new password',
      };
      return report({ state: 'stopped', code, message: why[code] ?? (login?.replyMessage || `Sign-in refused (${shape(login)})`) });
    }
    session = String(login.sessionId);
    tx = await portal('/api/account/transactions', { sessionId: session });
  }
  const code = String(tx?.resultCode ?? '');
  if (['4005', '7777'].includes(code)) {
    return report({ state: 'stopped', code, message: 'Signed in, but the session ended at once' });
  }
  const rows = rowArrays(tx)[0] ?? [];
  const withIds = await Promise.all(rows.map(async (r) => ({ ...r, _id: await rowId(r) })));
  return report({
    state: 'ok',
    code,
    message: `${rows.length} rows; reply keys: ${shape(tx)}`,
    session,
    rows: withIds,
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Forbidden', { status: 403 });
  const secret = req.headers.get('x-worker-secret');
  if (!secret || (await rpc('platform_worker_check', { p_secret: secret }).catch(() => false)) !== true) {
    return new Response('Forbidden', { status: 403 });
  }
  try {
    return Response.json(await run());
  } catch (err) {
    // Could not reach or read the portal: try again next minute.
    const message = (err as Error).message;
    await report({ state: 'ready', code: 'error', message: `Portal not reached: ${message}` }).catch(() => {});
    return Response.json({ error: message }, { status: 502 });
  }
});
