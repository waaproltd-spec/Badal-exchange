// CashdeskBot partner API (https://partners.servcul.com/CashdeskBotAPI/),
// moved from the Node backend (services/cashdeskBotService.ts and
// routes/cashdeskbot.ts) to a Supabase Edge Function. Same routes, request
// bodies, signatures and responses:
//
//   POST /functions/v1/cashdeskbot/deposit/:userId   {lng, summa}  + Idempotency-Key
//   POST /functions/v1/cashdeskbot/payout/:userId    {lng, code}   + Idempotency-Key
//   GET  /functions/v1/cashdeskbot/balance[?dt=...]
//   GET  /functions/v1/cashdeskbot/users/:userId
//
// Management only (admins and agents with 'manage_settings'), checked by
// the database for the caller's own Supabase session. The CashdeskBot
// credentials are Edge Function secrets, never sent to the apps:
//   supabase secrets set CASHDESKBOT_LOGIN=... CASHDESKBOT_CASHIERPASS=... \
//     CASHDESKBOT_HASH=... CASHDESKBOT_CASHDESKID=... [CASHDESKBOT_BASE_URL=...]
//
// See the Node service for notes on the signature scheme (the Deposit/Add
// signature still needs confirming against the live API).
import { md5Hex } from './md5.ts';

class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: unknown) {
    super(message);
  }
}

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

export interface Creds {
  baseUrl: string;
  login: string;
  cashierpass: string;
  hash: string;
  cashdeskid: string;
}

function getCredentials(): Creds {
  const env = (k: string) => Deno.env.get(`CASHDESKBOT_${k.toUpperCase()}`) ?? '';
  const missing = ['login', 'cashierpass', 'hash', 'cashdeskid'].filter((k) => !env(k));
  if (missing.length > 0) {
    throw new ApiError(
      400,
      'CASHDESKBOT_NOT_CONFIGURED',
      `CashdeskBot is not configured -- missing ${missing.map((k) => `CASHDESKBOT_${k.toUpperCase()}`).join(', ')}. ` +
        'Obtain these from the CashdeskBot API manager and set them as Supabase Edge Function secrets.',
    );
  }
  return {
    baseUrl: env('base_url') || 'https://partners.servcul.com/CashdeskBotAPI',
    login: env('login'),
    cashierpass: env('cashierpass'),
    hash: env('hash'),
    cashdeskid: env('cashdeskid'),
  };
}

/** "yyyy.MM.dd HH:mm:ss" in UTC, per the Balance endpoint's `dt` spec. */
export function formatCashdeskBotDate(date: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${date.getUTCFullYear()}.${p(date.getUTCMonth() + 1)}.${p(date.getUTCDate())} ` +
    `${p(date.getUTCHours())}:${p(date.getUTCMinutes())}:${p(date.getUTCSeconds())}`;
}

// sign = SHA256(SHA256(step1) + MD5(step2)), per the CashdeskBot docs.
const sign = async (step1: string, step2: string) => sha256Hex((await sha256Hex(step1)) + md5Hex(step2));
export const depositSign = (c: Creds, userId: string, lng: string, summa: number) =>
  sign(`hash=${c.hash}&lng=${lng}&userid=${userId}`, `summa=${summa}&cashierpass=${c.cashierpass}&cashdeskid=${c.cashdeskid}`);
export const payoutSign = (c: Creds, userId: string, lng: string, code: string) =>
  sign(`hash=${c.hash}&lng=${lng}&userid=${userId}`, `code=${code}&cashierpass=${c.cashierpass}&cashdeskid=${c.cashdeskid}`);
export const balanceSign = (c: Creds, dt: string) =>
  sign(`hash=${c.hash}&cashdeskid=${c.cashdeskid}&dt=${dt}`, `dt=${dt}&cashierpass=${c.cashierpass}&cashdeskid=${c.cashdeskid}`);
export const userSearchSign = (c: Creds, userId: string) =>
  sign(`hash=${c.hash}&userid=${userId}&cashdeskid=${c.cashdeskid}`, `userid=${userId}&cashierpass=${c.cashierpass}&hash=${c.hash}`);
const confirmForUser = (c: Creds, userId: string) => md5Hex(`${userId}:${c.hash}`);
const confirmForCashdesk = (c: Creds) => md5Hex(`${c.cashdeskid}:${c.hash}`);

async function callCashdeskBot(c: Creds, path: string, sign: string, method: 'GET' | 'POST', body?: unknown) {
  const res = await fetch(`${c.baseUrl}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', sign },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let parsed: any = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  if (res.status === 401) throw new ApiError(401, 'UNAUTHORIZED', 'CashdeskBot rejected the request: invalid or missing "sign" signature.');
  if (res.status === 403) throw new ApiError(403, 'FORBIDDEN', 'CashdeskBot rejected the request: invalid "confirm" value.');
  if (!res.ok) {
    throw new ApiError(502, 'CASHDESKBOT_ERROR', parsed?.message || `CashdeskBot request failed with HTTP ${res.status}`, parsed);
  }
  return parsed;
}

/** The caller's own Supabase session, used for every database call. */
interface Db {
  authorization: string;
}

