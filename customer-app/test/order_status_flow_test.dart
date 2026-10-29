import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/screens/deposit/deposit_result_screen.dart';
import 'package:badal_exchange_customer/screens/orders/orders_list_screen.dart';
import 'package:badal_exchange_customer/screens/withdraw/withdraw_result_screen.dart';
import 'package:badal_exchange_customer/services/success_sound.dart';
import 'package:badal_exchange_customer/state/orders_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:badal_exchange_customer/widgets/transaction_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a customer sees of an order's life: never "Pending"; "Your payment is
/// being verified…" until the server says completed or failed; and the app
/// keeps asking, whatever slow or failed answers come meanwhile.

const verifying = 'Your payment is being verified…';

Order _order(String id, String status, {String direction = 'deposit', String? reason}) => Order(
      id: id,
      orderCode: 'EX${id.toUpperCase()}',
      direction: direction,
      method: 'evc_plus',
      status: status,
      statusMessage: status,
      phoneNumber: '252610346060',
      amount: '4.00',
      fee: '0.00',
      netAmount: '4.00',
      failureReason: reason,
      createdAt: DateTime.now().subtract(const Duration(seconds: 20)),
      completedAt: status == 'completed' ? DateTime.now() : null,
    );

/// getOrder answers from [script] in turn (an Order, or an exception to throw);
/// the last one repeats. getOrders answers from [lists] the same way (a list, or an exception).
class ScriptedApi extends CustomerApi {
  ScriptedApi({this.script = const [], this.lists = const []}) : super(ApiClient());

  final List<Object> script;
  final List<Object> lists;
  int getOrderCalls = 0;
  int getOrdersCalls = 0;

  @override
  Stream<String> get liveChanges => const Stream.empty();

  @override
  Future<Order> getOrder(String id) async {
    final a = script[getOrderCalls < script.length ? getOrderCalls : script.length - 1];
    getOrderCalls++;
    if (a is Exception) throw a;
    return a as Order;
  }

  @override
  Future<List<Order>> getOrders() async {
    final l = lists[getOrdersCalls < lists.length ? getOrdersCalls : lists.length - 1];
    getOrdersCalls++;
    if (l is Exception) throw l;
    return l as List<Order>;
  }
}

class CountingPlayer implements SoundPlayer {
  int plays = 0;

  @override
  Future<void> play() async => plays++;
}

