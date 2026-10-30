import 'dart:convert';

import '../models/kyc.dart';
import '../models/withdrawal_access.dart';
import '../models/app_content.dart';
import '../models/bonus.dart';
import '../models/order.dart';
import '../models/payment_method.dart';
import '../models/player.dart';
import '../models/quote.dart';
import '../models/wallet.dart';
import 'api_client.dart';
import 'api_exception.dart';
import '../l10n/strings.dart';

/// Typed methods for every backend call the customer app makes (Supabase
/// Auth and RPC functions returning the same JSON the REST API did). Pure request/response mapping -- no business logic
/// or money math lives here.
class CustomerApi {
  CustomerApi(this._client);

  final ApiClient _client;

  // ---------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------

  /// Signs in with Supabase Auth and checks this is an active customer
  /// account (any other role gets "Invalid credentials", as before).
  Future<({String name})> login({
    required String phone,
    required String password,
  }) async {
    await _client.signIn(phone: phone, password: password);
    try {
      final me = await _client.rpc('session_profile', {'p_record_login': true}) as Map<String, dynamic>;
      if (me['role'] != 'customer') {
        throw ApiException(status: 401, code: 'UNAUTHORIZED', message: AppStrings.invalidLogin);
      }
      // One phone per account: the other phones are signed out.
      await _client.signOutOtherPhones();
      return (name: (me['name'] as String?) ?? '');
    } catch (_) {
      await _client.signOut();
      rethrow;
    }
  }

  /// Creates the account (and its wallet), then signs in.
  Future<void> register({
    required String phone,
    required String name,
    required String password,
  }) async {
    await _client.rpc('register_customer', {'p_phone': phone, 'p_name': name, 'p_password': password});
    await login(phone: phone, password: password);
  }

  Future<void> logout() => _client.signOut();

  /// Changes the password; this phone stays signed in. A wrong
  /// [currentPassword] is INVALID_PASSWORD.
  Future<void> changePassword({required String currentPassword, required String newPassword}) async {
    await _client.rpc('change_password', {'p_current_password': currentPassword, 'p_new_password': newPassword});
  }

  /// Support links (whatsapp, telegram, facebook; empty when not set),
  /// readable before logging in.
  Future<Map<String, String>> getSupportContacts() async {
    final data = await _client.rpc('support_contacts') as Map<String, dynamic>;
    return {for (final e in data.entries) e.key: (e.value as String?)?.trim() ?? ''};
  }

  /// Realtime changes to this customer's orders and wallet, and new
  /// notifications ('orders' | 'wallets' | 'notifications').
  Stream<String> get liveChanges => _client.liveChanges;

  /// Whether a restored session still belongs to an active customer.
  Future<bool> verifySession() async {
    final me = await _client.rpc('session_profile') as Map<String, dynamic>;
    return me['role'] == 'customer';
  }

  // ---------------------------------------------------------------------
  // Wallet & quotes
  // ---------------------------------------------------------------------

  /// The betting-platform account ID this customer used before with
  /// [method], or null the first time.
  Future<String?> getPlatformAccount(String method) async {
    final data = await _client.rpc('customer_platform_account', {'p_method': method}) as Map<String, dynamic>;
    return data['accountId'] as String?;
  }

