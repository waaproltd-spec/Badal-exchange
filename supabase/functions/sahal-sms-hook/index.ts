// Sahal's SMS access code, from an SMS-forwarding app on the merchant phone
// (migrations/*_sahal_auto_code.sql). The app posts each SMS here with the
// token a manager creates in the Agent App (Sahal sign-in -> SMS forwarder).
// The database decides everything: the token (only its hash is stored), that
// Sahal is waiting for a code, that the SMS is Sahal's and new, and which
// number is the code. The code is entered once and sent to Sahal by the
// golis-merchant function exactly as a typed one.
//
// The answer says what happened, never the code. Nothing of the SMS, the
// token or the code is logged. A wrong or missing token gets "forbidden"
// and nothing else.
//
// Accepts a POST with JSON or a form, or a GET, with the fields in any of
// the usual names:
//   sender: from, sender, address, number, phone
//   text:   text, body, message, content, msg, sms
// and the token as "Authorization: Bearer <token>", "X-Hook-Token: <token>"
// or ?token=<token> (a header is better: a URL ends up in logs).

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
  if (!res.ok) throw new Error(`${fn}: ${res.status}`);
  return data;
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function flatten(v: unknown, into: Record<string, string>, depth = 0) {
  if (depth > 2 || v == null || typeof v !== 'object') return;
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    if (typeof x === 'string' || typeof x === 'number') into[k.toLowerCase()] = String(x);
    else flatten(x, into, depth + 1);
  }
}

Deno.serve(async (req) => {
  const fields: Record<string, string> = {};
  for (const [k, v] of new URL(req.url).searchParams) fields[k.toLowerCase()] = v;
  if (req.method === 'POST') {
    try {
      const type = req.headers.get('content-type') ?? '';
      if (type.includes('json')) flatten(await req.json(), fields);
      else if (type.includes('form')) for (const [k, v] of await req.formData()) fields[k.toLowerCase()] = String(v);
      else fields.text = await req.text();
    } catch {
      return json(400, { result: 'bad_request' });
    }
  } else if (req.method !== 'GET') {
    return json(405, { result: 'method_not_allowed' });
  }

  const auth = req.headers.get('authorization') ?? '';
  const token = (auth.toLowerCase().startsWith('bearer ') ? auth.slice(7) : '') || req.headers.get('x-hook-token') || fields.token || '';
  if (!token) return json(403, { result: 'forbidden' });

  const pick = (...names: string[]) => names.map((n) => fields[n]).find((x) => x != null && x !== '') ?? '';
  try {
    const out = await rpc('sahal_sms_hook_code', {
      p_token: token,
      p_sender: pick('from', 'sender', 'address', 'number', 'phone'),
      p_body: pick('text', 'body', 'message', 'content', 'msg', 'sms'),
    });
    if (out?.result === 'forbidden') return json(403, { result: 'forbidden' });
    return json(200, { result: out?.result ?? 'error', ...(out?.reason ? { reason: out.reason } : {}) });
  } catch {
    return json(500, { result: 'error' });
  }
});