Widget _host(Widget child, ScriptedApi api) => MultiProvider(
      providers: [
        Provider<CustomerApi>.value(value: api),
        ChangeNotifierProvider(create: (_) => OrdersProvider(customerApi: api)),
      ],
      child: MaterialApp(theme: AppTheme.current, home: child),
    );

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(393, 851);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Moves time on by exactly [wait] (the app asks again after 3 s, a little
/// longer after each failed try, at most 10 s), then lets the answer arrive.
Future<void> _next(WidgetTester tester, [Duration wait = const Duration(seconds: 3)]) async {
  await tester.pump(wait);
  await tester.pump();
  await tester.pump();
}

const timeout = ApiException(status: 0, code: 'NETWORK', message: 'The request timed out.');

void main() {
  late CountingPlayer player;

  setUp(() {
    AppLanguage.current.value = AppLanguage.english;
    SharedPreferences.setMockInitialValues({});
    player = CountingPlayer();
    SuccessSound.instance = SuccessSound(player: player);
  });

  group('the Orders list', () {
    testWidgets('never shows Pending: Completed, Failed, or "being verified"', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(lists: [
        [
          _order('a1', 'pending'),
          _order('a2', 'processing', direction: 'withdraw'),
          _order('a3', 'completed'),
          _order('a4', 'failed', reason: 'Payment not received'),
          _order('a5', 'cancelled'),
          _order('a6', 'expired'),
        ]
      ]);
      await tester.pumpWidget(_host(const OrdersListScreen(), api));
      await tester.pumpAndSettle();
      expect(find.text('Pending'), findsNothing);
      expect(find.text('Processing'), findsNothing);
      expect(find.text('Cancelled'), findsNothing);
      expect(find.text('Expired'), findsNothing);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Failed'), findsNWidgets(3), reason: 'failed, cancelled and expired are definitive failures');
      expect(find.text(verifying), findsNWidgets(2), reason: 'the two still being confirmed');
    });

    testWidgets('Somali: the same, in Somali', (tester) async {
      AppLanguage.current.value = AppLanguage.somali;
      await _phone(tester);
      final api = ScriptedApi(lists: [
        [_order('a1', 'pending'), _order('a3', 'completed'), _order('a4', 'failed')]
      ]);
      await tester.pumpWidget(_host(const OrdersListScreen(), api));
      await tester.pumpAndSettle();
      expect(find.text('Lacag-bixintaada waa la hubinayaa…'), findsOneWidget);
      expect(find.text('Waa dhammaaday'), findsOneWidget);
      expect(find.text('Wuu fashilmay'), findsOneWidget);
      expect(find.text('Pending'), findsNothing);
    });

    testWidgets('delayed confirmation: it keeps asking, then turns Completed by itself', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(lists: [
        [_order('d1', 'pending')],
        [_order('d1', 'pending')],
        [_order('d1', 'completed')],
      ]);
      await tester.pumpWidget(_host(const OrdersListScreen(), api));
      await tester.pumpAndSettle();
      expect(find.text(verifying), findsOneWidget);
      expect(find.text('Completed'), findsNothing);

      await _next(tester, OrdersProvider.recheckEvery);
      expect(find.text(verifying), findsOneWidget, reason: 'still waiting: nothing is decided');
      expect(find.text('Failed'), findsNothing);

      await _next(tester, OrdersProvider.recheckEvery);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text(verifying), findsNothing);
      final calls = api.getOrdersCalls;
      await tester.pump(const Duration(seconds: 30));
      expect(api.getOrdersCalls, calls, reason: 'nothing left to check: it stops asking');
      expect(player.plays, 1, reason: 'one cha-ching for the one completion');
    });

    testWidgets('a failed read is not a result: the order stays "being verified", then turns Completed', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(lists: [
        [_order('e1', 'pending')],
        timeout,
        timeout,
        [_order('e1', 'completed')],
      ]);
      await tester.pumpWidget(_host(const OrdersListScreen(), api));
      await tester.pumpAndSettle();
      expect(find.text(verifying), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        await _next(tester, OrdersProvider.recheckEvery);
        expect(find.text(verifying), findsOneWidget, reason: 'read ${i + 2} failed: nothing is decided');
        expect(find.text('Failed'), findsNothing);
        expect(find.text('Pending'), findsNothing);
      }
      await _next(tester, OrdersProvider.recheckEvery);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text(verifying), findsNothing);
    });
  });

  group('after Send Money Now: the result screen', () {
    testWidgets('an immediate payment: already Completed, nothing to ask', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [_order('i1', 'completed')]);
      await tester.pumpWidget(_host(DepositResultScreen(order: _order('i1', 'completed')), api));
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Deposit Confirmed'), findsOneWidget);
      expect(api.getOrderCalls, 0);
      expect(find.text('Pending'), findsNothing);
    });

    testWidgets('a delayed confirmation: "being verified" until the server says Completed, then it stops asking', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [
        _order('c1', 'pending'),
        _order('c1', 'pending'),
        _order('c1', 'completed'),
      ]);
      await tester.pumpWidget(_host(DepositResultScreen(order: _order('c1', 'pending')), api));
      expect(find.text(verifying), findsOneWidget);
      expect(find.text('Pending'), findsNothing);
      expect(find.text('Deposit Confirmed'), findsNothing);

      await _next(tester);
      expect(find.text(verifying), findsOneWidget);
      await _next(tester);
      expect(find.text(verifying), findsOneWidget);
      expect(find.text('Deposit Confirmed'), findsNothing, reason: 'not before the server says so');
      await _next(tester);
      expect(find.text('Deposit Confirmed'), findsOneWidget);
      expect(find.text(verifying), findsNothing);
      expect(api.getOrderCalls, 3);
      await tester.pump(const Duration(seconds: 60));
      expect(api.getOrderCalls, 3, reason: 'completed once: no more asking');
      expect(player.plays, 1, reason: 'one cha-ching, once');
    });

    testWidgets('timeouts and network errors never turn into Failed: it keeps asking, then Completed', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [timeout, timeout, timeout, _order('n1', 'processing'), _order('n1', 'completed')]);
      await tester.pumpWidget(_host(DepositResultScreen(order: _order('n1', 'pending')), api));
      // After each failed try it waits a little longer: 3, 6, 9, then at most 10 seconds.
      var i = 0;
      for (final wait in [3, 6, 9, 10]) {
        await _next(tester, Duration(seconds: wait));
        i++;
        expect(find.text('Failed'), findsNothing, reason: 'try $i');
        expect(find.text(verifying), findsOneWidget, reason: 'try $i');
      }
      await _next(tester); // the answer after a good one: 3 s again
      expect(find.text('Deposit Confirmed'), findsOneWidget);
      expect(api.getOrderCalls, 5);
    });

    testWidgets('a genuine failure from the server shows Failed, with its reason', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [
        _order('f1', 'pending'),
        _order('f1', 'failed', reason: 'Payment not received'),
      ]);
      await tester.pumpWidget(_host(DepositResultScreen(order: _order('f1', 'pending')), api));
      await _next(tester);
      expect(find.text(verifying), findsOneWidget);
      await _next(tester);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Payment not received'), findsOneWidget);
      expect(find.text(verifying), findsNothing);
      expect(player.plays, 0, reason: 'no cha-ching for a failure');
      await tester.pump(const Duration(seconds: 60));
      expect(api.getOrderCalls, 2);
    });

    testWidgets('a deposit that expired is a definitive failure and reads Failed, never Expired', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [_order('x1', 'expired', reason: 'Not paid within 30 minutes')]);
      await tester.pumpWidget(_host(DepositResultScreen(order: _order('x1', 'pending')), api));
      await _next(tester);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Expired'), findsNothing);
    });

    testWidgets('the details of an order update by themselves too', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [_order('s1', 'completed')]);
      await tester.pumpWidget(_host(Scaffold(body: TransactionDetailsSheet(order: _order('s1', 'pending'))), api));
      expect(find.text(verifying), findsOneWidget);
      await _next(tester);
      expect(find.text('Deposit Confirmed'), findsOneWidget);
      expect(find.text(verifying), findsNothing);
    });

    testWidgets('a withdrawal result follows the same way', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [_order('w1', 'completed', direction: 'withdraw')]);
      await tester.pumpWidget(
          _host(WithdrawResultScreen(order: _order('w1', 'processing', direction: 'withdraw')), api));
      expect(find.text(verifying), findsOneWidget);
      await _next(tester);
      expect(find.text('Withdrawal Confirmed'), findsOneWidget);
    });

    testWidgets('a completed order is never taken back by a later answer', (tester) async {
      await _phone(tester);
      final api = ScriptedApi(script: [_order('k1', 'pending')]);
      await tester.pumpWidget(_host(DepositResultScreen(order: _order('k1', 'completed')), api));
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Deposit Confirmed'), findsOneWidget);
      expect(api.getOrderCalls, 0, reason: 'a final order is not asked about again');
    });
  });

  test('which statuses are final: only completed and the definitive failures', () {
    for (final s in ['completed', 'failed', 'cancelled', 'expired']) {
      expect(_order('z', s).isFinal, isTrue, reason: s);
    }
    for (final s in ['pending', 'processing', 'something_new', '']) {
      expect(_order('z', s).isFinal, isFalse, reason: s);
    }
    expect(_order('z', 'completed').isFailedFinal, isFalse);
    expect(_order('z', 'expired').isFailedFinal, isTrue);
  });
}
