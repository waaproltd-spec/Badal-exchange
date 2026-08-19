// Amounts arrive from the API as already-formatted decimal strings
// (e.g. "12.55"); we only prefix a currency symbol for display, never
// re-parse or do cents math on the frontend.
export function money(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return '$0.00';
  return `$${value}`;
}

export function dateTime(value: string | null | undefined): string {
  if (!value) return '—';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function dateOnly(value: string | null | undefined): string {
  if (!value) return '—';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

export function methodLabel(method: string): string {
  return method === 'evc_plus' ? 'EVC Plus' : method === 'winwin' ? 'WinWin' : method;
}

export function titleCase(value: string): string {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

export function shortId(id: string | null | undefined): string {
  if (!id) return '—';
  return id.slice(0, 8);
}
