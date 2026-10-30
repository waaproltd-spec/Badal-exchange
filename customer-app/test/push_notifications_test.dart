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
import 'dart:async';

import 'package:badal_exchange_customer/services/push_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Serves a wallet and three orders instead of calling the backend.
class _FakeApi extends CustomerApi {
  _FakeApi() : super(ApiClient());

  final registered = <String>[];
  final unregistered = <String>[];
  final opened = <String>[];

  @override
  Future<void> registerPushToken(String token) async => registered.add(token);

  @override
  Future<void> unregisterPushToken(String token) async => unregistered.add(token);

  @override
  Future<Order> getOrder(String id) async {
    opened.add(id);
    return (await getOrders()).firstWhere((o) => o.id == id);
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

late _FakeApi _api;

Widget _app() {
  final api = _api = _FakeApi();
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

/// Firebase stand-in: permission, token and messages under the test's control.
class _FakePlatform implements PushPlatform {
  bool allow = true;
  String? token = 'device-token-1';
  PushMessage? launchedBy;
  final refresh = StreamController<String>.broadcast();
  final foreground = StreamController<PushMessage>.broadcast();
  final opened = StreamController<PushMessage>.broadcast();
  int permissionAsked = 0;
  int deleted = 0;

  @override
  Future<bool> requestPermission() async {
    permissionAsked++;
    return allow;
  }

  @override
  Future<String?> getToken() async => token;

  @override
  Future<void> deleteToken() async => deleted++;

  @override
  Stream<String> get onTokenRefresh => refresh.stream;

  final topics = <String>{};

  @override
  Future<void> subscribe(String topic) async => topics.add(topic);

  @override
  Future<void> unsubscribe(String topic) async => topics.remove(topic);

  @override
  Stream<PushMessage> get onForeground => foreground.stream;

  @override
  Stream<PushMessage> get onOpened => opened.stream;

  @override
  Future<PushMessage?> initialMessage() async => launchedBy;
}

const _depositDone = PushMessage(
  type: 'deposit_completed',
  orderId: 'o2',
  title: 'Deposit-kaagu wuu guulaystay',
  body: 'Lacagta deposit-kaaga si guul leh ayaa loo xaqiijiyey.',
);
const _withdrawDone = PushMessage(
  type: 'withdraw_completed',
  orderId: 'o1',
  title: 'Withdrawal-kaagu wuu guulaystay',
  body: 'Lacagtaada si guul leh ayaa loo bixiyey.',
);

late _FakePlatform _platform;

Future<void> _start(WidgetTester tester, {void Function(_FakePlatform)? setup}) async {
  tester.view.physicalSize = const Size(393, 851);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _platform = _FakePlatform();
  setup?.call(_platform);
  PushNotifications.instance = PushNotifications(_platform);
  addTearDown(() => PushNotifications.instance = null);
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('after login: asks for permission and registers this device; a new token is registered too',
      (tester) async {
    await _start(tester);
    expect(_platform.permissionAsked, 1);
    expect(_api.registered, ['device-token-1']);
    expect(_platform.topics, {'customers'}, reason: 'gets "Send to all customers" messages');
    _platform.refresh.add('device-token-2');
    await tester.pumpAndSettle();
    expect(_api.registered, ['device-token-1', 'device-token-2']);
  });

  testWidgets('permission refused: nothing registered, the app works as usual', (tester) async {
    await _start(tester, setup: (p) => p.allow = false);
    expect(_api.registered, isEmpty);
    expect(_platform.topics, isEmpty);
    expect(find.byKey(const Key('home-deposit')), findsOneWidget);
  });

  testWidgets('tapping a Deposit Completed notification opens that deposit', (tester) async {
    await _start(tester);
    _platform.opened.add(_depositDone);
    await tester.pumpAndSettle();
    expect(_api.opened, ['o2']);
    expect(find.byKey(const Key('transaction-details')), findsOneWidget);
    expect(find.text('EXo2'), findsOneWidget);
  });

  testWidgets('the app started from a Withdrawal Completed notification opens that withdrawal', (tester) async {
    await _start(tester, setup: (p) => p.launchedBy = _withdrawDone);
    expect(_api.opened, ['o1']);
    expect(find.byKey(const Key('transaction-details')), findsOneWidget);
    expect(find.text('EXo1'), findsOneWidget);
  });

  testWidgets('a withdrawal arriving while the app is open: no banner (the app already shows it)', (tester) async {
    await _start(tester);
    _platform.foreground.add(_withdrawDone);
    await tester.pumpAndSettle();
    expect(find.text('Withdrawal-kaagu wuu guulaystay'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(_api.opened, isEmpty);
  });

  test('only our two notifications are understood', () {
    expect(PushMessage.fromData({'type': 'deposit_completed', 'orderId': 'x'})?.orderId, 'x');
    expect(PushMessage.fromData({'type': 'withdraw_completed', 'orderId': 'y'})?.type, 'withdraw_completed');
    expect(PushMessage.fromData({'type': 'deposit_failed', 'orderId': 'x'}), isNull);
    expect(PushMessage.fromData({'type': 'deposit_completed'}), isNull);
    expect(PushMessage.fromData({}), isNull);
    final b = PushMessage.fromData({'type': 'broadcast', 'notificationId': 'n1'}, title: 'Badal', body: 'kuso dhawo')!;
    expect([b.isBroadcast, b.title, b.body], [true, 'Badal', 'kuso dhawo']);
  });

  testWidgets('a "Send to all customers" notification: tapping it opens the Notifications screen', (tester) async {
    await _start(tester);
    _platform.opened.add(const PushMessage(type: 'broadcast', title: 'Badal', body: 'kuso dhawo'));
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsWidgets);
    expect(_api.opened, isEmpty, reason: 'no order to open');
  });

  testWidgets('a broadcast arriving while the app is open: banner with its text; View opens Notifications',
      (tester) async {
    await _start(tester);
    _platform.foreground.add(const PushMessage(type: 'broadcast', title: 'Badal', body: 'kuso dhawo'));
    await tester.pumpAndSettle();
    expect(find.text('Badal'), findsOneWidget);
    expect(find.text('kuso dhawo'), findsOneWidget);
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsWidgets);
  });

  test('logout: this device stops getting the notifications', () async {
    final platform = _FakePlatform();
    final push = PushNotifications(platform);
    final api = _FakeApi();
    await push.start(api);
    expect(platform.topics, {'customers'});
    await push.stop(api);
    expect(platform.topics, isEmpty, reason: 'no broadcasts after logout');
    expect(api.unregistered, ['device-token-1']);
    expect(platform.deleted, 1);
    platform.refresh.add('device-token-9');
    await Future<void>.delayed(Duration.zero);
    expect(api.registered, ['device-token-1'], reason: 'no longer listening after logout');
  });
}
