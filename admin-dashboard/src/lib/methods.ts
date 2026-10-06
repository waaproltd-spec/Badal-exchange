import type { OrderMethod } from '../api/types';

// Mirrors backend/src/lib/methods.ts.
export const METHODS: { method: OrderMethod; label: string }[] = [
  { method: 'evc_plus', label: 'EVC Plus' },
  { method: 'golis', label: 'Golis' },
  { method: 'telesom', label: 'Telesom' },
  { method: 'edahab', label: 'eDahab' },
  { method: 'winwin', label: 'WinWin' },
  { method: 'onexbet', label: '1XBET' },
  { method: 'melbet', label: 'MELBET' },
  { method: 'betwinner', label: 'Betwinner' },
  { method: 'dbbet', label: 'DBbet' },
  { method: '888starz', label: '888STARZ' },
];
