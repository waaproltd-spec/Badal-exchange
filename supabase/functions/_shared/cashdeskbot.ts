// Client for the CashdeskBot partner API (https://partners.servcul.com/CashdeskBotAPI/),
// shared by the `cashdeskbot` (Agent App) and `telegram-bot` Edge Functions.
// The credentials are Edge Function secrets, never sent to the apps:
//   supabase secrets set CASHDESKBOT_LOGIN=... CASHDESKBOT_CASHIERPASS=... \
//     CASHDESKBOT_HASH=... CASHDESKBOT_CASHDESKID=... [CASHDESKBOT_BASE_URL=...]
//
// See the Node service (backend/src/services/cashDeskBotService.ts) for notes
// on the signature scheme (the Deposit/Add signature still needs confirming
// against the live API).
import { md5Hex } from './md5.ts';

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: unknown) {
    super(message);
  }
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

export function getCredentials(): Creds {
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
export const confirmForUser = (c: Creds, userId: string) => md5Hex(`${userId}:${c.hash}`);
export const confirmForCashdesk = (c: Creds) => md5Hex(`${c.cashdeskid}:${c.hash}`);

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

/** POST Deposit/{userId}/Add: tops up a player account. Returns CashdeskBot's response as-is. */
export async function depositToPlayer(c: Creds, userId: string, lng: string, summa: number) {
  return callCashdeskBot(c, `/Deposit/${encodeURIComponent(userId)}/Add`, await depositSign(c, userId, lng, summa), 'POST', {
    cashdeskid: Number(c.cashdeskid),
    lng,
    summa,
    confirm: confirmForUser(c, userId),
  });
}

export interface PayoutResult {
  success: boolean;
  summa: number | null;
  messageId: number | null;
  message: string | null;
}

/** POST Deposit/{userId}/Payout: pays out a player's withdrawal code. */
export async function payoutToPlayer(c: Creds, userId: string, lng: string, code: string): Promise<PayoutResult> {
  const raw = await callCashdeskBot(c, `/Deposit/${encodeURIComponent(userId)}/Payout`, await payoutSign(c, userId, lng, code), 'POST', {
    cashdeskId: Number(c.cashdeskid),
    lng,
    code,
    confirm: confirmForUser(c, userId),
  });
  // success:false (e.g. insufficient balance) is a real outcome, returned as-is.
  return {
    success: Boolean(raw?.success),
    summa: raw?.summa ?? null,
    messageId: raw?.messageId ?? null,
    message: raw?.message ?? null,
  };
}

/** GET Cashdesk/{cashdeskId}/Balance: the cash register's balance and limit. */
export async function cashdeskBalance(c: Creds, dt: Date): Promise<{ balance: number | null; limit: number | null }> {
  const dtStr = formatCashdeskBotDate(dt);
  const qs = new URLSearchParams({ confirm: confirmForCashdesk(c), dt: dtStr }).toString();
  const raw = await callCashdeskBot(c, `/Cashdesk/${encodeURIComponent(c.cashdeskid)}/Balance?${qs}`, await balanceSign(c, dtStr), 'GET');
  return { balance: raw?.Balance ?? null, limit: raw?.Limit ?? null };
}

export interface Player {
  currencyId: number | null;
  userId: number | null;
  name: string | null;
}

/** GET Users/{userId}: player search. */
export async function findPlayer(c: Creds, userId: string): Promise<Player> {
  const qs = new URLSearchParams({ confirm: confirmForUser(c, userId), cashdeskid: c.cashdeskid }).toString();
  const raw = await callCashdeskBot(c, `/Users/${encodeURIComponent(userId)}?${qs}`, await userSearchSign(c, userId), 'GET');
  return { currencyId: raw?.currencyId ?? null, userId: raw?.userId ?? null, name: raw?.name ?? null };
}
