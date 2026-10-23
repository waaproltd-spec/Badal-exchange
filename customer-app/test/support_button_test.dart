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
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Serves a wallet and three orders instead of calling the backend.
class _FakeApi extends CustomerApi {
  _FakeApi(this.contacts) : super(ApiClient());

  /// What admins set in the Agent App; null: the request fails.
  final Map<String, String>? contacts;
  int contactRequests = 0;

  @override
  Future<Map<String, String>> getSupportContacts() async {
    contactRequests++;
    final c = contacts;
    if (c == null) throw Exception('offline');
    return c;
  }

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

Widget _app(_FakeApi api) {
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

/// Records what the app asked Android to open.
class _FakeLauncher extends Fake with MockPlatformInterfaceMixin implements UrlLauncherPlatform {
  final opened = <String>[];
  bool canOpen = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add('$url ${options.mode.name}');
    return canOpen;
  }
}

Future<void> _phone(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
  addTearDown(tester.view.reset);
}

const _contacts = {'whatsapp': '+252 61 234 5678', 'telegram': '@BaariSupport', 'facebook': ''};

late _FakeLauncher _launcher;

Future<_FakeApi> _open(WidgetTester tester, {Map<String, String>? contacts = _contacts, Size size = const Size(393, 851)}) async {
  await _phone(tester, size);
  final api = _FakeApi(contacts);
  await tester.pumpWidget(_app(api));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  setUp(() {
    AppLanguage.current.value = AppLanguage.english;
    _launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = _launcher;
  });

  testWidgets('tap opens WhatsApp and Telegram; tap again or elsewhere closes', (tester) async {
    final api = await _open(tester);
    expect(find.text('Support'), findsOneWidget);
    expect(find.byKey(const Key('support-menu')), findsNothing);
    expect(api.contactRequests, 0, reason: 'asked for only when opened');

    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Telegram'), findsOneWidget);
    // The menu sits right above the button.
    expect(tester.getRect(find.byKey(const Key('support-menu'))).bottom,
        lessThanOrEqualTo(tester.getRect(find.byKey(const Key('support-button'))).top));

    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-menu')), findsNothing, reason: 'tapped again');

    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(100, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-menu')), findsNothing, reason: 'tapped elsewhere');
    expect(api.contactRequests, 1, reason: 'loaded once');
  });

  testWidgets('WhatsApp opens a wa.me chat with the official number, Telegram the official account', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('support-whatsapp')));
    await tester.pumpAndSettle();
    expect(_launcher.opened, ['https://wa.me/252612345678 externalApplication']);
    expect(find.byKey(const Key('support-menu')), findsNothing);

    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('support-telegram')));
    await tester.pumpAndSettle();
    expect(_launcher.opened.last, 'https://t.me/BaariSupport externalApplication');
  });

  testWidgets('when it can not be opened, the customer is told where to reach support', (tester) async {
    await _open(tester);
    _launcher.canOpen = false;
    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('support-whatsapp')));
    await tester.pump();
    expect(find.text('Could not open WhatsApp. Contact us at https://wa.me/252612345678'), findsOneWidget);
  });

  testWidgets('only what admins set is offered; nothing set: no made-up links', (tester) async {
    await _open(tester, contacts: {'whatsapp': '', 'telegram': '@BaariSupport'});
    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-whatsapp')), findsNothing);
    expect(find.byKey(const Key('support-telegram')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _open(tester, contacts: {'whatsapp': '', 'telegram': ''});
    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-whatsapp')), findsNothing);
    expect(find.byKey(const Key('support-telegram')), findsNothing);
    expect(find.text('Support chat is not set up yet. Please try again later.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _open(tester, contacts: null); // request failed
    await tester.tap(find.byKey(const Key('support-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-unavailable')), findsOneWidget);
    expect(_launcher.opened, isEmpty);
  });

  for (final size in const [Size(320, 568), Size(320, 640), Size(360, 640), Size(412, 915)]) {
    for (final somali in [false, true]) {
      testWidgets('${somali ? 'Somali' : 'English'} ${size.width.toInt()}x${size.height.toInt()}: '
          'above the bottom bar, last order can scroll clear of it', (tester) async {
        AppLanguage.current.value = somali ? AppLanguage.somali : AppLanguage.english;
        await _open(tester, size: size);
        final button = tester.getRect(find.byKey(const Key('support-button')));
        final nav = tester.getRect(find.byType(NavigationBar));
        expect(button.bottom, lessThanOrEqualTo(nav.top));
        expect(button.right, lessThanOrEqualTo(size.width - 16));
        // Scrolled to the end, the last order ends above the button.
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
        await tester.pumpAndSettle();
        final last = tester.getRect(find.byKey(const Key('recent-order-o3')));
        expect(last.bottom, lessThanOrEqualTo(button.top));
        await tester.tap(find.byKey(const Key('support-button')));
        await tester.pumpAndSettle();
        final menu = tester.getRect(find.byKey(const Key('support-menu')));
        expect(menu.left, greaterThanOrEqualTo(16));
        expect(menu.top, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
