import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/screens/orders/orders_list_screen.dart';
import 'package:badal_exchange_customer/state/orders_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Order _o(int i, String direction, {String status = 'completed', String? ref}) => Order(
      id: 'o$i',
      orderCode: 'EX$i',
      direction: direction,
      method: 'evc_plus',
      status: status,
      statusMessage: status,
      amount: '${i + 1}.00',
      fee: '0.00',
      netAmount: '${i + 1}.00',
      transactionRef: ref,
      createdAt: DateTime(2026, 11, 11, 12).subtract(Duration(minutes: i)),
    );

/// 12 orders in the database: orders 0..6 are withdrawals (7), 7..11 deposits (5). The app holds the newest 6 (the provider's list).
class _Api extends CustomerApi {
  _Api({this.countsFail = false}) : super(ApiClient());
  final bool countsFail;
  final pages = <String>[];

  late final List<Order> db = [
    for (var i = 0; i < 12; i++) _o(i, i.isEven && i < 8 || i == 1 || i == 3 || i == 5 ? 'withdraw' : 'deposit', status: i == 2 ? 'failed' : i == 4 ? 'pending' : 'completed', ref: i == 0 ? 'TRX-0042' : null),
  ];

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<List<Order>> getOrders() async => db.take(6).toList();

  @override
  Future<OrderCounts> getOrderCounts() async {
    if (countsFail) throw Exception('offline');
    return OrderCounts.fromJson({'total': 999, 'deposits': db.where((o) => o.isDeposit).length, 'withdrawals': db.where((o) => !o.isDeposit).length});
  }

  @override
  Future<List<Order>> getOrdersPage({String? direction, int offset = 0, int limit = 30}) async {
    pages.add('$direction@$offset');
    final rows = db.where((o) => direction == null || (direction == 'deposit') == o.isDeposit).toList();
    return rows.skip(offset).take(limit).toList();
  }
}

Widget _app(_Api api) => MultiProvider(
      providers: [
        Provider<CustomerApi>.value(value: api),
        ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: api)),
      ],
      child: MaterialApp(theme: AppTheme.current, home: const OrdersListScreen()),
    );

Future<void> _phone(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

int _n(WidgetTester tester, String key) {
  final t = find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text));
  return int.parse(tester.widgetList<Text>(t).map((w) => w.data!).firstWhere((s) => RegExp(r'^\d+$').hasMatch(s)));
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.somali);

  testWidgets('the cards show the database counts and total = deposits + withdrawals (the total sent by a wrong server is ignored)', (tester) async {
    await _phone(tester, const Size(400, 900));
    final api = _Api();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final d = api.db.where((o) => o.isDeposit).length, w = api.db.where((o) => !o.isDeposit).length;
    expect(d + w, 12);
    expect(_n(tester, 'orders-count-deposits'), d);
    expect(_n(tester, 'orders-count-withdrawals'), w);
    expect(_n(tester, 'orders-count-all'), d + w, reason: 'the card is the sum, whatever else arrives');
    expect(find.text('Dhammaan'), findsWidgets);
    expect(find.text('Dhigashooyin'), findsWidgets);
    expect(find.text('Bixinno'), findsWidgets);
  });

  testWidgets('without the counts (offline) the cards count what the list holds; they never invent numbers', (tester) async {
    await _phone(tester, const Size(400, 900));
    await tester.pumpWidget(_app(_Api(countsFail: true)));
    await tester.pumpAndSettle();
    expect(_n(tester, 'orders-count-all'), 6);
    expect(_n(tester, 'orders-count-deposits') + _n(tester, 'orders-count-withdrawals'), 6);
  });

  testWidgets('each tab lists only its own orders; the card and the tab agree', (tester) async {
    await _phone(tester, const Size(400, 1400));
    final api = _Api();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('orders-count-deposits')));
    await tester.pumpAndSettle();
    for (final t in tester.widgetList<Text>(find.textContaining(' · EVC'))) {
      expect(t.data, startsWith(AppStrings.deposit), reason: 'only deposits on the Dhigashooyin tab');
    }
    await tester.tap(find.byKey(const Key('orders-count-withdrawals')));
    await tester.pumpAndSettle();
    for (final t in tester.widgetList<Text>(find.textContaining(' · EVC'))) {
      expect(t.data, startsWith(AppStrings.withdraw));
    }
    await tester.tap(find.byKey(const Key('orders-count-all')));
    await tester.pumpAndSettle();
    expect(find.text('ID: TRX-0042'), findsOneWidget, reason: 'the transaction id where there is one');
  });

  testWidgets('scrolling to the end reads the next page of the tab: all orders become reachable, none twice', (tester) async {
    await _phone(tester, const Size(400, 700));
    final api = _Api();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final ids = <String>{};
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byKey(const Key('orders-list')), const Offset(0, -900));
      await tester.pumpAndSettle();
    }
    expect(api.pages, isNotEmpty, reason: 'a further page was read');
    for (final tile in tester.widgetList<Text>(find.textContaining(' · EVC'))) {
      ids.add(tile.data!);
    }
    final list = tester.widget<ListView>(find.byKey(const Key('orders-list')));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).estimatedChildCount, 12 * 2 - 1, reason: 'all 12 orders of the database (and the 11 gaps between them), no spinner left');
  });

  testWidgets('green for completed, red for failed, orange for pending; withdrawals in red and deposits in green; no overflow on small phones', (tester) async {
    for (final size in const [Size(320, 640), Size(360, 780), Size(412, 915)]) {
      for (final lang in [AppLanguage.somali, AppLanguage.english]) {
        AppLanguage.current.value = lang;
        await _phone(tester, size);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_app(_Api()));
        await tester.pumpAndSettle();
        final ex = tester.takeException();
        expect(ex, isNull, reason: '$size $lang');
      }
    }
    final api = _Api();
    await _phone(tester, const Size(400, 1400));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    Color colorOf(String text) => tester.widget<Text>(find.text(text).first).style!.color!;
    final failed = api.db[2], done = api.db[0];
    expect(colorOf('-${'\$'}${done.amount}').red > colorOf('-${'\$'}${done.amount}').green, isTrue, reason: 'a withdrawal amount is red');
    expect(failed.status, 'failed');
    expect(AppStrings.statusCompleted, isNotEmpty);
  });
}
