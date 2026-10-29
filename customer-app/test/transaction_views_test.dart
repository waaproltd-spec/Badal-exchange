import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/screens/deposit/deposit_result_screen.dart';
import 'package:badal_exchange_customer/screens/orders/orders_list_screen.dart';
import 'package:badal_exchange_customer/screens/withdraw/withdraw_result_screen.dart';
import 'package:badal_exchange_customer/state/orders_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Order _order({
  required String id,
  required String direction,
  String method = 'evc_plus',
  String status = 'completed',
  String amount = '1.00',
  String? before,
  String? after,
  String? ref,
  String? phone = '252610346060',
  String? account,
}) =>
    Order(
      id: id,
      orderCode: 'EX$id',
      direction: direction,
      method: method,
      status: status,
      statusMessage: status,
      phoneNumber: phone,
      accountId: account,
      amount: amount,
      fee: '0.00',
      netAmount: amount,
      transactionRef: ref,
      balanceBefore: before,
      balanceAfter: after,
      createdAt: DateTime(2026, 10, 21, 19, 41),
    );

class _FakeApi extends CustomerApi {
  _FakeApi(this.orders) : super(ApiClient());

  final List<Order> orders;

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<List<Order>> getOrders() async => orders;
}

Widget _host(Widget child, [List<Order> orders = const []]) {
  final api = _FakeApi(orders);
  return MultiProvider(
    providers: [
      Provider<CustomerApi>.value(value: api),
      ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: api)),
    ],
    child: MaterialApp(theme: AppTheme.current, home: child),
  );
}

