import { api } from './client';
import type {
  AgentDevice,
  AgentListItem,
  AuditLog,
  CustomerDetail,
  CustomerListItem,
  DailyReportRow,
  DashboardSummary,
  ExchangeRate,
  Fee,
  LoginResponse,
  Order,
  OrderDirection,
  OrderStatus,
  PaymentIntegration,
  Transaction,
  Wallet,
  LedgerEntry,
  WithdrawalLimit,
  IntegrationProvider,
  OrderMethod,
  WinwinConfirmationInput,
  WinwinConfirmationResult,
  AutomationRun,
  MobCashLoginCheckResult,
} from './types';

export function adminLogin(phone: string, password: string) {
  return api.post<LoginResponse>('/auth/admin/login', { phone, password });
}

export function getDashboardSummary() {
  return api.get<DashboardSummary>('/admin/dashboard/summary');
}

export function listCustomers(q?: string) {
  return api.get<CustomerListItem[]>('/admin/customers', { q });
}

export function getCustomer(id: string) {
  return api.get<CustomerDetail>(`/admin/customers/${id}`);
}

export function listAgents() {
  return api.get<AgentListItem[]>('/admin/agents');
}

export function createAgent(input: { phone: string; name: string; password: string; responsibilities?: string[] }) {
  return api.post<AgentListItem>('/admin/agents', input);
}

export function enableAgent(id: string) {
  return api.post<{ id: string; status: string }>(`/admin/agents/${id}/enable`);
}

export function disableAgent(id: string) {
  return api.post<{ id: string; status: string }>(`/admin/agents/${id}/disable`);
}

export function getAgentTransactions(id: string) {
  return api.get<Order[]>(`/admin/agents/${id}/transactions`);
}

export function getAgentDevices(id: string) {
  return api.get<AgentDevice[]>(`/admin/agents/${id}/devices`);
}

export function listWallets() {
  return api.get<Wallet[]>('/admin/wallets');
}

export function getWalletLedger(customerId: string) {
  return api.get<LedgerEntry[]>(`/admin/wallets/${customerId}/ledger`);
}

export function listDeposits(status?: OrderStatus) {
  return api.get<Order[]>('/admin/deposits', { status });
}

export function listWithdrawals(status?: OrderStatus) {
  return api.get<Order[]>('/admin/withdrawals', { status });
}

export function listOrders(status?: OrderStatus) {
  return api.get<Order[]>('/admin/orders', { status });
}

export function getOrder(id: string) {
  return api.get<Order>(`/admin/orders/${id}`);
}

export function listTransactions() {
  return api.get<Transaction[]>('/admin/transactions');
}

export function getExchangeRates() {
  return api.get<ExchangeRate[]>('/admin/exchange-rates');
}

export function updateExchangeRate(input: { method: OrderMethod; direction: OrderDirection; rate: number }) {
  return api.put<ExchangeRate>('/admin/exchange-rates', input);
}

export function getFees() {
  return api.get<Fee[]>('/admin/fees');
}

export function updateFee(input: { method: OrderMethod; direction: OrderDirection; feeType: 'flat' | 'percent'; value: number }) {
  return api.put<Fee>('/admin/fees', input);
}

export function updateWithdrawalLimits(input: { method: OrderMethod; minAmount: number; maxAmount: number }) {
  return api.put<WithdrawalLimit>('/admin/withdrawal-limits', input);
}

export function listAuditLogs() {
  return api.get<AuditLog[]>('/admin/audit-logs');
}

export function getDailyReports() {
  return api.get<DailyReportRow[]>('/admin/reports/daily');
}

export function listPaymentIntegrations() {
  return api.get<PaymentIntegration[]>('/admin/payment-integrations');
}

export function getPaymentIntegration(provider: IntegrationProvider) {
  return api.get<PaymentIntegration>(`/admin/payment-integrations/${provider}`);
}

export function updateIntegrationCredentials(
  provider: IntegrationProvider,
  input: { username: string; password: string; config?: Record<string, unknown> }
) {
  return api.put<PaymentIntegration>(`/admin/payment-integrations/${provider}/credentials`, input);
}

export function setIntegrationStatus(provider: IntegrationProvider, status: 'active' | 'inactive') {
  return api.put<PaymentIntegration>(`/admin/payment-integrations/${provider}/status`, { status });
}

export function testIntegrationConnection(provider: IntegrationProvider) {
  return api.post<PaymentIntegration>(`/admin/payment-integrations/${provider}/test-connection`);
}

/**
 * Manual WinWin/MobCash confirmation: an admin has personally observed a
 * real, completed "Top up WebUser" deposit in the WinWin manager app and
 * keys the result in here. Requires a fresh Idempotency-Key per submission
 * so a retried request never double-credits a wallet.
 */
export function submitWinwinConfirmation(input: WinwinConfirmationInput) {
  const idempotencyKey = crypto.randomUUID();
  return api.post<WinwinConfirmationResult>('/admin/winwin-transactions', input, {
    'Idempotency-Key': idempotencyKey,
  });
}

/**
 * Backend-driven browser automation of MobCash Business Web (no official
 * API is confirmed to exist -- see the note on the MobCash Manager page).
 * Enabling 'automatic' requires credentials to already be saved; dryRun
 * defaults true and must be turned off as a separate, deliberate step.
 */
export function setAutomationMode(provider: IntegrationProvider, mode: 'manual' | 'automatic', dryRun: boolean) {
  return api.put<PaymentIntegration>(`/admin/payment-integrations/${provider}/automation`, { mode, dryRun });
}

export function resetCircuitBreaker(provider: IntegrationProvider) {
  return api.post<PaymentIntegration>(`/admin/payment-integrations/${provider}/reset-circuit-breaker`);
}

export function listAutomationRuns(provider: IntegrationProvider) {
  return api.get<AutomationRun[]>(`/admin/payment-integrations/${provider}/automation-runs`);
}

/**
 * Real browser-automation login attempt against MobCash Business Web with
 * credentials the admin just typed (not yet saved). On success returns
 * whatever EPOS accounts the real portal reports -- never fabricated.
 */
export function checkMobCashLogin(username: string, password: string) {
  return api.post<MobCashLoginCheckResult>('/admin/payment-integrations/mobcash_winwin/login-check', {
    username,
    password,
  });
}
