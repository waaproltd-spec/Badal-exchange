import '../models/order.dart';
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
  // Deposits
  // ---------------------------------------------------------------------

  Future<Order> depositEvc({
    required String phoneNumber,
    required String amount,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/customer/deposits/evc',
      body: {'phoneNumber': phoneNumber, 'amount': amount},
      idempotencyKey: idempotencyKey,
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  Future<Order> depositWinwin({
    required String winwinId,
    required String amount,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/customer/deposits/winwin',
      body: {'winwinId': winwinId, 'amount': amount},
      idempotencyKey: idempotencyKey,
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  // ---------------------------------------------------------------------
  // Withdrawals
  // ---------------------------------------------------------------------

  Future<Order> withdrawEvc({
    required String phoneNumber,
    required String amount,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/customer/withdrawals/evc',
      body: {'phoneNumber': phoneNumber, 'amount': amount},
      idempotencyKey: idempotencyKey,
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
  }

  Future<Order> withdrawWinwin({
    required String winwinId,
    required String amount,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/customer/withdrawals/winwin',
      body: {'winwinId': winwinId, 'amount': amount},
      idempotencyKey: idempotencyKey,
    ) as Map<String, dynamic>;
    return Order.fromJson(data);
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
