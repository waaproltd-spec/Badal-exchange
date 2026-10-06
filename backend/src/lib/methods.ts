/**
 * Payment methods a customer can deposit from / withdraw to.
 *
 * Two families, each with its own counterparty field and verification flow:
 *  - mobile_money: the customer's phone number on that mobile-money service.
 *    Deposits are matched by sender phone + amount, either from an agent
 *    device's payment SMS (EVC Plus) or a payment an agent confirms by hand.
 *  - platform: the customer's account ID on a betting platform, operated by
 *    an agent through that platform's cashier/manager tools. Deposits carry a
 *    short deposit code and are matched by account ID + amount (+ code) once
 *    an agent confirms the real top-up.
 *
 * Keep in sync with the `order_method` Postgres enum (migrations 001, 004)
 * and the method lists in the customer app, agent app and admin dashboard.
 */
export const MOBILE_MONEY_METHODS = ['evc_plus', 'golis', 'telesom', 'edahab'] as const;
export const PLATFORM_METHODS = ['winwin', 'onexbet', 'melbet', 'betwinner', 'dbbet', '888starz'] as const;
export const METHODS = [...MOBILE_MONEY_METHODS, ...PLATFORM_METHODS] as const;

export type MobileMoneyMethod = (typeof MOBILE_MONEY_METHODS)[number];
export type PlatformMethod = (typeof PLATFORM_METHODS)[number];
export type Method = (typeof METHODS)[number];

export const METHOD_LABELS: Record<Method, string> = {
  evc_plus: 'EVC Plus',
  golis: 'Golis',
  telesom: 'Telesom',
  edahab: 'eDahab',
  winwin: 'WinWin',
  onexbet: '1XBET',
  melbet: 'MELBET',
  betwinner: 'Betwinner',
  dbbet: 'DBbet',
  '888starz': '888STARZ',
};

export function isMethod(value: unknown): value is Method {
  return typeof value === 'string' && (METHODS as readonly string[]).includes(value);
}

export function isMobileMoney(method: string): method is MobileMoneyMethod {
  return (MOBILE_MONEY_METHODS as readonly string[]).includes(method);
}

export function isPlatform(method: string): method is PlatformMethod {
  return (PLATFORM_METHODS as readonly string[]).includes(method);
}

/**
 * Maps the `provider` an agent device reports with a payment SMS to the
 * mobile-money method it belongs to. Agent apps report the method id itself
 * (e.g. 'evc_plus'); the long-form names are accepted for older clients.
 * Unknown providers fall back to EVC Plus, the only SMS feed that existed
 * before more methods were added.
 */
export function methodForSmsProvider(provider: string): MobileMoneyMethod {
  if (isMobileMoney(provider)) return provider;
  const aliases: Record<string, MobileMoneyMethod> = {
    hormuud_evc_plus: 'evc_plus',
    golis_sahal: 'golis',
    telesom_zaad: 'telesom',
    somtel_edahab: 'edahab',
  };
  return aliases[provider] ?? 'evc_plus';
}
