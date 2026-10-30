// Automatic betting-platform orders through the CashdeskBot API, each on
// its brand's cash register (888STARZ and 1XBET; BRANDS in
// ../_shared/cashdeskbot.ts, order rules in migrations/*_platform_auto.sql).
//
//   withdraw  Baari wallet -> player account: Deposit/{userId}/Add
//   deposit   player account -> Baari wallet: Deposit/{userId}/Payout with
//             the withdrawal code the customer gave us
//
// The database wakes this function (pg_net, right after an order is created,
// and pg_cron every minute while orders wait) with the worker secret it keeps
// in Vault. Each run takes orders one at a time, each exactly once, and
// reports one of: done, refused, not_sent, unclear, low_funds.
//
// low_funds: BAARI's cash register can't cover a withdrawal right now. The
// order waits (the database hands it back every minute, and fails and
// refunds it after an hour); managers linked to the brand's Telegram bot
// are told to top the register up.
//
// Uses each brand's CashdeskBot secrets (../_shared/cashdeskbot.ts), the
// Telegram bot tokens (TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_TOKEN_1XBET) for
// the alerts and, optionally, CASHDESKBOT_LNG (default en).
import {
  ApiError,
  type Brand,
  brandFor,
  brandForMethod,
  depositToPlayer,
  findPlayer,
  credentialsFor,
  payoutToPlayer,
} from '../_shared/cashdeskbot.ts';
import { refreshCompanyBalances } from '../_shared/company_balances.ts';

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
  method: string;
  accountId: string;
  amount: string;
  code: string | null;
}

interface Outcome {
  outcome: 'done' | 'refused' | 'not_sent' | 'unclear' | 'low_funds';
  reference?: string;
  message?: string;
  summa?: number | null;
}

// CashdeskBot answered 401/403/400 or was never reached: nothing happened
// there. Anything else (5xx, timeouts, no answer) may have gone through.
const reachedNothing = (err: unknown) => err instanceof ApiError && err.status !== 502;

// What CashdeskBot says when the register can't cover a deposit, e.g.
// "Deposit limit exceeded. A maximum of 10.29 can be deposited".
const registerShort = (message: string | null) =>
  message != null && /limit exceeded|maximum of|insufficient|not enough|low balance/i.test(message);

const usd = (n: number) => `$${n.toFixed(2)}`;

async function run(job: Job): Promise<Outcome> {
  const brand = await brandFor(job.method);
  if (!brand) return { outcome: 'not_sent', message: `No cash register for ${job.method}` };
  let c;
  try {
    c = await credentialsFor(brand);
  } catch (err) {
    return { outcome: 'not_sent', message: (err as Error).message };
  }

  if (!/^\d{1,15}$/.test(job.accountId)) {
    return { outcome: 'refused', message: `"${job.accountId}" is not a ${brand.label} account ID` };
  }
  try {
    const player = await findPlayer(c, job.accountId);
    if (!player.found) return { outcome: 'refused', message: `${brand.label} account ${job.accountId} was not found` };
  } catch (err) {
    // A lookup is read-only: whatever went wrong, nothing was sent.
    return { outcome: 'not_sent', message: `Player lookup failed: ${(err as Error).message}` };
  }

  try {
    if (job.direction === 'withdraw') {
      const amount = Number(job.amount);
      const r = await depositToPlayer(c, job.accountId, LNG, amount);
      if (r.success) return { outcome: 'done', reference: `${brand.label} deposit ${r.summa ?? job.amount}` };
      if (registerShort(r.message)) return { outcome: 'low_funds', message: `${r.message}; order ${job.orderCode} needs ${usd(amount)}` };
      return { outcome: 'refused', message: r.message ?? `${brand.label} refused the deposit` };
    }
    const r = await payoutToPlayer(c, job.accountId, LNG, job.code!);
    return r.success
      // CashdeskBot reports the payout as negative (money leaving the player).
      ? { outcome: 'done', reference: `${brand.label} code ${job.code}`, summa: r.summa == null ? null : Math.abs(r.summa) }
      : { outcome: 'refused', message: r.message ?? `${brand.label} refused the withdrawal code` };
  } catch (err) {
    return { outcome: reachedNothing(err) ? 'not_sent' : 'unclear', message: (err as Error).message };
  }
}

const TELEGRAM_TOKENS: Record<string, string> = {
  '888starz': 'TELEGRAM_BOT_TOKEN',
  '1xbet': 'TELEGRAM_BOT_TOKEN_1XBET',
  winwin: 'TELEGRAM_BOT_TOKEN_WINWIN',
  betwinner: 'TELEGRAM_BOT_TOKEN_BETWINNER',
  dbbet: 'TELEGRAM_BOT_TOKEN_DBBET',
  betjam: 'TELEGRAM_BOT_TOKEN_BETJAM',
  betongame: 'TELEGRAM_BOT_TOKEN_BETONGAME',
  melbet: 'TELEGRAM_BOT_TOKEN_MELBET',
};

/** Tells the managers, through the brand's bot, to top up its register. */
async function alertManagers(brand: Brand, chatIds: number[], detail: string) {
  const token = Deno.env.get(TELEGRAM_TOKENS[brand.key] ?? '');
  if (!token || chatIds.length === 0) return;
  const text = `⚠️ <b>${brand.label} cash register is low</b>\n` +
    `A customer withdrawal is waiting: ${detail.replace(/[<>&]/g, '')}.\n` +
    `Top up the cash register (check with /balance). The withdrawal is sent automatically once it has enough; ` +
    `after 60 minutes it is failed and refunded.`;
  const api = Deno.env.get('TELEGRAM_API_URL') || 'https://api.telegram.org';
  await Promise.all(chatIds.map((chat_id) =>
    fetch(`${api}/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id, text, parse_mode: 'HTML' }),
    }).then((r) => r.body?.cancel()).catch((err) => console.error('telegram alert', err))
  ));
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Forbidden', { status: 403 });
  const secret = req.headers.get('x-worker-secret');
  if (!secret || (await rpc('platform_worker_check', { p_secret: secret }).catch(() => false)) !== true) {
    return new Response('Forbidden', { status: 403 });
  }

  // Company Balances (Agent App): read the cash registers every few minutes.
  try {
    const due = await rpc('company_balance_due', { p_max_age_seconds: 240 });
    if (due?.length) await refreshCompanyBalances(rpc, due);
  } catch (err) {
    console.error('company balances', (err as Error).message);
  }

  const results: unknown[] = [];
  const shortRegisters = new Set<string>();
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
      if (result.outcome === 'low_funds') shortRegisters.add(job.method);
      // Platforms added in the Agent App have no Telegram bot of their own.
      const bot = brandForMethod(job.method);
      if (finished?.alertTelegramUserIds && bot) {
        await alertManagers(bot, finished.alertTelegramUserIds, result.message ?? '');
      }
    } catch (err) {
      // The order stays claimed; after 10 minutes it goes to an agent.
      console.error(`platform_finish ${job.orderCode}`, result, err);
      results.push({ order: job.orderCode, ...result, error: (err as Error).message });
    }
  }
  // A register just turned out short: show its real balance right away.
  if (shortRegisters.size > 0) await refreshCompanyBalances(rpc, [...shortRegisters]).catch(() => {});
  return new Response(JSON.stringify({ processed: results }), { headers: { 'Content-Type': 'application/json' } });
});
