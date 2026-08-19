// Types mirror the exact JSON shapes returned by backend/src/routes/admin.ts
// and backend/src/routes/auth.ts. Money fields are already-formatted decimal
// strings (e.g. "12.55") server-side -- never re-parsed as cents here.

export type OrderDirection = 'deposit' | 'withdraw';
export type OrderMethod = 'evc_plus' | 'winwin';
export type OrderStatus = 'pending' | 'processing' | 'completed' | 'failed' | 'cancelled' | 'expired';
export type UserStatus = 'active' | 'disabled';

export interface AdminUser {
  id: string;
  role: 'admin';
  name?: string;
}

export interface LoginResponse {
  user: AdminUser;
  accessToken: string;
  refreshToken: string;
}

export interface DashboardSummary {
  totalCustomers: number;
  totalWalletBalance: string;
  totalWalletPending: string;
  todaysDeposits: string;
  todaysWithdrawals: string;
  pendingDeposits: number;
  pendingWithdrawals: number;
  completedTransactions: number;
  failedTransactions: number;
}

export interface CustomerListItem {
  id: string;
  name: string | null;
  phone: string | null;
  status: UserStatus;
  walletBalance: string;
  totalDeposits: string;
  totalWithdrawals: string;
  registeredAt: string;
}

export interface CustomerDetail {
  id: string;
  name: string | null;
  phone: string | null;
  status: UserStatus;
  wallet: {
    availableBalance: string;
    pendingBalance: string;
    totalDeposit: string;
    totalWithdraw: string;
  };
  registeredAt: string;
}

export interface AgentListItem {
  id: string;
  name: string | null;
  phone: string | null;
  status: UserStatus;
  created_at: string;
  responsibilities: string[] | null;
  last_seen_at: string | null;
  last_device_id: string | null;
}

export interface Order {
  id: string;
  orderCode: string;
  direction: OrderDirection;
  method: OrderMethod;
  status: OrderStatus;
  customerId: string;
  agentId: string | null;
  phoneNumber: string | null;
  winwinId: string | null;
  amount: string;
  fee: string;
  netAmount: string;
  transactionRef: string | null;
  createdAt: string;
  completedAt: string | null;
}

export interface AgentDevice {
  device_id: string;
  device_label: string | null;
  status: string;
  registered_at: string;
  last_seen_at: string | null;
}

export interface Wallet {
  customerId: string;
  name: string | null;
  phone: string | null;
  availableBalance: string;
  pendingBalance: string;
  totalDeposit: string;
  totalWithdraw: string;
}

export interface LedgerEntry {
  id: string;
  orderId: string | null;
  type: 'credit' | 'debit' | 'reserve' | 'release';
  amount: string;
  balanceAfter: string;
  reason: string;
  createdAt: string;
}

export interface Transaction {
  id: string;
  customerId: string;
  orderId: string | null;
  type: 'credit' | 'debit' | 'reserve' | 'release';
  amount: string;
  balanceAfter: string;
  reason: string;
  createdAt: string;
}

export interface ExchangeRate {
  id: string;
  method: OrderMethod;
  direction: OrderDirection;
  rate: string;
  active: boolean;
  created_by: string | null;
  created_at: string;
}

export interface Fee {
  id: string;
  method: OrderMethod;
  direction: OrderDirection;
  fee_type: 'flat' | 'percent';
  value: string;
  active: boolean;
  created_by: string | null;
  created_at: string;
}

export interface WithdrawalLimit {
  id: string;
  method: OrderMethod;
  min_cents: number;
  max_cents: number;
  updated_at: string;
}

export interface AuditLog {
  id: string;
  actor_id: string | null;
  actor_role: 'customer' | 'agent' | 'admin' | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  before_json: unknown;
  after_json: unknown;
  ip: string | null;
  created_at: string;
}

export interface DailyReportRow {
  day: string;
  direction: OrderDirection;
  method: OrderMethod;
  status: OrderStatus;
  count: number;
  amount: string;
}

export type IntegrationProvider = 'evc_plus' | 'mobcash_winwin';

export interface PaymentIntegration {
  provider: IntegrationProvider;
  status: 'active' | 'inactive';
  configJson: Record<string, unknown>;
  hasCredentials: boolean;
  username: string | null;
  lastTestAt: string | null;
  lastTestResult: 'success' | 'failed' | 'not_configured' | null;
  lastTestMessage: string | null;
  lastSuccessfulConnectionAt: string | null;
  lastTransactionAt: string | null;
  updatedAt: string;
}

export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
    details?: unknown;
  };
}
