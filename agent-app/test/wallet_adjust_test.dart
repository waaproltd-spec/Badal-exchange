import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/l10n/wallet_strings.dart';
import 'package:badal_agent_app/models/wallet_adjustment.dart';
import 'package:badal_agent_app/screens/wallet/wallet_adjust_screen.dart';
import 'package:badal_agent_app/screens/wallet/wallet_history_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

WalletAdjustment _adj(String ref, bool add, String amount, String before, String after,
        {String reason = 'Correction'}) =>
    WalletAdjustment(
      id: ref,
      reference: ref,
      customerId: 'c1',
      customerName: 'Yaasin maxamed adan',
      customerPhone: '252610346060',
      direction: add ? 'add' : 'deduct',
      amount: amount,
      balanceBefore: before,
      balanceAfter: after,
      reason: reason,
      agentId: 'a1',
      agentName: 'Demo Agent',
      status: 'completed',
      createdAt: DateTime(2026, 10, 21, 20, 15),
    );

/// Records adjustments; [failWith] makes the next one fail.
class _FakeApi extends AgentApi {
  final calls = <Map<String, Object>>[];
  Object? failWith;
  List<WalletAdjustment> history = [
    _adj('WAL123456', true, '5.00', '1.00', '6.00', reason: 'Ku shubid macmiilka'),
    _adj('WAL123455', false, '2.00', '6.00', '4.00', reason: 'Ka jarid macmiilka'),
  ];
  final historyCalls = <String?>[];

  @override
  Future<WalletAdjustment> adjustWallet({
    required String customerId,
    required bool add,
    required String amount,
    required String reason,
    required String idempotencyKey,
  }) async {
    calls.add({'customer': customerId, 'add': add, 'amount': amount, 'reason': reason, 'key': idempotencyKey});
    final error = failWith;
    if (error != null) {
      failWith = null;
      throw error;
    }
    return _adj('WALNEW001', add, amount, '1.00', add ? '6.00' : '0.00', reason: reason);
  }

  @override
  Future<List<WalletAdjustment>> getWalletAdjustments({String? customerId, String? direction}) async {
    historyCalls.add(direction);
    return history.where((a) => direction == null || a.direction == direction).toList();
  }
}

late _FakeApi _api;

Widget _app(Widget screen) {
  _api = _FakeApi();
  final api = _api;
  return ChangeNotifierProvider(
    key: UniqueKey(), // a fresh session for each pumped app
    create: (_) => Session(api: api),
    child: MaterialApp(home: screen),
  );
}

/// The screen opened from a page under it, as Customer Info does; that page
/// shows what the screen returned.
Widget _hosted(Widget screen) => _app(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              final result = await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
              if (result is WalletAdjustment && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('returned ${result.reference}')));
              }
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