/** Runs a database function as the caller; maps its errors to ApiError. */
async function rpc(db: Db, fn: string, args: Record<string, unknown>) {
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: Deno.env.get('SUPABASE_ANON_KEY')!,
      Authorization: db.authorization,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const code: string | undefined = data?.code;
    const status = code?.startsWith('PT') ? Number(code.slice(2)) || 400 : res.status === 401 ? 401 : 400;
    throw new ApiError(status, data?.hint || code || 'ERROR', data?.message || 'Request failed');
  }
  return data;
}

async function moneyCall(
  db: Db,
  req: Request,
  action: 'deposit' | 'payout',
  userId: string,
  payload: Record<string, unknown>,
  run: () => Promise<{ response: unknown; audit: unknown }>,
) {
  const key = req.headers.get('Idempotency-Key');
  if (!key) throw new ApiError(400, 'IDEMPOTENCY_KEY_REQUIRED', 'Idempotency-Key header is required');
  const replay = await rpc(db, 'cashdeskbot_begin', { p_action: action, p_idempotency_key: key, p_payload: { userId, ...payload } });
  if (replay !== null) return replay;
  let result;
  try {
    result = await run();
  } catch (err) {
    if (err instanceof ApiError && err.status !== 502) {
      // CashdeskBot never accepted it: free the key for a retry.
      await rpc(db, 'cashdeskbot_abort', { p_idempotency_key: key }).catch(() => {});
    }
    throw err;
  }
  await rpc(db, 'cashdeskbot_finish', {
    p_action: action,
    p_user_id: userId,
    p_audit: result.audit,
    p_idempotency_key: key,
    p_response: result.response,
  });
  return result.response;
}

async function handle(req: Request): Promise<unknown> {
  const authorization = req.headers.get('Authorization');
  if (!authorization) throw new ApiError(401, 'UNAUTHORIZED', 'Missing bearer token');
  const db: Db = { authorization };
  if ((await rpc(db, 'session_can_manage', {})) !== true) {
    throw new ApiError(403, 'FORBIDDEN', 'Your account is not allowed to manage settings. Ask an admin for access.');
  }

  const url = new URL(req.url);
  const parts = url.pathname.split('/').filter(Boolean);
  const at = parts.indexOf('cashdeskbot');
  const [route, param] = parts.slice(at + 1);
  const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};

  if (req.method === 'POST' && route === 'deposit' && param) {
    const { lng, summa } = body as { lng?: unknown; summa?: unknown };
    if (typeof lng !== 'string' || !lng || typeof summa !== 'number' || !(summa > 0)) {
      throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid request');
    }
    return moneyCall(db, req, 'deposit', param, { lng, summa }, async () => {
      const c = getCredentials();
      const response = await callCashdeskBot(c, `/Deposit/${encodeURIComponent(param)}/Add`, await depositSign(c, param, lng, summa), 'POST', {
        cashdeskid: Number(c.cashdeskid),
        lng,
        summa,
        confirm: confirmForUser(c, param),
      });
      return { response, audit: { lng, summa } };
    });
  }

  if (req.method === 'POST' && route === 'payout' && param) {
    const { lng, code } = body as { lng?: unknown; code?: unknown };
    if (typeof lng !== 'string' || !lng || typeof code !== 'string' || !code) {
      throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid request');
    }
    return moneyCall(db, req, 'payout', param, { lng, code }, async () => {
      const c = getCredentials();
      const raw = await callCashdeskBot(c, `/Deposit/${encodeURIComponent(param)}/Payout`, await payoutSign(c, param, lng, code), 'POST', {
        cashdeskId: Number(c.cashdeskid),
        lng,
        code,
        confirm: confirmForUser(c, param),
      });
      // success:false (e.g. insufficient balance) is a real outcome, returned as-is.
      const response = {
        success: Boolean(raw?.success),
        summa: raw?.summa ?? null,
        messageId: raw?.messageId ?? null,
        message: raw?.message ?? null,
      };
      return { response, audit: response };
    });
  }

  if (req.method === 'GET' && route === 'balance') {
    const dtParam = url.searchParams.get('dt');
    const dt = dtParam ? new Date(dtParam) : new Date();
    if (Number.isNaN(dt.getTime())) throw new ApiError(400, 'BAD_REQUEST', 'Invalid dt');
    const c = getCredentials();
    const dtStr = formatCashdeskBotDate(dt);
    const qs = new URLSearchParams({ confirm: confirmForCashdesk(c), dt: dtStr }).toString();
    const raw = await callCashdeskBot(c, `/Cashdesk/${encodeURIComponent(c.cashdeskid)}/Balance?${qs}`, await balanceSign(c, dtStr), 'GET');
    return { balance: raw?.Balance ?? null, limit: raw?.Limit ?? null };
  }

  if (req.method === 'GET' && route === 'users' && param) {
    const c = getCredentials();
    const qs = new URLSearchParams({ confirm: confirmForUser(c, param), cashdeskid: c.cashdeskid }).toString();
    const raw = await callCashdeskBot(c, `/Users/${encodeURIComponent(param)}?${qs}`, await userSearchSign(c, param), 'GET');
    return { currencyId: raw?.currencyId ?? null, userId: raw?.userId ?? null, name: raw?.name ?? null };
  }

  throw new ApiError(404, 'NOT_FOUND', `No route for ${req.method} ${url.pathname}`);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    return json(await handle(req));
  } catch (err) {
    if (err instanceof ApiError) {
      return json({ error: { code: err.code, message: err.message, details: err.details } }, err.status);
    }
    console.error(err);
    return json({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } }, 500);
  }
});
