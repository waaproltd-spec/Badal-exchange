import 'package:uuid/uuid.dart';

import '../models/agent_profile.dart';
import '../models/match_result.dart';
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
