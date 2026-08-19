export function Loading({ label = 'Loading…' }: { label?: string }) {
  return <div className="loading-state">{label}</div>;
}

export function ErrorState({ message }: { message: string }) {
  return <div className="error-banner">{message}</div>;
}

export function EmptyState({ message }: { message: string }) {
  return <div className="empty-state">{message}</div>;
}
