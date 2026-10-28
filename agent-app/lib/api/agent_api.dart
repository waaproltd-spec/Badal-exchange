import 'package:uuid/uuid.dart';

import '../models/deposit_board.dart';
import '../models/wallet_adjustment.dart';
import '../models/agent_profile.dart';
import '../models/payout.dart';
import '../models/match_result.dart';
import '../models/console.dart';
import '../models/management.dart';
import '../models/payment_methods.dart';
import '../models/order.dart';
import '../models/company_balance.dart';
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

  /// The "Lacagaha Sugaya Xaqiijinta" board: summary and the deposits of [from, to).
  Future<DepositBoard> getDepositBoard({DateTime? from, DateTime? to}) async =>
      DepositBoard.fromJson(await _map('agent_deposit_board', {
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
      }));

  /// Admin: Unconfirmed Deposits started in [from, to) (default: the last 7 days).
  Future<UnconfirmedDeposits> getUnconfirmedDeposits({DateTime? from, DateTime? to}) async =>
      UnconfirmedDeposits.fromJson(await _map('manage_unconfirmed_deposits', {
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
      }));

  /// Rejects a waiting deposit (nothing was credited, no money moves).
  Future<void> rejectDeposit(String orderId, {required String reason}) async {
    await _map('agent_reject_deposit', {'p_order_id': orderId, 'p_reason': reason});
  }

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
  /// stores it, dedupes it and matches it to at most one pending wallet
  /// deposit. Returns {id, status: new|already_processed, matchStatus,
  /// orderId?, reason?}.
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

  /// The payout phone's own "you transferred \$X to NUMBER" SMS. Only
  /// completes a withdrawal whose payout was dialed before this SMS arrived.
  Future<Map<String, dynamic>> reportPayoutConfirmation({
    required String receiverPhone,
    required String amount,
    required String rawText,
    String? provider,
    String? reference,
    DateTime? receivedAt,
    String? deviceId,
  }) =>
      _map('agent_payout_confirmation', {
        'p_receiver_phone': receiverPhone,
        'p_amount': amount,
        'p_raw_text': rawText,
        'p_provider': provider,
        'p_reference': reference,
        'p_received_at': receivedAt?.toUtc().toIso8601String(),
        'p_device_id': deviceId,
      });

  // ---- Withdrawal payouts (this phone dials them) ----

  Future<List<PayoutOrder>> getPayoutQueue() async =>
      (await _list('agent_payout_queue')).map((e) => PayoutOrder.fromJson(e as Map<String, dynamic>)).toList();

  Future<PayoutDialStart> startPayoutDial(String orderId, {String? deviceId}) async =>
      PayoutDialStart.fromJson(await _map('agent_payout_start_dial', {'p_order_id': orderId, 'p_device_id': deviceId}));

  Future<void> reportPayoutStep1(String attemptId, {required String status, String? response, bool isFinal = true}) async {
    await _client.rpc('agent_payout_report_step1',
        {'p_attempt_id': attemptId, 'p_status': status, 'p_response': response, 'p_is_final': isFinal});
  }

  Future<void> reportPayoutStep2(String attemptId, {required String status, String? response, bool isFinal = true}) async {
    await _client.rpc('agent_payout_report_step2',
        {'p_attempt_id': attemptId, 'p_status': status, 'p_response': response, 'p_is_final': isFinal});
  }

  // ---- Payout and payment SMS management ----

  Future<List<PayoutOrder>> getPayouts({bool reviewOnly = false}) async =>
      (await _list('manage_payouts', {'p_review_only': reviewOnly}))
          .map((e) => PayoutOrder.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<PayoutOrder> getPayout(String orderId) async =>
      PayoutOrder.fromJson(await _map('manage_payout', {'p_order_id': orderId}));

  /// Another automatic try. [confirmedNotPaid] is required (CONFIRM_NOT_PAID)
  /// when an earlier attempt reached the PIN step.
  Future<void> retryPayout(String orderId, {bool confirmedNotPaid = false}) async {
    await _client.rpc('manage_payout_retry', {'p_order_id': orderId, 'p_confirmed_not_paid': confirmedNotPaid});
  }

  Future<List<PaymentSmsLog>> getPaymentSms({String? status}) async => (await _list('manage_payment_sms', {'p_status': status}))
      .map((e) => PaymentSmsLog.fromJson(e as Map<String, dynamic>))
      .toList();

  /// Assigns a stored payment SMS to a pending deposit (by order code).
  Future<void> resolvePaymentSms(String smsId, String orderCode) async {
    await _client.rpc('manage_resolve_payment_sms', {'p_sms_id': smsId, 'p_order_code': orderCode});
  }

  Future<List<PayoutWallet>> getPayoutWallets() async =>
      (await _list('manage_payout_wallets')).map((e) => PayoutWallet.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> savePayoutWallet({String? id, required String method, required String phoneNumber, String? deviceId, int? simSlot}) async {
    await _client.rpc('manage_save_payout_wallet', {
      'p_id': id,
      'p_method': method,
      'p_phone_number': phoneNumber,
      'p_device_id': deviceId,
      'p_sim_slot': simSlot,
    });
  }

  Future<void> deletePayoutWallet(String id) async {
    await _client.rpc('manage_delete_payout_wallet', {'p_id': id});
  }

  Future<void> setPayoutWalletPin(String id, String pin) async {
    await _client.rpc('manage_set_payout_wallet_pin', {'p_id': id, 'p_pin': pin});
  }

  /// The number EVC's *736 code carries (*736*number*amount*CODE#), apart from the PIN.
  Future<void> setPayoutWalletUssdCode(String id, String code) async {
    await _client.rpc('manage_set_payout_wallet_ussd_code', {'p_id': id, 'p_code': code});
  }

  /// Server safeguards for automatic payouts, per method.
  Future<List<AutoPayoutSettings>> getAutoPayouts() async =>
      (await _list('manage_auto_payouts')).map((e) => AutoPayoutSettings.fromJson(e as Map<String, dynamic>)).toList();

  /// [mode] off | test | live (live only after a passed $0.10 test).
  /// Limits in dollars; null keeps them.
  Future<AutoPayoutSettings> setAutoPayout(String method, {String? mode, double? dailyLimit, double? minBalance}) async =>
      AutoPayoutSettings.fromJson(await _map('manage_set_auto_payout', {
        'p_method': method,
        'p_mode': mode,
        'p_daily_limit': dailyLimit,
        'p_min_balance': minBalance,
      }));

  /// Golis / ZAAD / EVC Plus withdrawals sent from Sahal by the server.
  Future<SahalPayoutSettings> getSahalPayouts() async => SahalPayoutSettings.fromJson(await _map('manage_sahal_payouts'));

  /// [mode] off | test | live (live only after a $0.10 test went out); [dailyLimit] in dollars.
  Future<SahalPayoutSettings> setSahalPayouts({String? mode, double? dailyLimit}) async =>
      SahalPayoutSettings.fromJson(await _map('manage_set_sahal_payouts', {'p_mode': mode, 'p_daily_limit': dailyLimit}));

  /// Sends a withdrawal Sahal refused (nothing was sent) again.
  Future<SahalPayoutSettings> retrySahalPayout(String orderId) async =>
      SahalPayoutSettings.fromJson(await _map('manage_sahal_retry', {'p_order_id': orderId}));

  /// The payout wallet's balance as read on the phone.
  Future<AutoPayoutSettings> setPayoutBalance(String method, double balance) async =>
      AutoPayoutSettings.fromJson(await _map('manage_set_payout_balance', {'p_method': method, 'p_balance': balance}));

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

  /// The Dashboard's money, customers, 7-day chart and top lists, for the 7 days ending [day] (today when null).
  Future<DashboardStats> getDashboardStats({DateTime? day}) async => DashboardStats.fromJson(await _map('agent_dashboard_stats', {
        'p_day': day == null
            ? null
            : '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
      }));

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

  /// Customer totals, and how many joined from [from] to [to] (days, inclusive).
  Future<CustomerOverview> getCustomerOverview({required DateTime from, required DateTime to}) async =>
      CustomerOverview.fromJson(await _map('agent_customer_overview', {'p_from': _isoDay(from), 'p_to': _isoDay(to)}));

  static String _isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<CustomerDetail> getCustomer(String id) async =>
      CustomerDetail.fromJson(await _map('agent_customer', {'p_id': id}));

  /// Managers: the Bonus screen -- on/off, the rate, eligible types, balances, history.
  Future<BonusSettings> getBonusSettings() async => BonusSettings.fromJson(await _map('manage_bonus_settings'));

  /// Any left null stays as it is; [eligible] is the full list ('withdraw:edahab', ...).
  Future<BonusSettings> setBonusSettings({bool? enabled, int? defaultRateBp, List<String>? eligible}) async =>
      BonusSettings.fromJson(await _map('manage_set_bonus_settings', {
        'p_enabled': enabled,
        'p_default_bp': defaultRateBp,
        'p_eligible': eligible,
      }));

  /// Managers: one customer's withdrawal bonus and its setting.
  Future<CustomerBonus> getCustomerBonus(String id) async =>
      CustomerBonus.fromJson(await _map('manage_customer_bonus', {'p_customer_id': id}));

  /// Bonus limits per customer, in dollars; empty clears one.
  Future<BonusSettings> setBonusLimits({required String daily, required String monthly}) async =>
      BonusSettings.fromJson(await _map('manage_set_bonus_limits', {'p_daily': daily, 'p_monthly': monthly}));

  /// Sets their rate (50, 100, 150 or 200 basis points) and/or turns it on or off.
  Future<CustomerBonus> setCustomerBonus(String id, {int? rateBp, bool? enabled}) async =>
      CustomerBonus.fromJson(await _map('manage_set_customer_bonus', {
        'p_customer_id': id,
        'p_rate_bp': rateBp,
        'p_enabled': enabled,
      }));

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

  // Company Balances (admins, managers, and 'view_company_balances').

  /// Every company's cash register balance; [refresh] reads the connected
  /// ones again (the server limits how often).
  Future<CompanyBalancesOverview> getCompanyBalances({bool refresh = false, DateTime? from, DateTime? to}) async {
    final data = await _client.getFunction('company-balances', {
      if (refresh) 'refresh': '1',
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
    });
    return CompanyBalancesOverview.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// One company: balance, recent balance reads, and its orders in the
  /// period ([status] 'open' | 'completed' | 'failed').
  Future<CompanyDetail> getCompanyDetail(String method, {DateTime? from, DateTime? to, String? status}) async =>
      CompanyDetail.fromJson(await _map('agent_company_detail', {
        'p_method': method,
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
        'p_status': status,
      }));

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

  /// City and street shown as Payment Location on 1XBET / 888STARZ
  /// deposits; empty clears a value.
  Future<void> setPaymentLocation(String method, {required String city, required String street}) async {
    await _client.rpc('manage_set_payment_location', {'p_method': method, 'p_city': city, 'p_street': street});
  }

  /// Mobile-money merchant code (e.g. *789*090353102*{amount}#) and whether
  /// customers are shown it on Complete Deposit.
  Future<void> setMerchantUssd(String method, {required String code, required bool enabled}) async {
    await _client.rpc('manage_set_merchant_ussd', {'p_method': method, 'p_code': code, 'p_enabled': enabled});
  }

  /// Sahal merchant feed: state, last read, whether an access code is due.
  Future<MerchantFeedStatus> getMerchantFeedStatus() async =>
      MerchantFeedStatus.fromJson(await _map('manage_merchant_feed_status', {'p_provider': 'golis'}));

  /// Starts a Sahal sign-in; Sahal texts an access code to the merchant phone.
  Future<MerchantFeedStatus> merchantFeedSignIn() async =>
      MerchantFeedStatus.fromJson(await _map('manage_merchant_feed_sign_in', {'p_provider': 'golis'}));

  /// Whether matching Sahal merchant payments credit deposits.
  Future<MerchantFeedStatus> merchantFeedCredit(bool on) async =>
      MerchantFeedStatus.fromJson(await _map('manage_merchant_feed_credit', {'p_provider': 'golis', 'p_on': on}));

  /// Whether withdrawals sent by hand from Sahal complete themselves.
  Future<MerchantFeedStatus> merchantFeedPayouts(bool on) async =>
      MerchantFeedStatus.fromJson(await _map('manage_merchant_feed_payouts', {'p_provider': 'golis', 'p_on': on}));

  /// The access code from Sahal's SMS.
  Future<MerchantFeedStatus> merchantFeedCode(String code) async =>
      MerchantFeedStatus.fromJson(await _map('manage_merchant_feed_code', {'p_provider': 'golis', 'p_code': code}));

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

  Future<void> updateAgent(String id, {required String name, required String phone}) async {
    await _client.rpc('admin_update_agent', {'p_id': id, 'p_name': name, 'p_phone': phone});
  }

  /// A new password for another agent; they are signed out everywhere.
  Future<void> resetAgentPassword(String id, String newPassword) async {
    await _client.rpc('admin_reset_agent_password', {'p_id': id, 'p_new_password': newPassword});
  }

  /// Hidden and unable to log in; kept with its orders and audit trail.
  Future<void> deleteAgent(String id, String reason) async {
    await _client.rpc('admin_delete_agent', {'p_id': id, 'p_reason': reason});
  }

  Future<List<LoginEvent>> getLoginHistory({String? userId}) async =>
      (await _list('admin_login_history', {'p_user_id': userId}))
          .map((e) => LoginEvent.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<List<AgentPerformance>> getAgentPerformance({required DateTime from, required DateTime to}) async =>
      (await _list('admin_agent_performance', {'p_from': _isoDay(from), 'p_to': _isoDay(to)}))
          .map((e) => AgentPerformance.fromJson(e as Map<String, dynamic>))
          .toList();

  // Betting platforms

  Future<({List<BettingAdapter> adapters, List<BettingPlatform> platforms})> getBettingPlatforms() async {
    final data = await _map('manage_betting_platforms');
    return (
      adapters: [for (final a in (data['adapters'] as List? ?? const [])) BettingAdapter.fromJson(a as Map<String, dynamic>)],
      platforms: [for (final p in (data['platforms'] as List? ?? const [])) BettingPlatform.fromJson(p as Map<String, dynamic>)],
    );
  }

  /// A new platform, switched off; its credentials are entered next.
  Future<String> createBettingPlatform(String name, String adapter) async =>
      (await _map('manage_create_betting_platform', {'p_name': name, 'p_adapter': adapter}))['method'] as String;

  /// Empty secrets keep the saved ones. Any change needs a new Test connection.
  Future<BettingPlatform> saveBettingPlatform(
    String method, {
    String? apiUrl,
    String? login,
    String? password,
    String? accountId,
    String? apiSecret,
    String? apiKey,
  }) async =>
      BettingPlatform.fromJson(await _map('manage_save_betting_platform', {
        'p_method': method,
        'p_api_url': apiUrl,
        'p_login': login,
        'p_password': password,
        'p_account_id': accountId,
        'p_api_secret': apiSecret,
        'p_api_key': apiKey,
      }));

  /// Tries the saved credentials against the provider (no money moves).
  Future<BettingPlatform> testBettingPlatform(String method) async => BettingPlatform.fromJson(
      await _client.getFunction('cashdeskbot/platform-test/${Uri.encodeComponent(method)}') as Map<String, dynamic>);

  Future<BettingPlatform> setBettingPlatformActive(String method, bool active) async =>
      BettingPlatform.fromJson(await _map('manage_set_betting_platform_active', {'p_method': method, 'p_active': active}));

  Future<void> deleteBettingPlatform(String method, String reason) async {
    await _client.rpc('manage_delete_betting_platform', {'p_method': method, 'p_reason': reason});
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

  /// The promo code customers see on their wallet card ('' / null = none).
  Future<String?> getPromoCode() async => (await _map('manage_promo_code'))['promoCode'] as String?;

  /// Add or deduct money on a customer's wallet. [idempotencyKey] makes a
  /// retried request apply once.
  Future<WalletAdjustment> adjustWallet({
    required String customerId,
    required bool add,
    required String amount,
    required String reason,
    required String idempotencyKey,
  }) async =>
      WalletAdjustment.fromJson(await _map('agent_wallet_adjust', {
        'p_customer_id': customerId,
        'p_direction': add ? 'add' : 'deduct',
        'p_amount': amount,
        'p_reason': reason,
        'p_idempotency_key': idempotencyKey,
      }));

  /// Wallet adjustments, newest first: an agent's own, or everyone's for
  /// managers.
  Future<List<WalletAdjustment>> getWalletAdjustments({String? customerId, String? direction}) async =>
      (await _list('agent_wallet_adjustments', {'p_customer_id': customerId, 'p_direction': direction}))
          .map((e) => WalletAdjustment.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<String?> setPromoCode(String code) async =>
      (await _map('manage_set_promo_code', {'p_code': code}))['promoCode'] as String?;

  /// Sets a new password for a customer who asked support (management only).
  Future<void> resetCustomerPassword(String customerId, String newPassword) async =>
      _client.rpc('manage_reset_customer_password', {'p_customer_id': customerId, 'p_new_password': newPassword});

  Future<TelegramLink> getTelegramLink() async => TelegramLink.fromJson(await _map('manage_telegram_status'));

  Future<TelegramLinkCode> createTelegramLinkCode() async =>
      TelegramLinkCode.fromJson(await _map('manage_telegram_link_code'));

  Future<TelegramLink> unlinkTelegram() async => TelegramLink.fromJson(await _map('manage_telegram_unlink'));

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

  /// Releases the reserved funds. [confirmedNotPaid] is required
  /// (CONFIRM_NOT_PAID) when an automatic payout may have sent the money.
  Future<Order> failWithdrawal(String orderId, {required String reason, bool confirmedNotPaid = false}) async =>
      Order.fromJson(await _map('agent_withdrawal_fail',
          {'p_order_id': orderId, 'p_reason': reason, 'p_confirmed_not_paid': confirmedNotPaid}));

  Future<void> logout() async {
    // Ends this session on the server too; the local session is cleared
    // regardless so the agent is always able to log out.
    await _client.signOut();
    await _tokens.clear();
  }
}