Future<void> _open(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(_hosted(screen));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

WalletAdjustScreen _screen({bool add = true, String balance = '1.00'}) => WalletAdjustScreen(
    customerId: 'c1', name: 'Yaasin maxamed adan', phone: '252610346060', balance: balance, add: add);

Future<void> _phone(WidgetTester tester, [Size size = const Size(393, 851)]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _tapSubmit(WidgetTester tester) async {
  final button = find.byKey(const Key('adjust-submit'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => WalletStrings.somaliOverride = false);

  testWidgets('add money: quick amount, current and new balance, confirm, result', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(_screen()));
    expect(find.text('Add Money'), findsWidgets);
    expect(find.byKey(const Key('adjust-balance')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('adjust-submit'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('quick-5')));
    await tester.enterText(find.byKey(const Key('adjust-reason')), 'Ku shubid macmiilka');
    await tester.pump();
    expect(find.text('+ \$5.00'), findsOneWidget);
    expect(find.text('\$6.00'), findsOneWidget); // new balance

    await _tapSubmit(tester);
    expect(find.text('Add \$5.00 to Yaasin maxamed adan\'s wallet?'), findsOneWidget);
    expect(_api.calls, isEmpty, reason: 'nothing happens before confirming');
    await tester.tap(find.byKey(const Key('confirm-adjust')));
    await tester.pumpAndSettle();
    expect(_api.calls.single, containsPair('add', true));
    expect(_api.calls.single, containsPair('amount', '5.00'));
    expect(_api.calls.single, containsPair('reason', 'Ku shubid macmiilka'));
    expect(find.byKey(const Key('adjust-result')), findsOneWidget);
    expect(find.text('WALNEW001'), findsOneWidget);
  });

  testWidgets('deduct money: more than the balance is blocked before sending', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(_screen(add: false, balance: '6.00')));
    await tester.enterText(find.byKey(const Key('adjust-amount')), '6.01');
    await tester.enterText(find.byKey(const Key('adjust-reason')), 'Ka jarid macmiilka');
    await tester.pump();
    expect(find.text('More than the customer\'s balance'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('adjust-submit'))).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('adjust-amount')), '2');
    await tester.pump();
    expect(find.text('- \$2.00'), findsOneWidget);
    expect(find.text('\$4.00'), findsOneWidget);
    await _tapSubmit(tester);
    expect(find.text('Deduct \$2.00 from Yaasin maxamed adan\'s wallet?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_api.calls, isEmpty, reason: 'cancelled');
  });

  testWidgets('a failed request shows the server message; the retry reuses its key, an edit starts a new one',
      (tester) async {
    await _phone(tester);
    await _open(tester, _screen(add: false, balance: '6.00'));
    await tester.enterText(find.byKey(const Key('adjust-amount')), '3');
    await tester.enterText(find.byKey(const Key('adjust-reason')), 'Dispute 77');
    await tester.pump();
    _api.failWith = const ApiException(statusCode: 0, code: 'NETWORK_ERROR', message: 'No connection. Try again.');
    await _tapSubmit(tester);
    await tester.tap(find.byKey(const Key('confirm-adjust')));
    await tester.pumpAndSettle();
    expect(find.text('No connection. Try again.'), findsOneWidget);

    await _tapSubmit(tester);
    await tester.tap(find.byKey(const Key('confirm-adjust')));
    await tester.pumpAndSettle();
    expect(_api.calls, hasLength(2));
    expect(_api.calls[1]['key'], _api.calls[0]['key'], reason: 'same request, applied once by the server');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('returned WALNEW001'), findsOneWidget, reason: 'the screen closes with the result');

    // A new screen for another adjustment edits the amount: a new key.
    await tester.pumpWidget(_app(_screen(add: false, balance: '6.00')));
    await tester.enterText(find.byKey(const Key('adjust-amount')), '3');
    await tester.enterText(find.byKey(const Key('adjust-reason')), 'Dispute 77');
    await tester.pump();
    _api.failWith = const ApiException(
        statusCode: 400, code: 'INSUFFICIENT_BALANCE', message: 'The customer\'s available balance is \$2.00');
    await _tapSubmit(tester);
    await tester.tap(find.byKey(const Key('confirm-adjust')));
    await tester.pumpAndSettle();
    expect(find.text('The customer\'s available balance is \$2.00'), findsOneWidget);
    final first = _api.calls.last['key'];
    await tester.enterText(find.byKey(const Key('adjust-amount')), '2');
    await tester.pump();
    await _tapSubmit(tester);
    await tester.tap(find.byKey(const Key('confirm-adjust')));
    await tester.pumpAndSettle();
    expect(_api.calls.last['key'], isNot(first));
  });

  testWidgets('history: list, filters, details', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(const WalletHistoryScreen(
        customerId: 'c1', name: 'Yaasin maxamed adan', phone: '252610346060', balance: '4.00')));
    await tester.pumpAndSettle();
    expect(find.text('Wallet History'), findsOneWidget);
    expect(find.text('Tx: WAL123456'), findsOneWidget);
    expect(find.text('Tx: WAL123455'), findsOneWidget);
    expect(find.text('+\$5.00'), findsOneWidget);
    expect(find.text('-\$2.00'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Deduct Money'));
    await tester.pumpAndSettle();
    expect(_api.historyCalls.last, 'deduct');
    expect(find.text('Tx: WAL123456'), findsNothing);
    expect(find.text('Tx: WAL123455'), findsOneWidget);

    await tester.tap(find.byKey(const Key('adjustment-WAL123455')));
    await tester.pumpAndSettle();
    expect(find.text('Ka jarid macmiilka'), findsWidgets);
    expect(find.text('Demo Agent'), findsOneWidget);
    expect(find.text('\$6.00'), findsOneWidget); // balance before
  });

  for (final somali in [false, true]) {
    testWidgets('${somali ? 'Somali' : 'English'} on a 320x568 phone: fits', (tester) async {
      WalletStrings.somaliOverride = somali;
      await _phone(tester, const Size(320, 568));
      await tester.pumpWidget(_app(_screen()));
      await tester.tap(find.byKey(const Key('quick-100')));
      await tester.enterText(find.byKey(const Key('adjust-reason')), 'x' * 120);
      await tester.pump();
      expect(find.text(somali ? 'Lacag Ku Shub' : 'Add Money'), findsWidgets);
      await tester.ensureVisible(find.byKey(const Key('adjust-submit')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_app(const WalletHistoryScreen()));
      await tester.pumpAndSettle();
      expect(find.text(somali ? 'Isbeddelada Wallet-ka' : 'Wallet Adjustments'), findsOneWidget);
      expect(find.text('Yaasin maxamed adan · 252610346060'), findsNWidgets(2)); // all customers: who it was
      expect(tester.takeException(), isNull);
    });
  }
}
