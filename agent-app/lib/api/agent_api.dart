import 'package:uuid/uuid.dart';

import '../models/agent_profile.dart';
import '../models/exchange.dart';
import '../models/match_result.dart';
import '../models/console.dart';
import '../models/management.dart';
import '../models/payment_methods.dart';
import '../models/order.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'token_storage.dart';

/// Result of a login: who signed in. Supabase Auth keeps the session itself.
class LoginResult {
  final String userId;
  final String name;

  const LoginResult({required this.userId, required this.name});
}

/// Typed wrapper around every backend call the Agent App makes. Each one is
/// a Supabase RPC (a Postgres function in supabase/migrations) returning the
/// same JSON the old REST endpoint did, so screens only deal with models.
class AgentApi {
  AgentApi({ApiClient? client, TokenStorage? tokenStorage})
      : _client = client ?? ApiClient(),
        _tokens = tokenStorage ?? TokenStorage.instance;

  final ApiClient _client;
  final TokenStorage _tokens;
  final Uuid _uuid = const Uuid();

  ApiClient get client => _client;

  Future<List<dynamic>> _list(String fn, [Map<String, dynamic>? params]) async =>
      (await _client.rpc(fn, params) as List<dynamic>?) ?? const [];

  Future<Map<String, dynamic>> _map(String fn, [Map<String, dynamic>? params]) async =>
      await _client.rpc(fn, params) as Map<String, dynamic>;

  /// Signs in with Supabase Auth, then checks this is an active agent
  /// account (other roles get the same "Invalid credentials" as before).
  Future<LoginResult> login({required String phone, required String password}) async {
    await _client.signIn(identifier: phone, password: password);
    try {
      final me = await _map('session_profile', {'p_record_login': true});
      if (me['role'] != 'agent') {
        throw const ApiException(statusCode: 401, code: 'UNAUTHORIZED', message: 'Invalid credentials');
      }
      return LoginResult(userId: me['id'] as String, name: me['name'] as String? ?? '');
    } catch (_) {
      await _client.signOut();
      rethrow;
    }
  }

  Future<void> registerDevice({required String deviceId, String? deviceLabel}) async {
    await _client.rpc('agent_register_device', {'p_device_id': deviceId, 'p_device_label': deviceLabel});
  }

  Future<List<Order>> getPendingDeposits() async =>
      (await _list('agent_pending_deposits')).map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<Order>> getPendingWithdrawals() async =>
      (await _list('agent_pending_withdrawals')).map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<Order>> getCompletedOrders() async =>
      (await _list('agent_completed_orders')).map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<Order>> getFailedOrders() async =>
      (await _list('agent_failed_orders')).map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();

