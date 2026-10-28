// Customer App push notifications through Firebase Cloud Messaging (HTTP
// v1): in Somali for completed deposits and withdrawals
// (migrations/*_push_notifications.sql queues them), and the Agent App's
// "Send to all customers" messages as written, to the FCM topic 'customers'
// that every signed-in Customer App device joins
// (migrations/*_push_broadcasts.sql).
//
// Woken by the database (pg_net right after an order completes, pg_cron
// every minute while some wait) with the platform worker secret. Each run
// claims the queued notifications (push_claim), sends one message per
// device, and reports back (push_finish): uninstalled devices' tokens are
// removed, FCM outages retried.
//
// An order message holds the title and text below and, for opening the
// order in the app, data {type, orderId} -- no amount, number or account.
// A broadcast holds its title and text and data {type: 'broadcast',
// notificationId}.
//
// Secret: FIREBASE_SERVICE_ACCOUNT -- the service account key JSON from the
// Firebase console (Project settings -> Service accounts -> Generate new
// private key), as is or base64-encoded. Without it nothing is claimed, so
// queued notifications wait (and expire after a day).
// Optional for tests: FCM_API_URL (default https://fcm.googleapis.com).

const MESSAGES: Record<string, { title: string; body: string }> = {
  deposit_completed: {
    title: 'Deposit-kaagu wuu guulaystay',
    body: 'Lacagta deposit-kaaga si guul leh ayaa loo xaqiijiyey.',
  },
  withdraw_completed: {
    title: 'Withdrawal-kaagu wuu guulaystay',
    body: 'Lacagtaada si guul leh ayaa loo bixiyey.',
  },
};

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

interface Job {
  id: string;
  kind: string;
  orderId?: string;
  tokens?: string[];
  // broadcasts
  notificationId?: string;
  title?: string;
  body?: string;
  topic?: string;
}

/** Where one message goes, and what it says. */
interface Target {
  token?: string;
  topic?: string;
  title: string;
  body: string;
  data: Record<string, string>;
}

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

function serviceAccount(): ServiceAccount | null {
  const raw = (Deno.env.get('FIREBASE_SERVICE_ACCOUNT') ?? '').trim();
  if (!raw) return null;
  try {
    return JSON.parse(raw.startsWith('{') ? raw : atob(raw));
  } catch {
    console.error('FIREBASE_SERVICE_ACCOUNT is not valid JSON');
    return null;
  }
}

const b64url = (data: ArrayBuffer | string) =>
  btoa(typeof data === 'string' ? data : String.fromCharCode(...new Uint8Array(data)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** An OAuth access token for FCM, from the service account (RS256 JWT). */
async function accessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const tokenUri = sa.token_uri || 'https://oauth2.googleapis.com/token';
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: tokenUri,
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch(tokenUri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${b64url(signature)}`,
    }),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok || !data?.access_token) throw new Error(`Firebase sign-in failed (HTTP ${res.status})`);
  return data.access_token;
}

type SendResult = 'sent' | 'invalid_token' | 'retry' | 'error';

async function send(sa: ServiceAccount, auth: string, t: Target): Promise<[SendResult, string?]> {
  const api = Deno.env.get('FCM_API_URL') || 'https://fcm.googleapis.com';
  let res: Response;
  try {
    res = await fetch(`${api}/v1/projects/${sa.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          ...(t.token ? { token: t.token } : { topic: t.topic }),
          notification: { title: t.title, body: t.body },
          data: t.data,
          android: { priority: 'high', notification: { sound: 'default' } },
        },
      }),
    });
  } catch (err) {
    return ['retry', (err as Error).message];
  }
  if (res.ok) {
    await res.body?.cancel();
    return ['sent'];
  }
  const body = await res.json().catch(() => null);
  const status: string = body?.error?.status ?? '';
  const code = JSON.stringify(body?.error?.details ?? '');
  const message = `FCM ${res.status} ${status}`.trim();
  // The app was uninstalled or the token is stale.
  if (res.status === 404 || status === 'NOT_FOUND' || code.includes('UNREGISTERED') ||
      (res.status === 400 && /token/i.test(body?.error?.message ?? ''))) {
    return ['invalid_token', message];
  }
  if (res.status === 429 || res.status >= 500) return ['retry', message];
  return ['error', message];
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Forbidden', { status: 403 });
  const secret = req.headers.get('x-worker-secret');
  if (!secret || (await rpc('platform_worker_check', { p_secret: secret }).catch(() => false)) !== true) {
    return new Response('Forbidden', { status: 403 });
  }
  const sa = serviceAccount();
  if (!sa) {
    return Response.json({ skipped: 'FIREBASE_SERVICE_ACCOUNT is not set' });
  }

  const jobs: Job[] = await rpc('push_claim', { p_limit: 50 });
  if (jobs.length === 0) return Response.json({ processed: [] });

  let auth: string;
  try {
    auth = await accessToken(sa);
  } catch (err) {
    // Nothing was sent: put them back for the next run.
    const error = (err as Error).message;
    await Promise.all(jobs.map((j) => rpc('push_finish', { p_id: j.id, p_sent: 0, p_error: error, p_retry: true })));
    return Response.json({ error }, { status: 502 });
  }

  const processed = [];
  for (const job of jobs) {
    if (job.kind === 'broadcast') {
      // One message to every signed-in customer device.
      const [r, m] = await send(sa, auth, {
        topic: job.topic || 'customers',
        title: job.title ?? '',
        body: job.body ?? '',
        data: { type: 'broadcast', notificationId: job.notificationId ?? '' },
      });
      const finished = await rpc('push_finish', {
        p_id: job.id, p_sent: r === 'sent' ? 1 : 0, p_error: r === 'sent' ? null : m ?? r, p_retry: r === 'retry',
      });
      processed.push({ id: job.id, kind: job.kind, sent: r === 'sent' ? 1 : 0, ...finished });
      continue;
    }
    const text = MESSAGES[job.kind];
    const tokens = job.tokens ?? [];
    if (!text) {
      await rpc('push_finish', { p_id: job.id, p_sent: 0, p_error: `Unknown kind ${job.kind}` });
      continue;
    }
    const results = await Promise.all(tokens.map((token) =>
      send(sa, auth, { token, ...text, data: { type: job.kind, orderId: job.orderId ?? '' } })));
    const sent = results.filter(([r]) => r === 'sent').length;
    const invalid = tokens.filter((_, i) => results[i][0] === 'invalid_token');
    const retry = sent === 0 && results.some(([r]) => r === 'retry');
    const error = sent === 0 ? results.map(([, m]) => m).find(Boolean) ?? null : null;
    const finished = await rpc('push_finish', {
      p_id: job.id, p_sent: sent, p_error: error, p_invalid_tokens: invalid, p_retry: retry,
    });
    processed.push({ id: job.id, kind: job.kind, devices: tokens.length, sent, ...finished });
  }
  return Response.json({ processed });
});
