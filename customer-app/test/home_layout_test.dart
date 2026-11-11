import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/app_content.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/tip.dart';
import 'package:badal_exchange_customer/models/wallet.dart';
import 'package:badal_exchange_customer/screens/root/root_shell.dart';
import 'package:badal_exchange_customer/widgets/floating_nav_bar.dart';
import 'package:badal_exchange_customer/widgets/wallet_card.dart';
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

  @override
  Future<List<Tip>> getTips([String filter = 'all']) async => [
        Tip.fromJson({'id': 'f1', 'title': 'Free pick', 'sport': 'football', 'teamCount': 3, 'isPaid': false, 'oddsCode': 'FREE-123'}),
      ];

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

  testWidgets('the bottom bar is Home, Orders, TIPS, Profile; Home has no TIPS card; the TIPS tab opens the tips', (tester) async {
    await _phone(tester, _phones.values.first);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-tips')), findsNothing, reason: 'TIPS is a tab, not a Home card');
    final bar = find.byType(FloatingNavBar);
    for (final label in [AppStrings.home, AppStrings.orders, AppStrings.tips, AppStrings.profile]) {
      expect(find.descendant(of: bar, matching: find.text(label)), findsOneWidget, reason: label);
    }
    expect(tester.widget<FloatingNavBar>(bar).tabs.length, 4);
    await tester.tap(find.descendant(of: bar, matching: find.text(AppStrings.tips)));
    await tester.pumpAndSettle();
    expect(find.text('FREE-123'), findsOneWidget);
    expect(find.text(AppStrings.tipsAll), findsOneWidget);
    // Profile is still the last tab.
    await tester.tap(find.descendant(of: bar, matching: find.text(AppStrings.profile)));
    await tester.pumpAndSettle();
    expect(find.text('FREE-123'), findsNothing);
  });

  for (final MapEntry(key: name, value: size) in _phones.entries) {
    testWidgets('$name: two recent orders show above the bottom bar, nothing overflows', (tester) async {
      await _phone(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final navTop = tester.getRect(find.byKey(const Key('floating-nav'))).top;
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
    final navTop = tester.getRect(find.byKey(const Key('floating-nav'))).top;
    expect(tester.getRect(find.byKey(const Key('recent-order-o2'))).bottom <= navTop, isTrue);
  });

  testWidgets('View all opens the Orders tab', (tester) async {
    await _phone(tester, const Size(360, 780));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('view-all-orders')));
    await tester.pumpAndSettle();
    expect(tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex, 1);
  });

  testWidgets('Deposit and Withdraw: only the word, a download / upload icon and an arrow, the same size, side by side, low', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    for (final size in _phones.values) {
      await _phone(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      final deposit = tester.getRect(find.byKey(const Key('home-deposit')));
      final withdraw = tester.getRect(find.byKey(const Key('home-withdraw')));
      expect(deposit.size, withdraw.size, reason: '$size');
      expect(deposit.top, withdraw.top);
      expect(deposit.height <= 56, isTrue, reason: 'low: ${deposit.height}');
      expect(deposit.right < withdraw.left, isTrue, reason: 'side by side');
      for (final k in ['home-deposit', 'home-withdraw']) {
        expect(find.descendant(of: find.byKey(Key(k)), matching: find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
      }
      expect(find.descendant(of: find.byKey(const Key('home-deposit')), matching: find.byIcon(Icons.file_download_rounded)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('home-withdraw')), matching: find.byIcon(Icons.file_upload_rounded)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('home-deposit')), matching: find.text('Dhigasho')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('home-withdraw')), matching: find.text('Bixinta')), findsOneWidget);
      for (final gone in ['Hadda dhigasho', 'Kuso shub lacag', 'Hadda bixin', 'Kala bax lacagta']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
    }
  });

  testWidgets('Dhigasho is green and Bixinta is red; the Caawimaad pill has its own band: it never covers an order, and the nav bar never covers it', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    for (final size in _phones.values) {
      await _phone(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      Color tint(String k) {
        final box = tester.widget<DecoratedBox>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(DecoratedBox)).first);
        return ((box.decoration as BoxDecoration).gradient! as LinearGradient).colors.first;
      }
      final g = tint('home-deposit'), r = tint('home-withdraw');
      expect(g.green > g.red && g.green > g.blue, isTrue, reason: 'green deposit $size');
      expect(r.red > r.green && r.red > r.blue, isTrue, reason: 'red withdraw $size');
      final pill = tester.getRect(find.byKey(const Key('support-button')));
      final list = tester.getRect(find.descendant(of: find.byType(RefreshIndicator), matching: find.byType(ListView)).first);
      expect(pill.top >= list.bottom - 0.5, isTrue, reason: 'the pill starts under the list: pill ${pill.top} list ${list.bottom} $size');
      final nav = tester.getRect(find.byType(FloatingNavBar));
      expect(pill.bottom <= nav.top + 0.5, isTrue, reason: 'above the navigation bar $size');
      // scrolled to the end, the last order is fully visible above the pill
      await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
    }
  });

  testWidgets('the eye hides and shows the wallet balance and the bonus balance together, and is remembered while the app is open', (tester) async {
    addTearDown(() => BalancePrivacy.hidden.value = false);
    BalancePrivacy.hidden.value = false;
    await _phone(tester, const Size(360, 780));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('balance-eye')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('available-balance'))).data, '\$2.73');
    expect(find.text('\$0.00'), findsOneWidget, reason: 'the bonus');
    await tester.tap(find.byKey(const Key('balance-eye')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('available-balance'))).data, '••••••');
    expect(find.text('••••••'), findsNWidgets(2), reason: 'the wallet balance and the bonus balance, with one eye');
    expect(find.text('\$2.73'), findsNothing);
    expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
    // the Wallet ID and promo code are not amounts: still shown
    expect(find.text('BE295683'), findsOneWidget);
    // remembered while the app stays open: the screen is built again, still hidden
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('available-balance'))).data, '••••••');
    await tester.tap(find.byKey(const Key('balance-eye')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('available-balance'))).data, '\$2.73');
    expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
  });
}
