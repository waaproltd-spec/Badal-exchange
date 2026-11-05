import 'dart:io';

import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/app_content.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/tip.dart';
import 'package:badal_exchange_customer/models/wallet.dart';
import 'package:badal_exchange_customer/screens/root/root_shell.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/state/orders_provider.dart';
import 'package:badal_exchange_customer/state/wallet_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:badal_exchange_customer/utils/network_error.dart';
import 'package:badal_exchange_customer/utils/payment_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _technical = "ClientException with SocketException: Failed host lookup: 'onbezsojnpsrtuxzwsjr.supabase.co' "
    '(OS Error: No address associated with hostname, errno = 7), uri=https://onbezsojnpsrtuxzwsjr.supabase.co/rest/v1/rpc/customer_orders';

class _OfflineApi extends CustomerApi {
  _OfflineApi() : super(ApiClient());
  bool online = false;
  int orderCalls = 0;

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<Wallet> getWallet() async {
    if (!online) throw const SocketException(_technical);
    return const Wallet(
        availableBalance: '2.73', pendingBalance: '0.00', totalDeposit: '5.00', totalWithdraw: '1.50', bonusBalance: '0.00',
        walletId: 'BE295683', promoCode: 'AARAN24');
  }

  @override
  Future<List<Order>> getOrders() async {
    orderCalls++;
    if (!online) throw const SocketException(_technical);
    return [
      Order(id: 'o1', orderCode: 'EXo1', direction: 'deposit', method: 'evc_plus', status: 'completed', statusMessage: 'Completed',
          amount: '5.00', fee: '0.00', netAmount: '5.00', createdAt: DateTime(2026, 10, 21, 15, 20)),
    ];
  }

  @override
  Future<List<HomeAd>> getHomeAds() async => const [];
  @override
  Future<List<Tip>> getTips([String filter = 'all']) async => const [];
}

Widget _app(_OfflineApi api) => MultiProvider(
      providers: [
        Provider<CustomerApi>.value(value: api),
        ChangeNotifierProvider(create: (_) => AuthProvider(apiClient: ApiClient(), customerApi: api)),
        ChangeNotifierProvider(create: (_) => WalletProvider(customerApi: api)),
        ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: api)),
      ],
      child: MaterialApp(theme: AppTheme.current, home: const RootShell()),
    );

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.somali);

  test('what counts as an internet problem', () {
    expect(isNetworkError(const SocketException(_technical)), isTrue);
    expect(isNetworkError(Exception(_technical)), isTrue);
    expect(isNetworkError(AuthRetryableFetchException(message: _technical)), isTrue);
    expect(isNetworkError(const ApiException(status: 0, code: 'NETWORK_ERROR', message: 'x')), isTrue);
    expect(isNetworkError(const ApiException(status: 400, code: 'INSUFFICIENT_BALANCE', message: 'x')), isFalse);
    expect(isNetworkError(StateError('bad state')), isFalse);
  });

  test('the client turns every connection failure into the friendly message: no SocketException, URL or DNS text', () async {
    for (final failure in <Object>[
      const SocketException(_technical),
      Exception(_technical),
      AuthRetryableFetchException(message: _technical),
    ]) {
      try {
        await ApiClient.guard(() async => throw failure);
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.code, 'NETWORK_ERROR');
        expect(e.message, AppStrings.networkBody);
        for (final bad in ['Socket', 'supabase', 'host', 'DNS', 'errno', 'uri=', 'Exception']) {
          expect(e.message, isNot(contains(bad)));
        }
      }
    }
  });

  test('the words: Somali and English', () {
    expect(AppStrings.networkTitle, 'Internet-kaagu ma fiicna');
    expect(AppStrings.networkBody, 'Fadlan hubi xiriirka internet-kaaga oo isku day mar kale.');
    expect(AppStrings.networkRetry, 'Mar kale isku day');
    AppLanguage.current.value = AppLanguage.english;
    expect(AppStrings.networkTitle, isNot('Internet-kaagu ma fiicna'));
  });

  test('a deposit or withdrawal without internet: the Somali internet message, never the technical text', () {
    for (final isDeposit in [true, false]) {
      final text = PaymentErrors.message(const SocketException(_technical), isDeposit: isDeposit);
      expect(text, contains('Internet-kaagu ma fiicna'));
      expect(text, isNot(contains('Socket')));
    }
  });

  testWidgets('Home without internet: the friendly message and a retry, never "No transactions yet"; it retries by itself', (tester) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _OfflineApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-problem')), findsOneWidget);
    expect(find.byKey(const Key('network-title')), findsOneWidget);
    expect(find.text('Fadlan hubi xiriirka internet-kaaga oo isku day mar kale.'), findsOneWidget);
    expect(find.text('Mar kale isku day'), findsOneWidget);
    expect(find.text(AppStrings.noOrders), findsNothing, reason: 'not "no transactions": they could not be loaded');
    expect(find.textContaining('Socket'), findsNothing);
    expect(find.textContaining('supabase'), findsNothing);
    expect(find.textContaining('Failed host'), findsNothing);

    // The button asks again (still offline: the message stays).
    final before = api.orderCalls;
    await tester.tap(find.byKey(const Key('network-retry')));
    await tester.pumpAndSettle();
    expect(api.orderCalls, greaterThan(before));
    expect(find.byKey(const Key('network-problem')), findsOneWidget);

    // The connection comes back: no tap needed.
    api.online = true;
    await tester.pump(OrdersProvider.networkRetryEvery + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-problem')), findsNothing);
    expect(find.byKey(const Key('recent-order-o1')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the retry button works after the connection returns', (tester) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _OfflineApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    api.online = true;
    await tester.tap(find.byKey(const Key('network-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-problem')), findsNothing);
    expect(find.byKey(const Key('recent-order-o1')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
