import '../models/app_content.dart';
import '../models/order.dart';
import '../models/payment_method.dart';
import '../models/quote.dart';
import '../models/wallet.dart';
import 'api_client.dart';

/// Typed methods for every `/auth/*` and `/customer/*` endpoint the
/// customer app uses. Pure request/response mapping -- no business logic
/// or money math lives here.
class CustomerApi {
  CustomerApi(this._client);

  final ApiClient _client;

  // ---------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------

  Future<({String name, String accessToken, String refreshToken})> login({
    required String phone,
    required String password,
  }) async {
    final data = await _client.post('/auth/customer/login', body: {
      'phone': phone,
      'password': password,
    }) as Map<String, dynamic>;
    final user = data['user'] as Map<String, dynamic>;
    return (
      name: (user['name'] as String?) ?? '',
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
  }

  Future<({String accessToken, String refreshToken})> register({
    required String phone,
    required String name,
    required String password,
  }) async {
    final data = await _client.post('/auth/customer/register', body: {
      'phone': phone,
      'name': name,
      'password': password,
    }) as Map<String, dynamic>;
    return (
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
  }

  Future<void> logout({required String refreshToken}) async {
    await _client.post('/auth/logout', body: {'refreshToken': refreshToken});
  }

  // ---------------------------------------------------------------------
  // Wallet & quotes
  // ---------------------------------------------------------------------

  Future<Wallet> getWallet() async {
    final data = await _client.get('/customer/wallet') as Map<String, dynamic>;
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
    final data = await _client.post('/customer/quotes', body: {
      'direction': direction,
      'method': method,
      'amount': amount,
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
    final data = await _client.post(
      '/customer/$kind/$method',
      body: {
        if (phoneNumber != null) 'phoneNumber': phoneNumber,
        if (accountId != null) 'accountId': accountId,
        'amount': amount,
      },
      idempotencyKey: idempotencyKey,
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  // ---------------------------------------------------------------------
  // App content (managed from the Agent App)
  // ---------------------------------------------------------------------

  /// Loads the shared payment-method catalog (public endpoint) so labels
  /// and styling match the backend. Keeps the bundled list on failure.
  Future<void> loadMethodCatalog() async {
    try {
      final data = await _client.get('/meta/payment-methods');
      if (data is List<dynamic>) applyPaymentMethodCatalog(data);
    } catch (_) {}
  }

  /// Enabled payment methods, in display order, with deposit numbers.
  Future<List<PaymentMethodOption>> getPaymentMethods() async {
    final data = await _client.get('/customer/payment-methods') as List<dynamic>;
    return data.map((e) => PaymentMethodOption.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<HomeAd>> getHomeAds() async {
    final data = await _client.get('/customer/home-ads') as List<dynamic>;
    return data.map((e) => HomeAd.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<AppNotification>> getNotifications() async {
    final data = await _client.get('/customer/notifications') as List<dynamic>;
    return data.map((e) => AppNotification.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------------------------------------------------------------------
  // Orders
  // ---------------------------------------------------------------------

  Future<List<Order>> getOrders() async {
    final data = await _client.get('/customer/orders') as List<dynamic>;
    return data.map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Order> getOrder(String id) async {
    final data = await _client.get('/customer/orders/$id') as Map<String, dynamic>;
    return Order.fromJson(data);
  }
}
