export function StatusBadge({ status }: { status: string }) {
  const normalized = status?.toLowerCase() ?? 'unknown';
  return <span className={`badge badge-${normalized}`}>{normalized.replace(/_/g, ' ')}</span>;
}
