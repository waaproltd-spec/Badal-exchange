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
// the database for the caller's own Supabase session. The CashdeskBot client
// and its credentials live in ../_shared/cashdeskbot.ts.
import {
  ApiError,
  cashdeskBalance,
  depositToPlayer,
  findPlayer,
  getCredentials,
  payoutToPlayer,
} from '../_shared/cashdeskbot.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
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
      const response = await depositToPlayer(getCredentials(), param, lng, summa);
      return { response, audit: { lng, summa } };
    });
  }

  if (req.method === 'POST' && route === 'payout' && param) {
    const { lng, code } = body as { lng?: unknown; code?: unknown };
    if (typeof lng !== 'string' || !lng || typeof code !== 'string' || !code) {
      throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid request');
    }
    return moneyCall(db, req, 'payout', param, { lng, code }, async () => {
      const response = await payoutToPlayer(getCredentials(), param, lng, code);
      return { response, audit: response };
    });
  }

  if (req.method === 'GET' && route === 'balance') {
    const dtParam = url.searchParams.get('dt');
    const dt = dtParam ? new Date(dtParam) : new Date();
    if (Number.isNaN(dt.getTime())) throw new ApiError(400, 'BAD_REQUEST', 'Invalid dt');
    return cashdeskBalance(getCredentials(), dt);
  }

  if (req.method === 'GET' && route === 'users' && param) {
    return findPlayer(getCredentials(), param);
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
