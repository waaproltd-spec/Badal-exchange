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
import 'package:badal_exchange_customer/theme/colors.dart';
import 'package:badal_exchange_customer/theme/theme_mode.dart';
import 'package:badal_exchange_customer/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    child: ThemeModeScope(builder: (_) => MaterialApp(theme: AppTheme.current, home: const RootShell())),
  );
}

Future<void> _phone(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The background of the screen on show.
Color _scaffold(WidgetTester tester) => tester
    .widgetList<Scaffold>(find.byType(Scaffold).hitTestable())
    .map((s) => s.backgroundColor)
    .whereType<Color>()
    .first;

Future<void> _openProfile(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.person_outline_rounded).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.current.value = AppLanguage.english;
    AppThemeMode.current.value = ThemeMode.light;
    AppThemeMode.platformBrightness.value = Brightness.light;
  });

  testWidgets('Profile: Dark repaints every screen in place and is remembered', (tester) async {
    await _phone(tester, const Size(393, 851));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(_scaffold(tester), AppColors.cream);

    await _openProfile(tester);
    expect(find.text('Appearance'), findsOneWidget);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(AppThemeMode.isDark, isTrue);
    expect(Theme.of(tester.element(find.text('Appearance'))).brightness, Brightness.dark);
    // Still on Profile, now dark; text is light.
    expect(find.text('Appearance'), findsOneWidget);
    expect(_scaffold(tester).computeLuminance(), lessThan(0.05));
    final label = tester.widget<Text>(find.text('Appearance'));
    expect(label.style!.color!.computeLuminance(), greaterThan(0.7));
    expect((await SharedPreferences.getInstance()).getString('theme_mode'), 'dark');

    // Home is dark too; nothing overflows.
    await tester.tap(find.byIcon(Icons.home_outlined).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-deposit')), findsOneWidget);
    expect(_scaffold(tester).computeLuminance(), lessThan(0.05));
    expect(tester.takeException(), isNull);

    // Back to Light.
    await _openProfile(tester);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(_scaffold(tester), AppColors.cream);
    expect((await SharedPreferences.getInstance()).getString('theme_mode'), 'light');
  });

  testWidgets('Phone follows the phone\'s light/dark setting', (tester) async {
    await _phone(tester, const Size(393, 851));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openProfile(tester);
    await tester.tap(find.text('Phone'));
    await tester.pumpAndSettle();
    expect(AppThemeMode.isDark, isFalse);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpAndSettle();
    expect(AppThemeMode.isDark, isTrue);
    expect(_scaffold(tester).computeLuminance(), lessThan(0.05));
    expect(find.text('Appearance'), findsOneWidget, reason: 'stays on the same screen');
  });

  test('a saved choice is loaded at start', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    await AppThemeMode.load();
    expect(AppThemeMode.current.value, ThemeMode.dark);
    SharedPreferences.setMockInitialValues({'theme_mode': 'nonsense'});
    await AppThemeMode.load();
    expect(AppThemeMode.current.value, ThemeMode.system);
  });

  for (final somali in [false, true]) {
    for (final size in const [Size(320, 568), Size(360, 640), Size(412, 915)]) {
      testWidgets('dark, ${somali ? 'Somali' : 'English'}, ${size.width.toInt()}x${size.height.toInt()}: '
          'Home and Profile fit', (tester) async {
        AppLanguage.current.value = somali ? AppLanguage.somali : AppLanguage.english;
        AppThemeMode.current.value = ThemeMode.dark;
        await _phone(tester, size);
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _openProfile(tester);
        await tester.scrollUntilVisible(find.byKey(const Key('theme-mode')), 100,
            scrollable: find.byType(Scrollable).last);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
