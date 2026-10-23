// Agent App: Company Balances.
//
//   GET /functions/v1/company-balances[?refresh=1&from=ISO&to=ISO]
//
// For callers the database lets see company balances (admins, managers,
// agents with 'view_company_balances'; agent_company_balances_access, as the
// caller's own session). Reads each connected company's cash register when
// its last read is older than a minute (15 seconds with refresh=1), records
// the read (../_shared/company_balances.ts), then returns
// agent_company_balances for the period, as the caller. Balances are only
// ever what the company's API said; nothing here can set one.
import { ApiError } from '../_shared/cashdeskbot.ts';
import { refreshCompanyBalances } from '../_shared/company_balances.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

async function call(fn: string, args: Record<string, unknown>, authorization: string, apikey: string) {
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey, 'Content-Type': 'application/json', ...(authorization ? { Authorization: authorization } : {}) },
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

/** As the service role (records balance reads). */
function serviceRpc(fn: string, args: Record<string, unknown>) {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  return call(fn, args, key.startsWith('sb_') ? '' : `Bearer ${key}`, key);
}

/** The signed-in user's id from their token (already checked by the database). */
function userId(authorization: string): string | null {
  try {
    const payload = authorization.replace(/^Bearer\s+/i, '').split('.')[1];
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/'))).sub ?? null;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED', message: 'Use GET' } }, 405);
  const authorization = req.headers.get('Authorization');
  if (!authorization) return json({ error: { code: 'UNAUTHORIZED', message: 'Sign in first' } }, 401);
  const asCaller = (fn: string, args: Record<string, unknown>) =>
    call(fn, args, authorization, Deno.env.get('SUPABASE_ANON_KEY')!);

  try {
    await asCaller('agent_company_balances_access', {});
    const url = new URL(req.url);
    const refresh = url.searchParams.get('refresh') === '1';
    const due = (await serviceRpc('company_balance_due', { p_max_age_seconds: refresh ? 15 : 60 })) as string[];
    if (due.length > 0) await refreshCompanyBalances(serviceRpc, due, userId(authorization));
    return json(await asCaller('agent_company_balances', {
      p_from: url.searchParams.get('from') || null,
      p_to: url.searchParams.get('to') || null,
    }));
  } catch (err) {
    const e = err as ApiError;
    return json({ error: { code: e.code ?? 'ERROR', message: e.message } }, e.status ?? 500);
  }
});
