import { createHash } from 'crypto';
import { config } from '../config';
import { ApiError } from '../lib/errors';

/**
 * CashdeskBot partner API client (https://partners.servcul.com/CashdeskBotAPI/).
 *
 * The signature scheme below was transcribed directly from the API
 * manager's documentation and verified against the documentation's own
 * worked example (hash=fhd.ncbf9hf2ythr, cashierpass=123123, cashdeskid=77,
 * userid=76, lng=ru):
 *   - step-1 SHA256 and the final "confirm" MD5 both reproduce the
 *     documented example values exactly.
 *   - the "Reception" MD5 sub-hash (used by Deposit/Add) does NOT reproduce
 *     the documented example's published result under the literal formula
 *     text ("summa={0}&cashierpass={1}&cashdeskid={2}"), nor under any
 *     field-order/format variant tried. This looks like a typo in the
 *     vendor's example, not an error in the formula text -- but it has not
 *     been verified against the live API. Confirm the Deposit/Add sign
 *     works against a real request before relying on it in production.
 *
 * "login" is one of the four credentials the docs say to obtain from the
 * API manager, but it does not appear in any of the four documented
 * signature formulas below. Left wired through as a stored credential in
 * case another (undocumented) endpoint needs it -- worth confirming with
 * the API manager whether it belongs anywhere in these four calls.
 */

function sha256Hex(input: string): string {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

function md5Hex(input: string): string {
  return createHash('md5').update(input, 'utf8').digest('hex');
}

interface CashdeskBotCredentials {
  baseUrl: string;
  login: string;
  cashierpass: string;
  hash: string;
  cashdeskid: string;
}

function getCredentials(): CashdeskBotCredentials {
  const { cashdeskBot } = config;
  const missing = (['login', 'cashierpass', 'hash', 'cashdeskid'] as const).filter((k) => !cashdeskBot[k]);
  if (missing.length > 0) {
    throw ApiError.badRequest(
      `CashdeskBot is not configured -- missing ${missing
        .map((k) => `CASHDESKBOT_${k.toUpperCase()}`)
        .join(', ')}. Obtain these from the CashdeskBot API manager and set them as backend environment variables.`,
      'CASHDESKBOT_NOT_CONFIGURED'
    );
  }
  return cashdeskBot as CashdeskBotCredentials;
}

/** Non-throwing check for whether CashdeskBot credentials are on file, so callers can pick a fallback path. */
export function isCashdeskBotConfigured(): boolean {
  try {
    getCredentials();
    return true;
  } catch {
    return false;
  }
}

/** Formats a Date as "yyyy.MM.dd HH:mm:ss" in UTC+0, per the Balance endpoint's `dt` spec. */
export function formatCashdeskBotDate(date: Date): string {
  const p = (n: number, len = 2) => String(n).padStart(len, '0');
  return (
    `${date.getUTCFullYear()}.${p(date.getUTCMonth() + 1)}.${p(date.getUTCDate())} ` +
    `${p(date.getUTCHours())}:${p(date.getUTCMinutes())}:${p(date.getUTCSeconds())}`
  );
}

function buildDepositSign(creds: CashdeskBotCredentials, userId: string, lng: string, summa: number): string {
  const step1 = sha256Hex(`hash=${creds.hash}&lng=${lng}&userid=${userId}`);
  const step2 = md5Hex(`summa=${summa}&cashierpass=${creds.cashierpass}&cashdeskid=${creds.cashdeskid}`);
  return sha256Hex(step1 + step2);
}

function buildPayoutSign(creds: CashdeskBotCredentials, userId: string, lng: string, code: string): string {
  const step1 = sha256Hex(`hash=${creds.hash}&lng=${lng}&userid=${userId}`);
  const step2 = md5Hex(`code=${code}&cashierpass=${creds.cashierpass}&cashdeskid=${creds.cashdeskid}`);
  return sha256Hex(step1 + step2);
}

function buildBalanceSign(creds: CashdeskBotCredentials, dt: string): string {
  const step1 = sha256Hex(`hash=${creds.hash}&cashdeskid=${creds.cashdeskid}&dt=${dt}`);
  const step2 = md5Hex(`dt=${dt}&cashierpass=${creds.cashierpass}&cashdeskid=${creds.cashdeskid}`);
  return sha256Hex(step1 + step2);
}

function buildUserSearchSign(creds: CashdeskBotCredentials, userId: string): string {
  const step1 = sha256Hex(`hash=${creds.hash}&userid=${userId}&cashdeskid=${creds.cashdeskid}`);
  const step2 = md5Hex(`userid=${userId}&cashierpass=${creds.cashierpass}&hash=${creds.hash}`);
  return sha256Hex(step1 + step2);
}

function confirmForUser(creds: CashdeskBotCredentials, userId: string): string {
  return md5Hex(`${userId}:${creds.hash}`);
}

function confirmForCashdesk(creds: CashdeskBotCredentials): string {
  return md5Hex(`${creds.cashdeskid}:${creds.hash}`);
}

async function callCashdeskBot(
  creds: CashdeskBotCredentials,
  path: string,
  sign: string,
  init: { method: 'GET' | 'POST'; body?: unknown }
): Promise<{ status: number; json: any }> {
  const res = await fetch(`${creds.baseUrl}${path}`, {
    method: init.method,
    headers: {
      'Content-Type': 'application/json',
      sign,
    },
    body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
  });

  const text = await res.text();
  let json: any = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }

  if (res.status === 401) {
    throw ApiError.unauthorized('CashdeskBot rejected the request: invalid or missing "sign" signature.');
  }
  if (res.status === 403) {
    throw ApiError.forbidden('CashdeskBot rejected the request: invalid "confirm" value.');
  }
  if (!res.ok) {
    const message = (json && json.message) || `CashdeskBot request failed with HTTP ${res.status}`;
    throw new ApiError(502, 'CASHDESKBOT_ERROR', message, json);
  }

  return { status: res.status, json };
}

