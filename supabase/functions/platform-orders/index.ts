// Automatic 888STARZ orders through the CashdeskBot API (see
// migrations/*_platform_auto.sql for the order rules).
//
//   withdraw  Baari wallet -> 888starz account: Deposit/{userId}/Add
//   deposit   888starz account -> Baari wallet: Deposit/{userId}/Payout with
//             the withdrawal code the customer gave us
//
// The database wakes this function (pg_net, right after an order is created,
// and pg_cron every minute while orders wait) with the worker secret it keeps
// in Vault. Each run takes orders one at a time, each exactly once, and
// reports one of: done, refused, not_sent, unclear.
//
// Uses the CASHDESKBOT_* secrets (../_shared/cashdeskbot.ts) and, optionally,
// CASHDESKBOT_LNG (default en).
import { ApiError, depositToPlayer, findPlayer, getCredentials, payoutToPlayer } from '../_shared/cashdeskbot.ts';

const LNG = Deno.env.get('CASHDESKBOT_LNG') || 'en';
const MAX_ORDERS_PER_RUN = 20;

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

interface Job {
  orderId: string;
  orderCode: string;
  direction: 'deposit' | 'withdraw';
  accountId: string;
  amount: string;
  code: string | null;
}

interface Outcome {
  outcome: 'done' | 'refused' | 'not_sent' | 'unclear';
  reference?: string;
  message?: string;
  summa?: number | null;
}

// CashdeskBot answered 401/403/400 or was never reached: nothing happened
// there. Anything else (5xx, timeouts, no answer) may have gone through.
const reachedNothing = (err: unknown) => err instanceof ApiError && err.status !== 502;

async function run(job: Job): Promise<Outcome> {
  let c;
  try {
    c = getCredentials();
  } catch (err) {
    return { outcome: 'not_sent', message: (err as Error).message };
  }

  if (!/^\d{1,15}$/.test(job.accountId)) {
    return { outcome: 'refused', message: `"${job.accountId}" is not an 888starz account ID` };
  }
  try {
    const player = await findPlayer(c, job.accountId);
    if (!player.found) return { outcome: 'refused', message: `888starz account ${job.accountId} was not found` };
  } catch (err) {
    // A lookup is read-only: whatever went wrong, nothing was sent.
    return { outcome: 'not_sent', message: `Player lookup failed: ${(err as Error).message}` };
  }

  try {
    if (job.direction === 'withdraw') {
      const r = await depositToPlayer(c, job.accountId, LNG, Number(job.amount));
      return r.success
        ? { outcome: 'done', reference: `888starz deposit ${r.summa ?? job.amount}` }
        : { outcome: 'refused', message: r.message ?? '888starz refused the deposit' };
    }
    const r = await payoutToPlayer(c, job.accountId, LNG, job.code!);
    return r.success
      ? { outcome: 'done', reference: `888starz code ${job.code}`, summa: r.summa }
      : { outcome: 'refused', message: r.message ?? '888starz refused the withdrawal code' };
  } catch (err) {
    return { outcome: reachedNothing(err) ? 'not_sent' : 'unclear', message: (err as Error).message };
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Forbidden', { status: 403 });
  const secret = req.headers.get('x-worker-secret');
  if (!secret || (await rpc('platform_worker_check', { p_secret: secret }).catch(() => false)) !== true) {
    return new Response('Forbidden', { status: 403 });
  }

  const results: unknown[] = [];
  for (let i = 0; i < MAX_ORDERS_PER_RUN; i++) {
    const job: Job | null = await rpc('platform_claim_next', {});
    if (!job) break;
    const result = await run(job);
    try {
      const finished = await rpc('platform_finish', {
        p_order_id: job.orderId,
        p_outcome: result.outcome,
        p_reference: result.reference ?? null,
        p_message: result.message ?? null,
        p_summa: result.summa ?? null,
      });
      results.push({ order: job.orderCode, ...result, ...finished });
    } catch (err) {
      // The order stays claimed; after 10 minutes it goes to an agent.
      console.error(`platform_finish ${job.orderCode}`, result, err);
      results.push({ order: job.orderCode, ...result, error: (err as Error).message });
    }
  }
  return new Response(JSON.stringify({ processed: results }), { headers: { 'Content-Type': 'application/json' } });
});
