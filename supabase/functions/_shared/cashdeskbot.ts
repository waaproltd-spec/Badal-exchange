// Client for the CashdeskBot partner API (https://partners.servcul.com/CashdeskBotAPI/),
// shared by the `cashdeskbot` (Agent App), `telegram-bot` and
// `platform-orders` Edge Functions.
//
// Each betting brand has its own cash register, with its own Edge Function
// secrets (never sent to the apps):
//   888starz: CASHDESKBOT_LOGIN, CASHDESKBOT_CASHIERPASS, CASHDESKBOT_HASH,
//             CASHDESKBOT_CASHDESKID [, CASHDESKBOT_BASE_URL]
//   1xBet:    the same names with the CASHDESKBOT_1XBET_ prefix
//   WinWin:   the same names with the CASHDESKBOT_WINWIN_ prefix
//   Betwinner: the same names with the CASHDESKBOT_BETWINNER_ prefix
//   DBbet, BetJam, BetOnGame: CASHDESKBOT_DBBET_, CASHDESKBOT_BETJAM_, CASHDESKBOT_BETONGAME_
//   MELBET: the same names with the CASHDESKBOT_MELBET_ prefix
//
// Checked against the live API: the Balance signature differs from the PDF
// (see balanceSign). The Deposit/Add and Payout signatures are as the PDF
// describes and still need confirming against the live API.
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

export interface Brand {
  key: string;
  label: string;
  /** The order method its customers' orders use. */
  method: string;
  /** Prefix of its CashdeskBot secrets. */
  envPrefix: string;
}

export const BRANDS: Record<string, Brand> = {
  '888starz': { key: '888starz', label: '888starz', method: '888starz', envPrefix: 'CASHDESKBOT' },
  '1xbet': { key: '1xbet', label: '1xBet', method: 'onexbet', envPrefix: 'CASHDESKBOT_1XBET' },
  winwin: { key: 'winwin', label: 'WinWin', method: 'winwin', envPrefix: 'CASHDESKBOT_WINWIN' },
  betwinner: { key: 'betwinner', label: 'Betwinner', method: 'betwinner', envPrefix: 'CASHDESKBOT_BETWINNER' },
  dbbet: { key: 'dbbet', label: 'DBbet', method: 'dbbet', envPrefix: 'CASHDESKBOT_DBBET' },
  betjam: { key: 'betjam', label: 'BetJam', method: 'betjam', envPrefix: 'CASHDESKBOT_BETJAM' },
  betongame: { key: 'betongame', label: 'BetOnGame', method: 'betongame', envPrefix: 'CASHDESKBOT_BETONGAME' },
  melbet: { key: 'melbet', label: 'MELBET', method: 'melbet', envPrefix: 'CASHDESKBOT_MELBET' },
};

export const brandForMethod = (method: string) => Object.values(BRANDS).find((b) => b.method === method);

export function getCredentials(brand: Brand = BRANDS['888starz']): Creds {
  const name = (k: string) => `${brand.envPrefix}_${k.toUpperCase()}`;
  // Trimmed: a value pasted into the dashboard often carries a space or newline,
  // which changes the signature and CashdeskBot then refuses every request.
  const env = (k: string) => (Deno.env.get(name(k)) ?? '').trim();
  const missing = ['login', 'cashierpass', 'hash', 'cashdeskid'].filter((k) => !env(k));
  if (missing.length > 0) {
    throw new ApiError(
      400,
      'CASHDESKBOT_NOT_CONFIGURED',
      `The ${brand.label} cash register is not configured -- missing ${missing.map(name).join(', ')}. ` +
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
// The PDF says step 1 is hash&cashdeskid&dt; the live API accepts hash&cashierpass&dt.
export const balanceSign = (c: Creds, dt: string) =>
  sign(`hash=${c.hash}&cashierpass=${c.cashierpass}&dt=${dt}`, `dt=${dt}&cashierpass=${c.cashierpass}&cashdeskid=${c.cashdeskid}`);
export const userSearchSign = (c: Creds, userId: string) =>
  sign(`hash=${c.hash}&userid=${userId}&cashdeskid=${c.cashdeskid}`, `userid=${userId}&cashierpass=${c.cashierpass}&hash=${c.hash}`);
export const confirmForUser = (c: Creds, userId: string) => md5Hex(`${userId}:${c.hash}`);
export const confirmForCashdesk = (c: Creds) => md5Hex(`${c.cashdeskid}:${c.hash}`);

/** A response field, whether CashdeskBot sends it as `userId` or `UserId`. */
function field(raw: any, name: string) {
  return raw?.[name] ?? raw?.[name[0].toUpperCase() + name.slice(1)] ?? null;
}

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

export interface PayoutResult {
  success: boolean;
  summa: number | null;
  messageId: number | null;
  message: string | null;
}

// success:false (e.g. insufficient balance) is a real outcome, returned as-is.
const operationResult = (raw: any): PayoutResult => ({
  success: Boolean(field(raw, 'success')),
  summa: field(raw, 'summa'),
  messageId: field(raw, 'messageId'),
  message: field(raw, 'message'),
});

/** POST Deposit/{userId}/Add: tops up a player account. */
export async function depositToPlayer(c: Creds, userId: string, lng: string, summa: number): Promise<PayoutResult> {
  return operationResult(await callCashdeskBot(c, `/Deposit/${encodeURIComponent(userId)}/Add`, await depositSign(c, userId, lng, summa), 'POST', {
    cashdeskid: Number(c.cashdeskid),
    lng,
    summa,
    confirm: confirmForUser(c, userId),
  }));
}

/** POST Deposit/{userId}/Payout: pays out a player's withdrawal code. */
export async function payoutToPlayer(c: Creds, userId: string, lng: string, code: string): Promise<PayoutResult> {
  const raw = await callCashdeskBot(c, `/Deposit/${encodeURIComponent(userId)}/Payout`, await payoutSign(c, userId, lng, code), 'POST', {
    cashdeskId: Number(c.cashdeskid),
    lng,
    code,
    confirm: confirmForUser(c, userId),
  });
  return operationResult(raw);
}

/** GET Cashdesk/{cashdeskId}/Balance: the cash register's balance and limit. */
export async function cashdeskBalance(c: Creds, dt: Date): Promise<{ balance: number | null; limit: number | null }> {
  const dtStr = formatCashdeskBotDate(dt);
  const qs = new URLSearchParams({ confirm: confirmForCashdesk(c), dt: dtStr }).toString();
  const raw = await callCashdeskBot(c, `/Cashdesk/${encodeURIComponent(c.cashdeskid)}/Balance?${qs}`, await balanceSign(c, dtStr), 'GET');
  return { balance: field(raw, 'balance'), limit: field(raw, 'limit') };
}

export interface Player {
  found: boolean;
  currencyId: number | null;
  userId: number | null;
  name: string | null;
}

/** GET Users/{userId}: player search. */
export async function findPlayer(c: Creds, userId: string): Promise<Player> {
  const qs = new URLSearchParams({ confirm: confirmForUser(c, userId), cashdeskid: c.cashdeskid }).toString();
  const raw = await callCashdeskBot(c, `/Users/${encodeURIComponent(userId)}?${qs}`, await userSearchSign(c, userId), 'GET');
  // An unknown player comes back as {"UserId":0,"CurrencyId":0}.
  const id = field(raw, 'userId');
  return { found: Boolean(id), currencyId: field(raw, 'currencyId'), userId: id, name: field(raw, 'name') };
}