Future<void> _phone(WidgetTester tester, [Size size = const Size(393, 851)]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  final deposit = _order(id: 'd1', direction: 'deposit', before: '0.25', after: '1.25', ref: '7497945808');
  final withdrawal = _order(
      id: 'w1', direction: 'withdraw', method: 'onexbet', phone: null, account: '244208987', before: '1.25', after: '0.25');
  final unpaid = _order(id: 'd2', direction: 'deposit', status: 'pending', amount: '5.00');

  testWidgets('Orders: All / Deposits / Withdrawals filter', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_host(const OrdersListScreen(), [deposit, withdrawal, unpaid]));
    await tester.pumpAndSettle();
    expect(find.text('Deposit · EVC Plus'), findsNWidgets(2));
    expect(find.text('Withdraw · 1XBET'), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter-deposits')));
    await tester.pumpAndSettle();
    expect(find.text('Deposit · EVC Plus'), findsNWidgets(2));
    expect(find.text('Withdraw · 1XBET'), findsNothing);

    await tester.tap(find.byKey(const Key('filter-withdrawals')));
    await tester.pumpAndSettle();
    expect(find.text('Deposit · EVC Plus'), findsNothing);
    expect(find.text('Withdraw · 1XBET'), findsOneWidget);
  });

  testWidgets('tapping an order opens Transaction Details with the balance before and after', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_host(const OrdersListScreen(), [withdrawal, deposit]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Withdraw · 1XBET'));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const Key('transaction-details'));
    expect(find.text('Transaction Details'), findsOneWidget);
    String? valueOf(String label) {
      final row = find.ancestor(of: find.descendant(of: sheet, matching: find.text(label)), matching: find.byType(Row)).first;
      final texts = tester.widgetList<SelectableText>(find.descendant(of: row, matching: find.byType(SelectableText)));
      return texts.isEmpty ? null : texts.first.data;
    }

    expect(valueOf('Transaction ID'), 'EXw1');
    expect(valueOf('Type'), 'Withdraw');
    expect(valueOf('1XBET Account'), '244208987');
    expect(valueOf('Amount'), '-\$1.00');
    expect(valueOf('Balance Before'), '\$1.25');
    expect(valueOf('Balance After'), '\$0.25');
    expect(find.descendant(of: sheet, matching: find.text('Withdrawal Confirmed')), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deposit · EVC Plus'));
    await tester.pumpAndSettle();
    expect(valueOf('EVC PLUS Account'), '+252610346060');
    expect(find.text('Transfer ID'), findsNothing, reason: 'the transfer number is for agents only');
    expect(valueOf('Balance After'), '\$1.25');
  });

  testWidgets('an unpaid deposit has no balance lines and says it is being verified', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_host(const OrdersListScreen(), [unpaid]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deposit · EVC Plus'));
    await tester.pumpAndSettle();
    expect(find.text('Your payment is being verified…'), findsAtLeastNWidgets(1));
    expect(find.text('Pending'), findsNothing);
    expect(find.text('Balance Before'), findsNothing);
    expect(find.text('Balance After'), findsNothing);
  });

  testWidgets('result screens: confirmed deposit, withdrawal in progress, small phone, Back to Home', (tester) async {
    await _phone(tester, const Size(320, 568));
    await tester.pumpWidget(_host(DepositResultScreen(order: deposit)));
    expect(find.text('USD Deposited'), findsOneWidget);
    expect(find.text('Deposit Confirmed'), findsOneWidget);
    expect(find.text('7497945808'), findsNothing, reason: 'the transfer number is for agents only');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(WithdrawResultScreen(
        order: _order(id: 'w2', direction: 'withdraw', status: 'processing', before: '2.00', after: '1.00'))));
    expect(find.text('USD Withdrawn'), findsOneWidget);
    expect(find.text('Your payment is being verified…'), findsOneWidget);
    expect(find.text('Pending'), findsNothing);
    expect(find.text('Withdrawal Confirmed'), findsNothing, reason: 'only once it is paid out');
    await tester.scrollUntilVisible(find.byKey(const Key('back-to-home')), 120, scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deposit code box: no betting company shows it (they use the customer\'s own code)', (tester) async {
    await _phone(tester);
    Order withCode(String method) => Order(
          id: 'd-$method',
          orderCode: 'EXD$method',
          direction: 'deposit',
          method: method,
          status: 'processing',
          statusMessage: 'processing',
          accountId: '1847412855',
          depositCode: 'KSBW',
          amount: '5.00',
          fee: '0.00',
          netAmount: '5.00',
          createdAt: DateTime(2026, 10, 22, 4),
        );

    for (final method in ['melbet', '888starz', 'onexbet', 'winwin', 'betwinner', 'dbbet', 'betjam', 'betongame']) {
      await tester.pumpWidget(_host(DepositResultScreen(order: withCode(method))));
      expect(find.text('KSBW'), findsNothing, reason: method);
      expect(find.text('DEPOSIT CODE'), findsNothing, reason: method);
    }
  });

  testWidgets('Somali labels', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _phone(tester);
    await tester.pumpWidget(_host(DepositResultScreen(order: deposit)));
    expect(find.text('Dhigashada waa la xaqiijiyay'), findsOneWidget);
    expect(find.text('USD la dhigay'), findsOneWidget);
  });

  testWidgets('a late withdrawal says why; an on-time one says nothing extra', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _phone(tester);
    final late = Order(
      id: 'w-late', orderCode: 'EX8N5NPM', direction: 'withdraw', method: 'evc_plus', status: 'pending',
      statusMessage: 'pending', phoneNumber: '252610346060', amount: '1.00', fee: '0.00', netAmount: '1.00',
      createdAt: DateTime(2026, 10, 28, 16, 44), delay: 'provider_unavailable');
    await tester.pumpWidget(_host(WithdrawResultScreen(order: late)));
    expect(find.byKey(const Key('delay-notice')), findsOneWidget);
    expect(find.text('Maxay u daahday?'), findsOneWidget);
    expect(find.textContaining('Lacagtaadu way badbaadsan tahay'), findsOneWidget);

    final onTime = _order(id: 'w-ok', direction: 'withdraw', status: 'pending');
    await tester.pumpWidget(_host(WithdrawResultScreen(order: onTime)));
    expect(find.byKey(const Key('delay-notice')), findsNothing);
  });

  test('every delay code has its own words, and an unknown one still reads well', () {
    AppLanguage.current.value = AppLanguage.english;
    final texts = ['provider_unavailable', 'provider_balance', 'confirming', 'manual', 'waiting', 'something_new']
        .map(AppStrings.delayReason)
        .toList();
    expect(texts.toSet().length, 5, reason: 'waiting and an unknown code share the queue text');
    expect(texts[0], contains('will be sent automatically'));
    expect(Order.fromJson({
      'id': 'x', 'orderCode': 'EXX', 'direction': 'withdraw', 'method': 'golis', 'status': 'pending',
      'amount': '1.00', 'fee': '0.00', 'netAmount': '1.00', 'createdAt': '2026-10-28T13:44:00Z', 'delay': 'manual',
    }).delay, 'manual');
  });
}