  /// "Find a Player": the 888STARZ / 1XBET player with [accountId], asked
  /// of the platform's cash register.
  Future<PlayerLookup> findPlayer(String method, String accountId) async {
    final data = await _client.invoke('player-lookup', {'method': method, 'accountId': accountId});
    return PlayerLookup.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<Wallet> getWallet() async {
    final data = await _client.rpc('customer_wallet') as Map<String, dynamic>;
    return Wallet.fromJson(data);
  }

  /// Always call this before showing a confirmation screen -- the app
  /// never calculates fee/net amount itself, only displays what this
  /// returns.
  Future<Quote> createQuote({
    required String direction,
    required String method,
    required String amount,
  }) async {
    final data = await _client.rpc('customer_quote', {
      'p_direction': direction,
      'p_method': method,
      'p_amount': amount,
    }) as Map<String, dynamic>;
    return Quote.fromJson(data);
  }

  // ---------------------------------------------------------------------
  // Deposits & withdrawals (any payment method)
  // ---------------------------------------------------------------------

  /// Mobile-money methods take [phoneNumber]; betting platforms take
  /// [accountId].
  Future<Order> deposit({
    required String method,
    String? phoneNumber,
    String? accountId,
    /// Null for a cash-desk deposit by withdrawal code: the platform says it.
    required String? amount,
    required String idempotencyKey,
    String? platformCode,
  }) =>
      _createOrder('deposits', method, phoneNumber, accountId, amount, idempotencyKey, platformCode: platformCode);

  Future<Order> withdraw({
    required String method,
    String? phoneNumber,
    String? accountId,
    required String amount,
    required String idempotencyKey,
  }) =>
      _createOrder('withdrawals', method, phoneNumber, accountId, amount, idempotencyKey);

  Future<Order> _createOrder(
    String kind,
    String method,
    String? phoneNumber,
    String? accountId,
    String? amount,
    String idempotencyKey, {
    String? platformCode,
  }) async {
    final data = await _client.rpc(
      kind == 'deposits' ? 'customer_create_deposit' : 'customer_create_withdrawal',
      {
        'p_method': method,
        'p_phone_number': phoneNumber,
        'p_account_id': accountId,
        'p_amount': amount,
        'p_idempotency_key': idempotencyKey,
        if (platformCode != null) 'p_platform_code': platformCode,
      },
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  // ---------------------------------------------------------------------
  // App content (managed from the Agent App)
  // ---------------------------------------------------------------------

  /// Loads the shared payment-method catalog (callable before login) so labels
  /// and styling match the backend. Keeps the bundled list on failure.
  Future<void> loadMethodCatalog() async {
    try {
      final data = await _client.rpc('payment_method_catalog');
      if (data is List<dynamic>) applyPaymentMethodCatalog(data);
    } catch (_) {}
  }

  /// Enabled payment methods, in display order, with deposit numbers.
  Future<List<PaymentMethodOption>> getPaymentMethods() async {
    final data = await _client.rpc('customer_payment_methods') as List<dynamic>;
    return data.map((e) => PaymentMethodOption.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<HomeAd>> getHomeAds() async {
    final data = await _client.rpc('customer_home_ads') as List<dynamic>;
    return data.map((e) => HomeAd.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<AppNotification>> getNotifications() async {
    final data = await _client.rpc('customer_notifications') as List<dynamic>;
    return data.map((e) => AppNotification.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------------------------------------------------------------------
  // Orders
  // ---------------------------------------------------------------------

  Future<List<Order>> getOrders() async {
    final data = await _client.rpc('customer_orders') as List<dynamic>;
    return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// This device's push notification token, for the signed-in customer.
  Future<void> registerPushToken(String token) =>
      _client.rpc('customer_register_push_token', {'p_token': token, 'p_platform': 'android'});

  Future<void> unregisterPushToken(String token) => _client.rpc('customer_unregister_push_token', {'p_token': token});

  /// The customer's KYC.
  Future<KycStatus> getKycStatus() async =>
      KycStatus.fromJson(await _client.rpc('customer_kyc_status') as Map<String, dynamic>);

  /// Submits KYC: the server checks it and sends it to Admin Review (or to
  /// the identity service, when one is set up). Images as JPEG / PNG bytes.
  Future<KycStatus> submitKyc({
    required String documentType,
    required String fullName,
    required String documentNumber,
    String? country,
    String? dateOfBirth,
    String? expiryDate,
    required List<int> front,
    List<int>? back,
    required List<int> selfie,
  }) async =>
      KycStatus.fromJson(await _client.rpc('customer_submit_kyc', {
        'p_document_type': documentType,
        'p_full_name': fullName,
        'p_document_number': documentNumber,
        'p_country': country,
        'p_date_of_birth': dateOfBirth,
        'p_expiry_date': expiryDate,
        'p_front': base64Encode(front),
        'p_back': back == null ? null : base64Encode(back),
        'p_selfie': base64Encode(selfie),
      }) as Map<String, dynamic>);

  /// May this account withdraw? The first time, it asks the admin to
  /// approve it. Null when it cannot be read (the server still decides).
  Future<WithdrawalAccess?> getWithdrawalAccess() async {
    try {
      return WithdrawalAccess.fromJson(await _client.rpc('customer_withdrawal_access') as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Records the deposit form as the customer fills it in, before
  /// "Confirm Deposit" (Admin Dashboard -> Unconfirmed Deposits). Only the
  /// method, amount and account ID: the server takes the registered phone.
  /// Never fails the form: any error is ignored.
  Future<void> trackDepositDraft({required String method, String? amount, String? accountId}) async {
    try {
      await _client.rpc('customer_track_deposit_draft', {'p_method': method, 'p_amount': amount, 'p_account_id': accountId});
    } catch (_) {
      // Monitoring only.
    }
  }

  Future<Order> getOrder(String id) async {
    final data = await _client.rpc('customer_order', {'p_id': id}) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  // ---------------------------------------------------------------------
  // Bonus wallet
  // ---------------------------------------------------------------------

  Future<BonusInfo> getBonus() async {
    final data = await _client.rpc('customer_bonus') as Map<String, dynamic>;
    return BonusInfo.fromJson(data);
  }

  /// Moves the whole bonus balance to the main wallet. Nothing to move is NO_BONUS.
  Future<BonusInfo> moveBonus() async {
    final data = await _client.rpc('customer_move_bonus') as Map<String, dynamic>;
    return BonusInfo.fromJson(data['bonus'] as Map<String, dynamic>);
  }

  /// The name Sahal has for the customer's own Golis / ZAAD / EVC Plus number,
  /// or null when it has none. Throws when Sahal couldn't be asked.
  Future<String?> getReceiverName(String method) async {
    final data = await _client.invoke('receiver-name', {'method': method}) as Map<String, dynamic>;
    final name = (data['name'] as String?)?.trim();
    return data['found'] == true && name != null && name.isNotEmpty ? name : null;
  }

  /// The bonus this withdrawal will earn once paid, or null when it earns none.
  Future<BonusPreview?> getBonusPreview(String method, String amount) async {
    final data = await _client.rpc('customer_bonus_preview', {'p_method': method, 'p_amount': amount});
    return data is Map<String, dynamic> ? BonusPreview.fromJson(data) : null;
  }
}
