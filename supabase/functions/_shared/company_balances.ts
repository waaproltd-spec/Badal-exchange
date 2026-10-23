// Reads the cash register balance of each connected company (CashdeskBot:
// 888STARZ, 1XBET) and records every read -- the amount, or why there is
// none -- with the database's company_balance_record (service role). Used
// by the company-balances function (Agent App) and the platform-orders
// worker (every 5 minutes, and after a withdrawal waits for a top-up).
import { brandForMethod, cashdeskBalance, getCredentials } from './cashdeskbot.ts';

export type ServiceRpc = (fn: string, args: Record<string, unknown>) => Promise<unknown>;

const num = (v: unknown) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));

export async function refreshCompanyBalances(rpc: ServiceRpc, methods: string[], requestedBy: string | null = null) {
  await Promise.all(methods.map(async (method) => {
    const brand = brandForMethod(method);
    let balance: number | null = null;
    let limit: number | null = null;
    let error: string | null = null;
    if (!brand) {
      error = `No cash register for ${method}`;
    } else {
      try {
        const r = await cashdeskBalance(getCredentials(brand), new Date());
        balance = num(r.balance);
        limit = num(r.limit);
        if (balance === null) error = `${brand.label} did not return a balance`;
      } catch (err) {
        error = (err as Error).message;
      }
    }
    try {
      await rpc('company_balance_record', {
        p_method: method, p_balance: balance, p_limit: limit, p_error: error, p_requested_by: requestedBy,
      });
    } catch (err) {
      console.error('company_balance_record', method, (err as Error).message);
    }
  }));
}
