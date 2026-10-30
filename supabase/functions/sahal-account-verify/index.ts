// Verifies a NEW Sahal merchant login saved in the Admin Dashboard
// (migrations/*_sahal_accounts.sql), without touching the working feed.
//
// Woken by the database (a manager tapped Test, or typed the SMS code) with
// the platform worker secret. It does the portal's own steps, for the
// pending account only, in its own cookie jar:
//   login      POST /api/account/login  {userNature, type, username, currency, password}
//              2001 = signed in; 1001 / 6083 = Sahal texted a code to the NEW
//              account's phone (the manager types it in the app);
//   code       POST /api/account/2auth  {type, code, sessionId};
//   then       POST /api/account/transactions: a list that reads is the proof.
// The verified session is stored with the pending account; activating it
// (manage_sahal_account_activate) hands it to the feed, so there is no second
// SMS. Nothing here reads or writes the working feed's session, and nothing
// is logged or returned that is a password, PIN, session id or code.
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

const jar = new Map<string, string>();
const cookieHeader = () => [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
function keepCookies(res: Response) {
  for (const c of res.headers.getSetCookie?.() ?? []) {
    const [pair] = c.split(';');
    const i = pair.indexOf('=');
    if (i > 0) jar.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
  }
}

async function portal(path: string, body: Record<string, unknown>) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...(jar.size ? { Cookie: cookieHeader() } : {}) },
    body: JSON.stringify({ userNature: 'MERCHANT', ...body }),
    signal: AbortSignal.timeout(20_000),
  });
  keepCookies(res);
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${path}: HTTP ${res.status}, not JSON`);
  }
}

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

/** The portal's USD entry (the same look-up the feed makes). */
async function usdCode(): Promise<string> {
  const data = await portal('/api/account/currencies', {});
  for (const rows of rowArrays(data)) {
    const usd = rows.find((c) => Object.values(c).some((v) => /^(usd|840|us)$/i.test(String(v ?? '').trim())));
    const code = usd?.CURRENCYCODE ?? usd?.currencyCode ?? usd?.code;
    if (code != null) return String(code);
  }
  throw new Error('no USD entry in the portal currency list');
}

const say = (s: string) => String(s ?? '').replace(/\s+/g, ' ').slice(0, 200);
const report = (status: string, message: string, extra: Record<string, unknown> = {}) =>
  rpc('sahal_pending_report', {
    p_status: status,
    p_message: say(message),
    p_session: extra.session ?? null,
    p_cookies: extra.cookies ?? null,
    p_second_session: extra.second ?? null,
  });

/** A signed-in session must read the transaction list to count as verified. */
async function finish(session: string) {
  const tx = await portal('/api/account/transactions', { sessionId: session });
  const code = String(tx?.resultCode ?? '');
  if (['4005', '7777'].includes(code) || !code) {
    return report('failed', `Signed in, but Sahal refused the transaction list (${code || 'no answer'})`);
  }
  await report('verified', 'Signed in and the transaction list reads. It can be activated.', { session, cookies: cookieHeader() });
  return { verified: true };
}

async function run() {
  const work = await rpc('sahal_pending_work', {});
  if (!work) return { idle: true };
  jar.clear();
  try {
    if (work.action === 'login') {
      const login = await portal('/api/account/login', {
        type: 'MERCHANT',
        username: work.username,
        password: work.password,
        currency: work.currency || (await usdCode()),
      });
      const code = String(login?.resultCode ?? '');
      if (code === '2001' && login.sessionId) return await finish(String(login.sessionId));
      if ((code === '1001' || code === '6083') && login.sessionId) {
        await report('needs_code', 'Sahal sent an access code to the new account\'s phone. Type it here within 10 minutes.',
          { second: String(login.sessionId), cookies: cookieHeader() });
        return { waiting: 'code' };
      }
      const why: Record<string, string> = {
        '6054': 'The portal asks for a new password: change it on the portal first',
      };
      await report('failed', why[code] ?? (login?.replyMessage ? `Sahal refused the sign-in: ${login.replyMessage}` : `Sahal refused the sign-in (${code || 'no answer'})`));
      return { failed: code };
    }
    // The code a manager typed, with the pending session and its cookie.
    for (const part of String(work.cookies ?? '').split(';')) {
      const i = part.indexOf('=');
      if (i > 0) jar.set(part.slice(0, i).trim(), part.slice(i + 1).trim());
    }
    const auth = await portal('/api/account/2auth', { type: 'MERCHANT', code: work.code, sessionId: work.secondSessionId });
    if (String(auth?.resultCode ?? '') === '2001' && auth.sessionId) return await finish(String(auth.sessionId));
    await report('failed', `Sahal did not accept the code${auth?.replyMessage ? `: ${auth.replyMessage}` : ''}. Test again for a new one.`);
    return { failed: String(auth?.resultCode ?? '') };
  } catch (err) {
    // Sahal not reached: nothing was verified, the manager can test again.
    await report('failed', `Sahal could not be reached: ${(err as Error).message}`).catch(() => {});
    return { error: true };
  }
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
    return Response.json({ error: (err as Error).message }, { status: 502 });
  }
});
