import '../models/app_content.dart';
import '../models/order.dart';
import '../models/payment_method.dart';
import '../models/quote.dart';
import '../models/wallet.dart';
import 'api_client.dart';
import 'api_exception.dart';

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
        throw const ApiException(status: 401, code: 'UNAUTHORIZED', message: 'Invalid credentials');
      }
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
    required String amount,
    required String idempotencyKey,
  }) =>
      _createOrder('deposits', method, phoneNumber, accountId, amount, idempotencyKey);

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
    String amount,
    String idempotencyKey,
  ) async {
    final data = await _client.rpc(
      kind == 'deposits' ? 'customer_create_deposit' : 'customer_create_withdrawal',
      {
        'p_method': method,
        'p_phone_number': phoneNumber,
        'p_account_id': accountId,
        'p_amount': amount,
        'p_idempotency_key': idempotencyKey,
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

  Future<Order> getOrder(String id) async {
    final data = await _client.rpc('customer_order', {'p_id': id}) as Map<String, dynamic>;
    return Order.fromJson(data);
  }
}
