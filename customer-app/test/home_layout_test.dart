import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/app_content.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/wallet.dart';
import 'package:badal_exchange_customer/screens/root/root_shell.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/state/orders_provider.dart';
import 'package:badal_exchange_customer/state/wallet_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Serves a wallet and three orders instead of calling the backend.
class _FakeApi extends CustomerApi {
  _FakeApi() : super(ApiClient());

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<Wallet> getWallet() async => const Wallet(
        availableBalance: '2.73',
        pendingBalance: '0.00',
        totalDeposit: '5.00',
        totalWithdraw: '1.50',
        bonusBalance: '0.00',
        walletId: 'BE295683',
        promoCode: 'AARAN24',
      );

  @override
  Future<List<Order>> getOrders() async => [
        _order('o1', 'withdraw', 'onexbet', '1.50', DateTime(2026, 10, 21, 16, 46)),
        _order('o2', 'deposit', 'onexbet', '5.00', DateTime(2026, 10, 21, 15, 20)),
        _order('o3', 'deposit', 'evc_plus', '1.00', DateTime(2026, 10, 20, 9, 5)),
      ];

  @override
  Future<List<HomeAd>> getHomeAds() async => const [];

  static Order _order(String id, String direction, String method, String amount, DateTime at) => Order(
        id: id,
        orderCode: 'EX$id',
        direction: direction,
        method: method,
        status: 'completed',
        statusMessage: 'Completed',
        amount: amount,
        fee: '0.00',
        netAmount: amount,
        createdAt: at,
      );
}

Widget _app() {
  final api = _FakeApi();
  return MultiProvider(
    providers: [
      Provider<CustomerApi>.value(value: api),
      ChangeNotifierProvider(create: (_) => AuthProvider(apiClient: ApiClient(), customerApi: api)),
      ChangeNotifierProvider(create: (_) => WalletProvider(customerApi: api)),
      ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: api)),
    ],
    child: MaterialApp(theme: AppTheme.current, home: const RootShell()),
  );
}

/// A phone screen in logical pixels, with a status bar and gesture bar.
Future<void> _phone(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
  addTearDown(tester.view.reset);
}

/// Android phones from small to large (width x height, dp).
const _phones = {
  'small 320x640': Size(320, 640),
  'small 360x640': Size(360, 640),
  'standard 360x780': Size(360, 780),
  'standard 393x851': Size(393, 851),
  'large 412x915': Size(412, 915),
};

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  for (final MapEntry(key: name, value: size) in _phones.entries) {
    testWidgets('$name: two recent orders show above the bottom bar, nothing overflows', (tester) async {
      await _phone(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final navTop = tester.getRect(find.byType(NavigationBar)).top;
      for (final id in ['o1', 'o2']) {
        final tile = tester.getRect(find.byKey(Key('recent-order-$id')));
        expect(tile.bottom <= navTop, isTrue, reason: 'order $id ends at ${tile.bottom}, bar starts at $navTop');
      }
      // Each order shows its service, amount, date and status.
      expect(find.text('Withdraw · 1XBET'), findsOneWidget);
      expect(find.text('-\$1.50'), findsOneWidget);
      expect(find.text('Deposit · 1XBET'), findsOneWidget);
      expect(find.text('+\$5.00'), findsOneWidget);
      expect(find.byKey(const Key('view-all-orders')), findsOneWidget);

      // Deposit and Withdraw are the same size, side by side.
      final deposit = tester.getRect(find.byKey(const Key('home-deposit')));
      final withdraw = tester.getRect(find.byKey(const Key('home-withdraw')));
      expect(deposit.size, withdraw.size);
      expect(deposit.top, withdraw.top);

      // The wallet card keeps all its values.
      expect(find.text('\$2.73'), findsOneWidget);
      expect(find.text('AARAN24'), findsOneWidget);
      expect(find.text('BE295683'), findsOneWidget);
      expect(find.text('\$0.00'), findsOneWidget);
    });
  }

  testWidgets('Somali on a 320-wide phone fits too', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _phone(tester, const Size(320, 640));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final navTop = tester.getRect(find.byType(NavigationBar)).top;
    expect(tester.getRect(find.byKey(const Key('recent-order-o2'))).bottom <= navTop, isTrue);
  });

  testWidgets('View all opens the Orders tab', (tester) async {
    await _phone(tester, const Size(360, 780));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('view-all-orders')));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
  });
}
