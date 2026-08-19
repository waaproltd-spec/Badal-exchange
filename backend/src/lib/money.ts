/**
 * All money is handled as integer minor units (cents) end-to-end to avoid
 * floating point drift. API request/response bodies use decimal strings.
 */

export function toCents(decimalAmount: number | string): number {
  const n = typeof decimalAmount === 'string' ? Number(decimalAmount) : decimalAmount;
  if (!Number.isFinite(n) || n < 0) {
    throw new Error(`Invalid amount: ${decimalAmount}`);
  }
  return Math.round(n * 100);
}

export function fromCents(cents: number | string): string {
  const n = typeof cents === 'string' ? parseInt(cents, 10) : cents;
  return (n / 100).toFixed(2);
}

export function applyFee(
  amountCents: number,
  feeType: 'flat' | 'percent',
  value: number
): number {
  const fee = feeType === 'flat' ? Math.round(value) : Math.round((amountCents * value) / 100);
  return Math.max(0, fee);
}
