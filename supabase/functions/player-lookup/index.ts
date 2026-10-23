// Customer App: "Find a Player" before a 888STARZ / 1XBET withdrawal.
//
//   POST /functions/v1/player-lookup   {method, accountId}
//   -> 200 {found: true, accountId, name}   name is null when the platform
//                                            doesn't give one
//      200 {found: false, accountId}
//      503 PLAYER_LOOKUP_UNAVAILABLE         the platform couldn't be asked
//
// The database (customer_begin_player_lookup, as the caller's own session)
// checks the customer, the method, the ID and the rate limit; the name comes
// only from the brand's CashdeskBot player search (../_shared/cashdeskbot.ts),
// never made up. The withdrawal itself is checked again by the
// platform-orders worker before any money moves.
import { ApiError, brandForMethod, findPlayer, getCredentials } from '../_shared/cashdeskbot.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

const error = (status: number, code: string, message: string) => json({ error: { code, message } }, status);

/** Runs a database function as the caller; maps its errors to ApiError. */
async function rpc(authorization: string, fn: string, args: Record<string, unknown>) {
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: Deno.env.get('SUPABASE_ANON_KEY')!, Authorization: authorization, 'Content-Type': 'application/json' },
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return error(405, 'METHOD_NOT_ALLOWED', 'Use POST');
  const authorization = req.headers.get('Authorization');
  if (!authorization) return error(401, 'UNAUTHORIZED', 'Sign in first');

  let body: { method?: unknown; accountId?: unknown };
  try {
    body = await req.json();
  } catch {
    return error(400, 'VALIDATION_ERROR', 'Send {method, accountId}');
  }

  let checked: { method: string; accountId: string };
  try {
    checked = await rpc(authorization, 'customer_begin_player_lookup', {
      p_method: String(body.method ?? ''),
      p_account_id: String(body.accountId ?? ''),
    });
  } catch (err) {
    const e = err as ApiError;
    return error(e.status ?? 400, e.code ?? 'ERROR', e.message);
  }

  const unavailable = () =>
    error(503, 'PLAYER_LOOKUP_UNAVAILABLE', 'Could not check the player right now. Try again in a moment.');
  const brand = brandForMethod(checked.method);
  if (!brand) return unavailable();
  try {
    const player = await findPlayer(getCredentials(brand), checked.accountId);
    if (!player.found || String(player.userId) !== String(Number(checked.accountId))) {
      return json({ found: false, accountId: checked.accountId });
    }
    const name = typeof player.name === 'string' && player.name.trim() ? player.name.trim() : null;
    return json({ found: true, accountId: checked.accountId, name });
  } catch (err) {
    console.error('player lookup', brand.key, (err as Error).message);
    return unavailable();
  }
});
