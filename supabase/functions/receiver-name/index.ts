// Customer App: the receiver's name on Confirm Withdrawal for Golis, ZAAD
// and EVC Plus, as Sahal has it.
//
//   POST /functions/v1/receiver-name   {method}
//   -> 200 {found: true, name}  |  200 {found: false}
//      503 RECEIVER_NAME_UNAVAILABLE   Sahal couldn't be asked (not signed in, no answer)
//
// The database (customer_begin_receiver_lookup, as the caller) checks the
// customer and the method and gives the customer's own number; the name is
// asked with the Sahal session the golis-merchant feed keeps open
// (POST /api/account/find {type: 'internetwork', mobileNo}, as a payout
// does). Read only: nothing is sent and the session's cookies aren't changed.
const BASE = (Deno.env.get('GOLIS_MERCHANT_BASE_URL') || 'https://mymerchant.golis.so').replace(/\/$/, '');

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

const error = (status: number, code: string, message: string) => json({ error: { code, message } }, status);

class RpcError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}

/** A database function, as the caller (authorization) or as the service. */
async function rpc(fn: string, args: Record<string, unknown>, authorization?: string) {
  const key = authorization ? Deno.env.get('SUPABASE_ANON_KEY')! : Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (authorization) headers.Authorization = authorization;
  else if (!key.startsWith('sb_')) headers.Authorization = `Bearer ${key}`;
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const code: string | undefined = data?.code;
    const status = code?.startsWith('PT') ? Number(code.slice(2)) || 400 : res.status === 401 ? 401 : 400;
    throw new RpcError(status, data?.hint || code || 'ERROR', data?.message || 'Request failed');
  }
  return data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return error(405, 'METHOD_NOT_ALLOWED', 'Use POST');
  const authorization = req.headers.get('Authorization');
  if (!authorization) return error(401, 'UNAUTHORIZED', 'Sign in first');

  let method = '';
  let phone: string | null = null;
  try {
    const body = await req.json();
    method = String(body?.method ?? '');
    // The number the money goes to, when it is not the registered one (the database checks it).
    phone = body?.phone ? String(body.phone) : null;
  } catch {
    return error(400, 'VALIDATION_ERROR', 'Send {method}');
  }

  let checked: { method: string; mobile: string };
  try {
    checked = await rpc('customer_begin_receiver_lookup', { p_method: method, p_phone: phone }, authorization);
  } catch (err) {
    const e = err as RpcError;
    return error(e.status ?? 400, e.code ?? 'ERROR', e.message);
  }

  const unavailable = () => error(503, 'RECEIVER_NAME_UNAVAILABLE', 'Could not check the name right now.');
  try {
    const feed = await rpc('merchant_feed_get', { p_provider: 'golis' });
    if (!feed?.sessionId) return unavailable();
    const res = await fetch(`${BASE}/api/account/find`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        ...(feed.cookies ? { Cookie: String(feed.cookies) } : {}),
      },
      body: JSON.stringify({ userNature: 'MERCHANT', sessionId: feed.sessionId, type: 'internetwork', mobileNo: checked.mobile }),
      signal: AbortSignal.timeout(15_000),
    });
    const found = await res.json();
    const code = String(found?.resultCode ?? '');
    const name = String(found?.ReceiverInfo?.NAME ?? '').trim();
    if (code === '2001' && name) return json({ found: true, name });
    // 4005 / 7777: the session has ended; the feed signs in again.
    if (['4005', '7777'].includes(code) || !code) return unavailable();
    return json({ found: false });
  } catch (err) {
    console.error('receiver name', (err as Error).message);
    return unavailable();
  }
});
