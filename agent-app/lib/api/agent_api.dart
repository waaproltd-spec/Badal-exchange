import 'package:uuid/uuid.dart';

import '../models/agent_profile.dart';
import '../models/match_result.dart';
import '../models/console.dart';
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

  Future<List<CustomerSummary>> getCustomers({String? query, String status = 'all', int offset = 0}) async {
    final data = await _client.get('/agent/customers', query: {
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      'status': status,
      'offset': '$offset',
    }) as List<dynamic>;
    return data.map((e) => CustomerSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<CustomerDetail> getCustomer(String id) async {
    final data = await _client.get('/agent/customers/$id') as Map<String, dynamic>;
    return CustomerDetail.fromJson(data);
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

  Future<List<ManagedMethod>> getManagedMethods() async {
    final data = await _client.get('/agent/manage/payment-methods') as List<dynamic>;
    return data.map((e) => ManagedMethod.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> setMethodEnabled(String method, bool enabled) async {
    await _client.put('/agent/manage/payment-methods/$method', body: {'enabled': enabled});
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
