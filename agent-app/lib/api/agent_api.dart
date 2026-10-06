import 'package:uuid/uuid.dart';

import '../models/agent_profile.dart';
import '../models/match_result.dart';
import '../models/console.dart';
import '../models/management.dart';
import '../models/payment_methods.dart';
import '../models/order.dart';
import 'api_client.dart';
import 'token_storage.dart';

/// Result of a login call: the raw fields the backend returns from
/// POST /auth/agent/login, kept together so main.dart/login screen can
/// decide what to persist.
class LoginResult {
  final String userId;
  final String name;
  final String accessToken;
  final String refreshToken;

  const LoginResult({
    required this.userId,
    required this.name,
    required this.accessToken,
    required this.refreshToken,
  });
}

/// Typed wrapper around every `/agent` (and the agent-relevant `/auth`)
/// endpoint the app needs. Keeps request/response shaping in one place so
/// screens only ever deal with typed models.
class AgentApi {
  AgentApi({ApiClient? client, TokenStorage? tokenStorage})
      : _client = client ?? ApiClient(),
        _tokens = tokenStorage ?? TokenStorage.instance;

  final ApiClient _client;
  final TokenStorage _tokens;
  final Uuid _uuid = const Uuid();

  ApiClient get client => _client;

  Future<LoginResult> login({required String phone, required String password}) async {
    final data = await _client.postPublic('/auth/agent/login', {
      'phone': phone,
      'password': password,
    });
    final user = data['user'] as Map<String, dynamic>;
    return LoginResult(
      userId: user['id'] as String,
      name: user['name'] as String? ?? '',
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
  }

  Future<void> registerDevice({required String deviceId, String? deviceLabel}) async {
    await _client.post('/agent/devices/register', body: {
      'deviceId': deviceId,
      if (deviceLabel != null) 'deviceLabel': deviceLabel,
    });
  }

  Future<List<Order>> getPendingDeposits() async {
    final data = await _client.get('/agent/deposits/pending') as List<dynamic>;
    return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Order>> getPendingWithdrawals() async {
    final data = await _client.get('/agent/withdrawals/pending') as List<dynamic>;
    return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Order>> getCompletedOrders() async {
    final data = await _client.get('/agent/orders/completed') as List<dynamic>;
    return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Order>> getFailedOrders() async {
    final data = await _client.get('/agent/orders/failed') as List<dynamic>;
    return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<AgentProfile> getProfile() async {
    final data = await _client.get('/agent/profile') as Map<String, dynamic>;
    return AgentProfile.fromJson(data);
  }

  /// Submits the minimal fields extracted from an authorized EVC Plus
  /// payment SMS. Never pass the raw SMS body here — only the extracted
  /// facts, per the backend contract.
  Future<MatchResult> submitSmsTransaction({
    required String provider,
    String? sender,
    String? receiver,
    required String amount,
    required String transactionRef,
    required DateTime occurredAt,
    String? deviceId,
  }) async {
    final data = await _client.post(
      '/agent/sms-transactions',
      idempotencyKey: _uuid.v4(),
      body: {
        'provider': provider,
        if (sender != null) 'sender': sender,
        if (receiver != null) 'receiver': receiver,
        'amount': amount,
        'transactionRef': transactionRef,
        'occurredAt': occurredAt.toUtc().toIso8601String(),
        if (deviceId != null) 'deviceId': deviceId,
      },
    ) as Map<String, dynamic>;
    return MatchResult.fromJson(data);
  }

  /// Submits a WinWin/MobCash deposit confirmation the agent manually keyed
  /// in after observing the real transaction in the WinWin manager app.
  Future<MatchResult> submitWinwinTransaction({
    required String winwinId,
    String? depositCode,
    required String amount,
    required String mobcashRef,
    required DateTime occurredAt,
  }) async {
    final data = await _client.post(
      '/agent/winwin-transactions',
      idempotencyKey: _uuid.v4(),
      body: {
        'winwinId': winwinId,
        if (depositCode != null && depositCode.isNotEmpty) 'depositCode': depositCode,
        'amount': amount,
        'mobcashRef': mobcashRef,
        'occurredAt': occurredAt.toUtc().toIso8601String(),
      },
    ) as Map<String, dynamic>;
    return MatchResult.fromJson(data);
  }

  /// Mobile-money payment (EVC Plus, Golis, Telesom, eDahab) the agent saw
  /// arrive and keys in by hand. Deduped with SMS-reported payments.
  Future<MatchResult> submitMobileMoneyTransaction({
    required String method,
    required String senderPhone,
    required String amount,
    required String transactionRef,
    required DateTime occurredAt,
  }) async {
    final data = await _client.post(
      '/agent/mobile-money-transactions',
      idempotencyKey: _uuid.v4(),
      body: {
        'method': method,
        'senderPhone': senderPhone,
        'amount': amount,
        'transactionRef': transactionRef,
        'occurredAt': occurredAt.toUtc().toIso8601String(),
      },
    ) as Map<String, dynamic>;
    return MatchResult.fromJson(data);
  }

  /// Betting-platform deposit (WinWin, 1XBET, MELBET, ...) the agent
  /// confirmed in that platform's cashier tools.
  Future<MatchResult> submitPlatformTransaction({
    required String method,
    required String accountId,
    String? depositCode,
    required String amount,
    required String reference,
    required DateTime occurredAt,
  }) async {
    final data = await _client.post(
      '/agent/platform-transactions',
      idempotencyKey: _uuid.v4(),
      body: {
        'method': method,
        'accountId': accountId,
        if (depositCode != null && depositCode.isNotEmpty) 'depositCode': depositCode,
        'amount': amount,
        'reference': reference,
        'occurredAt': occurredAt.toUtc().toIso8601String(),
      },
    ) as Map<String, dynamic>;
    return MatchResult.fromJson(data);
  }

  // ---------------------------------------------------------------------
  // Console: Dashboard, Users, Reports, History, Account
  // ---------------------------------------------------------------------

  Future<DashboardSummary> getDashboard() async {
    final data = await _client.get('/agent/dashboard') as Map<String, dynamic>;
    return DashboardSummary.fromJson(data);
  }

  Future<List<CustomerSummary>> getCustomers({
    String? query,
    String status = 'all',
    String sort = 'newest',
    int offset = 0,
  }) async {
    final data = await _client.get('/agent/customers', query: {
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      'status': status,
      'sort': sort,
      'offset': '$offset',
    }) as List<dynamic>;
    return data.map((e) => CustomerSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<CustomerDetail> getCustomer(String id) async {
    final data = await _client.get('/agent/customers/$id') as Map<String, dynamic>;
    return CustomerDetail.fromJson(data);
  }

  Future<List<LedgerEntry>> getCustomerLedger(String id) async {
    final data = await _client.get('/agent/customers/$id/ledger') as List<dynamic>;
    return data.map((e) => LedgerEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ReportSummary> getReport({required String period, String? from, String? to}) async {
    final data = await _client.get('/agent/reports', query: {
      'period': period,
      if (from != null) 'from': from,
      if (to != null) 'to': to,
    }) as Map<String, dynamic>;
    return ReportSummary.fromJson(data);
  }

  Future<List<HistoryItem>> getHistory({
    String? query,
    String type = 'all',
    String? status,
    String? method,
    String? customerId,
    String? from,
    String? to,
    int offset = 0,
    int limit = 50,
  }) async {
    final data = await _client.get('/agent/history', query: {
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      'type': type,
      if (status != null) 'status': status,
      if (method != null) 'method': method,
      if (customerId != null) 'customerId': customerId,
      if (from != null) 'from': from,
      if (to != null) 'to': to,
      'offset': '$offset',
      'limit': '$limit',
    }) as List<dynamic>;
    return data.map((e) => HistoryItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<AgentAccount> getAccount() async {
    final data = await _client.get('/agent/account') as Map<String, dynamic>;
    return AgentAccount.fromJson(data);
  }

  Future<void> changePassword({required String currentPassword, required String newPassword}) async {
    await _client.post('/agent/account/password', body: {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
  }

  // Admin features (require the 'manage_settings' responsibility).

  /// Loads the shared payment-method catalog from the backend (public
  /// endpoint). Keeps the bundled list if the backend can't be reached.
  Future<void> loadMethodCatalog() async {
    try {
      final data = await _client.getPublic('/meta/payment-methods');
      if (data is List<dynamic>) applyPaymentMethodCatalog(data);
    } catch (_) {}
  }

  /// Every method with ON/OFF, rates, fees and withdrawal limits.
  Future<List<MethodSettings>> getMethodSettings() async {
    final data = await _client.get('/agent/manage/payment-methods') as List<dynamic>;
    return data.map((e) => MethodSettings.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> setMethodEnabled(String method, bool enabled) async {
    await _client.put('/agent/manage/payment-methods/$method', body: {'enabled': enabled});
  }

  /// New exchange rate for one method/direction (past orders keep theirs).
  Future<void> setRate(String method, String direction, double rate) async {
    await _client.put('/admin/exchange-rates', body: {'method': method, 'direction': direction, 'rate': rate});
  }

  /// [value] is dollars for a flat fee (sent as cents) or 0-100 for percent.
  Future<void> setFee(String method, String direction, {required String type, required double value}) async {
    await _client.put('/admin/fees', body: {
      'method': method,
      'direction': direction,
      'feeType': type,
      'value': type == 'flat' ? (value * 100).round() : value,
    });
  }

  /// Withdrawal limits in dollars.
  Future<void> setWithdrawalLimits(String method, {required double min, required double max}) async {
    await _client.put('/admin/withdrawal-limits', body: {'method': method, 'minAmount': min, 'maxAmount': max});
  }

  // Agents

  Future<List<AgentListItem>> getAgents() async {
    final data = await _client.get('/admin/agents') as List<dynamic>;
    return data.map((e) => AgentListItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> createAgent({
    required String name,
    required String phone,
    required String password,
    required List<String> responsibilities,
  }) async {
    await _client.post('/admin/agents', body: {
      'name': name,
      'phone': phone,
      'password': password,
      'responsibilities': responsibilities,
    });
  }

  Future<void> setAgentEnabled(String id, bool enabled) async {
    await _client.post('/admin/agents/$id/${enabled ? 'enable' : 'disable'}');
  }

  Future<void> setAgentResponsibilities(String id, List<String> responsibilities) async {
    await _client.put('/admin/agents/$id/responsibilities', body: {'responsibilities': responsibilities});
  }

  Future<List<AgentDevice>> getAgentDevices(String id) async {
    final data = await _client.get('/admin/agents/$id/devices') as List<dynamic>;
    return data.map((e) => AgentDevice.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Orders this agent verified or processed.
  Future<List<Order>> getAgentOrders(String id) async {
    final data = await _client.get('/admin/agents/$id/transactions') as List<dynamic>;
    return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  // Payment integrations (EVC Plus, MobCash/WinWin)

  Future<List<PaymentIntegration>> getIntegrations() async {
    final data = await _client.get('/admin/payment-integrations') as List<dynamic>;
    return data.map((e) => PaymentIntegration.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PaymentIntegration> getIntegration(String provider) async {
    final data = await _client.get('/admin/payment-integrations/$provider') as Map<String, dynamic>;
    return PaymentIntegration.fromJson(data);
  }

  Future<void> saveIntegrationCredentials(String provider, {required String username, required String password}) async {
    await _client.put('/admin/payment-integrations/$provider/credentials', body: {
      'username': username,
      'password': password,
    });
  }

  Future<void> setIntegrationActive(String provider, bool active) async {
    await _client.put('/admin/payment-integrations/$provider/status', body: {'status': active ? 'active' : 'inactive'});
  }

  Future<void> testIntegration(String provider) async {
    await _client.post('/admin/payment-integrations/$provider/test-connection');
  }

  /// Real login attempt on MobCash with credentials that aren't saved yet.
  Future<MobCashLoginCheck> checkMobCashLogin({required String username, required String password}) async {
    final data = await _client.post('/admin/payment-integrations/mobcash_winwin/login-check', body: {
      'username': username,
      'password': password,
    }) as Map<String, dynamic>;
    return MobCashLoginCheck.fromJson(data);
  }

  Future<void> setAutomationMode(String provider, {required String mode, required bool dryRun}) async {
    await _client.put('/admin/payment-integrations/$provider/automation', body: {'mode': mode, 'dryRun': dryRun});
  }

  Future<void> resetCircuitBreaker(String provider) async {
    await _client.post('/admin/payment-integrations/$provider/reset-circuit-breaker');
  }

  Future<List<AutomationRun>> getAutomationRuns(String provider) async {
    final data = await _client.get('/admin/payment-integrations/$provider/automation-runs') as List<dynamic>;
    return data.map((e) => AutomationRun.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Base64 PNG of the portal at the end of an automation run, if kept.
  Future<String> getAutomationRunScreenshot(String provider, String runId) async {
    final data = await _client.get('/admin/payment-integrations/$provider/automation-runs/$runId/screenshot')
        as Map<String, dynamic>;
    return data['screenshotBase64'] as String;
  }

  /// Latest wallet ledger entries across all customers.
  Future<List<WalletTransaction>> getAllWalletTransactions() async {
    final data = await _client.get('/admin/transactions') as List<dynamic>;
    return data.map((e) => WalletTransaction.fromJson(e as Map<String, dynamic>)).toList();
  }

  // Audit

  Future<List<AuditLog>> getAuditLogs() async {
    final data = await _client.get('/admin/audit-logs') as List<dynamic>;
    return data.map((e) => AuditLog.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<HomeAd>> getHomeAds() async {
    final data = await _client.get('/agent/manage/home-ads') as List<dynamic>;
    return data.map((e) => HomeAd.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveHomeAd({
    String? id,
    required String title,
    String? body,
    String? imageUrl,
    String? linkUrl,
    required bool enabled,
    int sortOrder = 0,
  }) async {
    final payload = {
      'title': title,
      'body': body,
      'imageUrl': imageUrl,
      'linkUrl': linkUrl,
      'enabled': enabled,
      'sortOrder': sortOrder,
    };
    if (id == null) {
      await _client.post('/agent/manage/home-ads', body: payload);
    } else {
      await _client.put('/agent/manage/home-ads/$id', body: payload);
    }
  }

  Future<void> deleteHomeAd(String id) => _client.delete('/agent/manage/home-ads/$id');

  Future<List<DepositNumber>> getDepositNumbers() async {
    final data = await _client.get('/agent/manage/deposit-numbers') as List<dynamic>;
    return data.map((e) => DepositNumber.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveDepositNumber({
    String? id,
    required String method,
    required String number,
    String? label,
    required bool enabled,
  }) async {
    final payload = {'method': method, 'number': number, 'label': label, 'enabled': enabled};
    if (id == null) {
      await _client.post('/agent/manage/deposit-numbers', body: payload);
    } else {
      await _client.put('/agent/manage/deposit-numbers/$id', body: payload);
    }
  }

  Future<void> deleteDepositNumber(String id) => _client.delete('/agent/manage/deposit-numbers/$id');

  Future<List<AppNotification>> getSentNotifications() async {
    final data = await _client.get('/agent/manage/notifications') as List<dynamic>;
    return data.map((e) => AppNotification.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> sendNotification({required String title, required String body}) async {
    await _client.post('/agent/manage/notifications', body: {'title': title, 'body': body});
  }

  Future<Contacts> saveContacts(Contacts contacts) async {
    final data = await _client.put('/agent/manage/contacts', body: contacts.toJson());
    return Contacts.fromJson(data);
  }

  Future<Order> startWithdrawal(String orderId) async {
    final data = await _client.post('/agent/withdrawals/$orderId/start') as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  Future<Order> completeWithdrawal(String orderId, {required String transactionRef}) async {
    final data = await _client.post(
      '/agent/withdrawals/$orderId/complete',
      idempotencyKey: _uuid.v4(),
      body: {'transactionRef': transactionRef},
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  Future<Order> failWithdrawal(String orderId, {required String reason}) async {
    final data = await _client.post(
      '/agent/withdrawals/$orderId/fail',
      body: {'reason': reason},
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  Future<void> logout() async {
    final refreshToken = await _tokens.refreshToken;
    try {
      if (refreshToken != null) {
        await _client.postPublic('/auth/logout', {'refreshToken': refreshToken});
      }
    } catch (_) {
      // Best-effort server-side revoke; local session clear happens
      // regardless so the agent is always able to log out.
    }
    await _tokens.clear();
  }
}