  Future<AgentProfile> getProfile() async => AgentProfile.fromJson(await _map('agent_profile'));

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
    final data = await _map('agent_submit_sms_transaction', {
      'p_provider': provider,
      'p_sender': sender,
      'p_receiver': receiver,
      'p_amount': amount,
      'p_transaction_ref': transactionRef,
      'p_occurred_at': occurredAt.toUtc().toIso8601String(),
      'p_device_id': deviceId,
      'p_idempotency_key': _uuid.v4(),
    });
    return MatchResult.fromJson(data);
  }

  /// Uploads one payment SMS (Dalab POST /agent/sms-logs). The backend
  /// stores it, dedupes it and matches it to at most one pending exchange
  /// order or wallet deposit. Returns {id, status: new|already_processed,
  /// matchStatus, exchangeOrderId?, orderId?, reason?}.
  Future<Map<String, dynamic>> ingestPaymentSms({
    required String sender,
    required String body,
    required DateTime receivedAt,
    String? provider,
    String? amount,
    String? phone,
    String? transactionRef,
    int? simSlot,
    String? deviceId,
  }) =>
      _map('agent_ingest_payment_sms', {
        'p_sender': sender,
        'p_body': body,
        'p_received_at': receivedAt.toUtc().toIso8601String(),
        'p_parsed_provider': provider,
        'p_parsed_amount': amount,
        'p_parsed_phone': phone,
        'p_transaction_ref': transactionRef,
        'p_sim_slot': simSlot,
        'p_device_id': deviceId,
      });

  /// The payout phone's own "you transferred \$X to NUMBER" SMS (Dalab POST
  /// /agent/exchange/orders/payout-confirmation). Only completes an order
  /// whose payout was actually dialed before this SMS arrived.
  Future<Map<String, dynamic>> reportExchangePayoutConfirmation({
    required String receiverPhone,
    required String amount,
    required String rawText,
    String? provider,
    String? reference,
    DateTime? receivedAt,
  }) =>
      _map('agent_exchange_payout_confirmation', {
        'p_receiver_phone': receiverPhone,
        'p_amount': amount,
        'p_raw_text': rawText,
        'p_provider': provider,
        'p_reference': reference,
        'p_received_at': receivedAt?.toUtc().toIso8601String(),
      });

  // ---- Exchange payouts (this phone dials them) ----

  Future<List<ExchangeOrder>> getExchangePayoutQueue() async => (await _list('agent_exchange_payout_queue'))
      .map((e) => ExchangeOrder.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<ExchangeDialStart> startExchangeDial(String orderId, {String? deviceId}) async =>
      ExchangeDialStart.fromJson(await _map('agent_exchange_start_dial', {'p_order_id': orderId, 'p_device_id': deviceId}));

  Future<void> reportExchangeStep1(String attemptId, {required String status, String? response, bool isFinal = true}) async {
    await _client.rpc('agent_exchange_report_step1',
        {'p_attempt_id': attemptId, 'p_status': status, 'p_response': response, 'p_is_final': isFinal});
  }

  Future<void> reportExchangeStep2(String attemptId, {required String status, String? response, bool isFinal = true}) async {
    await _client.rpc('agent_exchange_report_step2',
        {'p_attempt_id': attemptId, 'p_status': status, 'p_response': response, 'p_is_final': isFinal});
  }

  // ---- Exchange management ----

  Future<List<ExchangeOrder>> getExchangeOrders({String? status, String? query}) async =>
      (await _list('manage_exchange_orders', {'p_status': status, 'p_q': query}))
          .map((e) => ExchangeOrder.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<ExchangeOrder> getExchangeOrder(String id) async =>
      ExchangeOrder.fromJson(await _map('manage_exchange_order', {'p_id': id}));

  Future<void> verifyExchangeOrder(String id, {String? reference}) async {
    await _client.rpc('manage_exchange_verify', {'p_id': id, 'p_reference': reference});
  }

  Future<void> retryExchangePayout(String id, {bool confirmedNotPaid = false}) async {
    await _client.rpc('manage_exchange_retry_payout', {'p_id': id, 'p_confirmed_not_paid': confirmedNotPaid});
    await _client.rpc('manage_exchange_request_payout', {'p_id': id});
  }

  Future<void> reverseExchangeOrder(String id, {String? reason}) async {
    await _client.rpc('manage_exchange_reverse', {'p_id': id, 'p_reason': reason});
  }

  Future<List<PaymentSmsLog>> getPaymentSms({String? status}) async => (await _list('manage_payment_sms', {'p_status': status}))
      .map((e) => PaymentSmsLog.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<void> resolvePaymentSms(String smsId, String exchangeOrderId) async {
    await _client.rpc('manage_resolve_payment_sms', {'p_sms_id': smsId, 'p_exchange_order_id': exchangeOrderId});
  }

  Future<ExchangeSettings> getExchangeSettings() async => ExchangeSettings.fromJson(await _map('manage_exchange_settings'));

  Future<void> saveExchangeCorridor(ExchangeCorridor c,
      {required double rate,
      required String feeType,
      required double feeValue,
      double? minAmount,
      double? maxAmount,
      String? payoutWalletId,
      required bool enabled}) async {
    await _client.rpc('manage_save_exchange_corridor', {
      'p_id': c.id,
      'p_rate': rate,
      'p_fee_type': feeType,
      'p_fee_value': feeValue,
      'p_min_amount': minAmount,
      'p_max_amount': maxAmount,
      'p_payout_wallet_id': payoutWalletId,
      'p_enabled': enabled,
    });
  }

  Future<void> savePayoutWallet({String? id, required String method, required String phoneNumber, String? deviceId, int? simSlot}) async {
    await _client.rpc('manage_save_payout_wallet', {
      'p_id': id,
      'p_method': method,
      'p_phone_number': phoneNumber,
      'p_device_id': deviceId,
      'p_sim_slot': simSlot,
    });
  }

  Future<void> setPayoutWalletPin(String id, String pin) async {
    await _client.rpc('manage_set_payout_wallet_pin', {'p_id': id, 'p_pin': pin});
  }

  /// Submits a WinWin/MobCash deposit confirmation the agent manually keyed
  /// in after observing the real transaction in the WinWin manager app.
  Future<MatchResult> submitWinwinTransaction({
    required String winwinId,
    String? depositCode,
    required String amount,
    required String mobcashRef,
    required DateTime occurredAt,
  }) {
    return submitPlatformTransaction(
      method: 'winwin',
      accountId: winwinId,
      depositCode: depositCode,
      amount: amount,
      reference: mobcashRef,
      occurredAt: occurredAt,
    );
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
    final data = await _map('agent_submit_mobile_money_transaction', {
      'p_method': method,
      'p_sender_phone': senderPhone,
      'p_amount': amount,
      'p_transaction_ref': transactionRef,
      'p_occurred_at': occurredAt.toUtc().toIso8601String(),
      'p_idempotency_key': _uuid.v4(),
    });
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
    final data = await _map('agent_submit_platform_transaction', {
      'p_method': method,
      'p_account_id': accountId,
      'p_deposit_code': (depositCode != null && depositCode.isNotEmpty) ? depositCode : null,
      'p_amount': amount,
      'p_reference': reference,
      'p_occurred_at': occurredAt.toUtc().toIso8601String(),
      'p_idempotency_key': _uuid.v4(),
    });
    return MatchResult.fromJson(data);
  }

  // ---------------------------------------------------------------------
  // Console: Dashboard, Users, Reports, History, Account
  // ---------------------------------------------------------------------

  Future<DashboardSummary> getDashboard() async => DashboardSummary.fromJson(await _map('agent_dashboard'));

  Future<List<CustomerSummary>> getCustomers({
    String? query,
    String status = 'all',
    String sort = 'newest',
    int offset = 0,
  }) async {
    final data = await _list('agent_customers', {
      'p_q': (query != null && query.trim().isNotEmpty) ? query.trim() : null,
      'p_status': status,
      'p_sort': sort,
      'p_offset': offset,
    });
    return data.map((e) => CustomerSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<CustomerDetail> getCustomer(String id) async =>
      CustomerDetail.fromJson(await _map('agent_customer', {'p_id': id}));

  Future<List<LedgerEntry>> getCustomerLedger(String id) async =>
      (await _list('agent_customer_ledger', {'p_id': id}))
          .map((e) => LedgerEntry.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<ReportSummary> getReport({required String period, String? from, String? to}) async =>
      ReportSummary.fromJson(await _map('agent_reports', {'p_period': period, 'p_from': from, 'p_to': to}));

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
    final data = await _list('agent_history', {
      'p_q': (query != null && query.trim().isNotEmpty) ? query.trim() : null,
      'p_type': type,
      'p_status': status,
      'p_method': method,
      'p_customer_id': customerId,
      'p_from': from,
      'p_to': to,
      'p_offset': offset,
      'p_limit': limit,
    });
    return data.map((e) => HistoryItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<AgentAccount> getAccount() async => AgentAccount.fromJson(await _map('agent_account'));

  Future<void> changePassword({required String currentPassword, required String newPassword}) async {
    await _client.rpc('change_password', {
      'p_current_password': currentPassword,
      'p_new_password': newPassword,
    });
  }

  // Admin features (require the 'manage_settings' responsibility).

  /// Loads the shared payment-method catalog (callable before login). Keeps
  /// the bundled list if the backend can't be reached.
  Future<void> loadMethodCatalog() async {
    try {
      final data = await _client.rpc('payment_method_catalog');
      if (data is List<dynamic>) applyPaymentMethodCatalog(data);
    } catch (_) {}
  }

  /// Every method with ON/OFF, rates, fees and withdrawal limits.
  Future<List<MethodSettings>> getMethodSettings() async =>
      (await _list('manage_payment_methods')).map((e) => MethodSettings.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> setMethodEnabled(String method, bool enabled) async {
    await _client.rpc('manage_set_payment_method', {'p_method': method, 'p_enabled': enabled});
  }

  /// New exchange rate for one method/direction (past orders keep theirs).
  Future<void> setRate(String method, String direction, double rate) async {
    await _client.rpc('admin_set_exchange_rate', {'p_method': method, 'p_direction': direction, 'p_rate': rate});
  }

  /// [value] is dollars for a flat fee (sent as cents) or 0-100 for percent.
  Future<void> setFee(String method, String direction, {required String type, required double value}) async {
    await _client.rpc('admin_set_fee', {
      'p_method': method,
      'p_direction': direction,
      'p_fee_type': type,
      'p_value': type == 'flat' ? (value * 100).round() : value,
    });
  }

  /// Withdrawal limits in dollars.
  Future<void> setWithdrawalLimits(String method, {required double min, required double max}) async {
    await _client.rpc('admin_set_withdrawal_limits', {'p_method': method, 'p_min_amount': min, 'p_max_amount': max});
  }

  // Agents

  Future<List<AgentListItem>> getAgents() async =>
      (await _list('admin_agents')).map((e) => AgentListItem.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> createAgent({
    required String name,
    required String phone,
    required String password,
    required List<String> responsibilities,
  }) async {
    await _client.rpc('admin_create_agent', {
      'p_name': name,
      'p_phone': phone,
      'p_password': password,
      'p_responsibilities': responsibilities,
    });
  }

  Future<void> setAgentEnabled(String id, bool enabled) async {
    await _client.rpc('admin_set_agent_status', {'p_id': id, 'p_enabled': enabled});
  }

  Future<void> setAgentResponsibilities(String id, List<String> responsibilities) async {
    await _client.rpc('admin_set_agent_responsibilities', {'p_id': id, 'p_responsibilities': responsibilities});
  }

  Future<List<AgentDevice>> getAgentDevices(String id) async =>
      (await _list('admin_agent_devices', {'p_id': id}))
          .map((e) => AgentDevice.fromJson(e as Map<String, dynamic>))
          .toList();

  /// Orders this agent verified or processed.
  Future<List<Order>> getAgentOrders(String id) async =>
      (await _list('admin_agent_transactions', {'p_id': id}))
          .map((e) => Order.fromJson(e as Map<String, dynamic>))
          .toList();

  // Payment integrations (EVC Plus, MobCash/WinWin)

  Future<List<PaymentIntegration>> getIntegrations() async =>
      (await _list('admin_payment_integrations'))
          .map((e) => PaymentIntegration.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<PaymentIntegration> getIntegration(String provider) async =>
      PaymentIntegration.fromJson(await _map('admin_payment_integration', {'p_provider': provider}));

  Future<void> saveIntegrationCredentials(String provider, {required String username, required String password}) async {
    await _client.rpc('admin_set_integration_credentials', {
      'p_provider': provider,
      'p_username': username,
      'p_password': password,
      'p_config': <String, dynamic>{},
    });
  }

  Future<void> setIntegrationActive(String provider, bool active) async {
    await _client.rpc('admin_set_integration_status', {'p_provider': provider, 'p_status': active ? 'active' : 'inactive'});
  }

  Future<void> testIntegration(String provider) async {
    await _client.rpc('admin_test_integration_connection', {'p_provider': provider});
  }

  /// Real login attempt on MobCash with credentials that aren't saved yet.
  /// Runs on the MobCash automation worker; the backend says so if it can't.
  Future<MobCashLoginCheck> checkMobCashLogin({required String username, required String password}) async {
    final data = await _map('admin_mobcash_login_check', {'p_username': username, 'p_password': password});
    return MobCashLoginCheck.fromJson(data);
  }

  Future<void> setAutomationMode(String provider, {required String mode, required bool dryRun}) async {
    await _client.rpc('admin_set_integration_automation', {'p_provider': provider, 'p_mode': mode, 'p_dry_run': dryRun});
  }

  Future<void> resetCircuitBreaker(String provider) async {
    await _client.rpc('admin_reset_circuit_breaker', {'p_provider': provider});
  }

  Future<List<AutomationRun>> getAutomationRuns(String provider) async =>
      (await _list('admin_automation_runs', {'p_provider': provider}))
          .map((e) => AutomationRun.fromJson(e as Map<String, dynamic>))
          .toList();

  /// Base64 PNG of the portal at the end of an automation run, if kept.
  Future<String> getAutomationRunScreenshot(String provider, String runId) async {
    final data = await _map('admin_automation_run_screenshot', {'p_provider': provider, 'p_run_id': runId});
    return data['screenshotBase64'] as String;
  }

  /// Latest wallet ledger entries across all customers.
  Future<List<WalletTransaction>> getAllWalletTransactions() async =>
      (await _list('admin_transactions')).map((e) => WalletTransaction.fromJson(e as Map<String, dynamic>)).toList();

  // Audit

  Future<List<AuditLog>> getAuditLogs() async =>
      (await _list('admin_audit_logs')).map((e) => AuditLog.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<HomeAd>> getHomeAds() async =>
      (await _list('manage_home_ads')).map((e) => HomeAd.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> saveHomeAd({
    String? id,
    required String title,
    String? body,
    String? imageUrl,
    String? linkUrl,
    required bool enabled,
    int sortOrder = 0,
  }) async {
    await _client.rpc('manage_save_home_ad', {
      'p_id': id,
      'p_title': title,
      'p_body': body,
      'p_image_url': imageUrl,
      'p_link_url': linkUrl,
      'p_enabled': enabled,
      'p_sort_order': sortOrder,
    });
  }

  Future<void> deleteHomeAd(String id) async {
    await _client.rpc('manage_delete_home_ad', {'p_id': id});
  }

  Future<List<DepositNumber>> getDepositNumbers() async =>
      (await _list('manage_deposit_numbers')).map((e) => DepositNumber.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> saveDepositNumber({
    String? id,
    required String method,
    required String number,
    String? label,
    required bool enabled,
  }) async {
    await _client.rpc('manage_save_deposit_number', {
      'p_id': id,
      'p_method': method,
      'p_number': number,
      'p_label': label,
      'p_enabled': enabled,
    });
  }

  Future<void> deleteDepositNumber(String id) async {
    await _client.rpc('manage_delete_deposit_number', {'p_id': id});
  }

  Future<List<AppNotification>> getSentNotifications() async =>
      (await _list('manage_notifications')).map((e) => AppNotification.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> sendNotification({required String title, required String body}) async {
    await _client.rpc('manage_send_notification', {'p_title': title, 'p_body': body});
  }

  Future<Contacts> saveContacts(Contacts contacts) async {
    final json = contacts.toJson();
    final data = await _map('manage_set_contacts', {
      'p_whatsapp': json['whatsapp'],
      'p_facebook': json['facebook'],
      'p_telegram': json['telegram'],
    });
    return Contacts.fromJson(data);
  }

  Future<Order> startWithdrawal(String orderId) async =>
      Order.fromJson(await _map('agent_withdrawal_start', {'p_order_id': orderId}));

  Future<Order> completeWithdrawal(String orderId, {required String transactionRef}) async {
    final data = await _map('agent_withdrawal_complete', {
      'p_order_id': orderId,
      'p_transaction_ref': transactionRef,
      'p_idempotency_key': _uuid.v4(),
    });
    return Order.fromJson(data);
  }

  Future<Order> failWithdrawal(String orderId, {required String reason}) async =>
      Order.fromJson(await _map('agent_withdrawal_fail', {'p_order_id': orderId, 'p_reason': reason}));

  Future<void> logout() async {
    // Ends this session on the server too; the local session is cleared
    // regardless so the agent is always able to log out.
    await _client.signOut();
    await _tokens.clear();
  }
}
