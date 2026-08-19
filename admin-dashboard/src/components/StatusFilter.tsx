import type { OrderStatus } from '../api/types';

const STATUSES: OrderStatus[] = ['pending', 'processing', 'completed', 'failed', 'cancelled', 'expired'];

export function StatusFilter({ value, onChange }: { value: OrderStatus | ''; onChange: (v: OrderStatus | '') => void }) {
  return (
    <select className="search-input" style={{ width: 180 }} value={value} onChange={(e) => onChange(e.target.value as OrderStatus | '')}>
      <option value="">All statuses</option>
      {STATUSES.map((s) => (
        <option key={s} value={s}>
          {s[0].toUpperCase() + s.slice(1)}
        </option>
      ))}
    </select>
  );
}