/** POST /Deposit/{userId}/Add -- fund a player account. */
export async function cashdeskBotDeposit(userId: string, input: { lng: string; summa: number }) {
  const creds = getCredentials();
  const sign = buildDepositSign(creds, userId, input.lng, input.summa);
  const confirm = confirmForUser(creds, userId);
  const { json } = await callCashdeskBot(creds, `/Deposit/${encodeURIComponent(userId)}/Add`, sign, {
    method: 'POST',
    body: {
      cashdeskid: Number(creds.cashdeskid),
      lng: input.lng,
      summa: input.summa,
      confirm,
    },
  });
  // The documentation does not show a response schema for this endpoint --
  // passed through as-is. HTTP 401/403/non-2xx are already thrown above;
  // reaching here means CashdeskBot accepted the request.
  return json;
}

/** POST /Deposit/{userId}/Payout -- process a player payout. */
export async function cashdeskBotPayout(userId: string, input: { lng: string; code: string }) {
  const creds = getCredentials();
  const sign = buildPayoutSign(creds, userId, input.lng, input.code);
  const confirm = confirmForUser(creds, userId);
  const { json } = await callCashdeskBot(creds, `/Deposit/${encodeURIComponent(userId)}/Payout`, sign, {
    method: 'POST',
    body: {
      cashdeskId: Number(creds.cashdeskid),
      lng: input.lng,
      code: input.code,
      confirm,
    },
  });
  const result = {
    success: Boolean(json?.success),
    summa: json?.summa ?? null,
    messageId: json?.messageId ?? null,
    message: json?.message ?? null,
  };
  // success:false is a legitimate 200-level business outcome (e.g.
  // insufficient balance), not a transport error -- surfaced honestly to
  // the caller rather than thrown, but never treated as a success.
  return result;
}

/** GET /Cashdesk/{cashdeskId}/Balance -- check cashpoint balance. */
export async function cashdeskBotBalance(dt: Date = new Date()) {
  const creds = getCredentials();
  const dtStr = formatCashdeskBotDate(dt);
  const sign = buildBalanceSign(creds, dtStr);
  const confirm = confirmForCashdesk(creds);
  const qs = new URLSearchParams({ confirm, dt: dtStr }).toString();
  const { json } = await callCashdeskBot(creds, `/Cashdesk/${encodeURIComponent(creds.cashdeskid)}/Balance?${qs}`, sign, {
    method: 'GET',
  });
  return {
    balance: json?.Balance ?? null,
    limit: json?.Limit ?? null,
  };
}

/** GET /Users/{userId} -- look up a player. */
export async function cashdeskBotSearchUser(userId: string) {
  const creds = getCredentials();
  const sign = buildUserSearchSign(creds, userId);
  const confirm = confirmForUser(creds, userId);
  const qs = new URLSearchParams({ confirm, cashdeskid: creds.cashdeskid }).toString();
  const { json } = await callCashdeskBot(creds, `/Users/${encodeURIComponent(userId)}?${qs}`, sign, {
    method: 'GET',
  });
  return {
    currencyId: json?.currencyId ?? null,
    userId: json?.userId ?? null,
    name: json?.name ?? null,
  };
}
