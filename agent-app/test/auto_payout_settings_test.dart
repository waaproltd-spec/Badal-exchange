import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/payout.dart';
import 'package:badal_agent_app/screens/admin/payout_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

AutoPayoutSettings _evc({String mode = 'off', bool testPassed = false, String? balance, int waiting = 0, String? held}) =>
    AutoPayoutSettings(
      method: 'evc_plus',
      mode: mode,
      dailyLimit: '500.00',
      minBalance: '5.00',
      testAmount: '0.10',
      paidToday: '12.00',
      balance: balance,
      hasWallet: true,
      walletPhone: '617000001',
      testPassed: testPassed,
      testOrderCode: testPassed ? 'EXTEST01' : null,
      waiting: waiting,
      heldReason: held,
    );

class _FakeApi extends AgentApi {
  AutoPayoutSettings evc;
  final calls = <String>[];
  _FakeApi(this.evc);

  @override
  Future<List<PayoutWallet>> getPayoutWallets() async => const [
        PayoutWallet(id: 'w1', method: 'evc_plus', phoneNumber: '617000001', deviceId: 'd1', simSlot: 1, hasPin: true, paysWithdrawals: true),
      ];

  @override
  Future<List<AutoPayoutSettings>> getAutoPayouts() async => [evc];

  @override
  Future<AutoPayoutSettings> setAutoPayout(String method, {String? mode, double? dailyLimit, double? minBalance}) async {
    calls.add('set $method ${mode ?? '-'} ${dailyLimit ?? '-'} ${minBalance ?? '-'}');
    return evc = _evc(mode: mode ?? evc.mode, testPassed: evc.testPassed);
  }

  @override
  Future<AutoPayoutSettings> setPayoutBalance(String method, double balance) async {
    calls.add('balance $method $balance');
    return evc = _evc(mode: evc.mode, balance: balance.toStringAsFixed(2));
  }
}

late _FakeApi _api;

Widget _app(AutoPayoutSettings s) {
  _api = _FakeApi(s);
  final api = _api;
  return ChangeNotifierProvider(
    create: (_) => Session(api: api),
    child: const MaterialApp(home: PayoutSettingsScreen()),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.badalexchange.agent/payout'),
      (call) async => {'accessibilityEnabled': true, 'permissionsGranted': true},
    );
  });

  testWidgets('off: shows the safeguards and why withdrawals wait; Test asks first', (tester) async {
    await tester.pumpWidget(_app(_evc(waiting: 2, held: 'Automatic EVC Plus payouts are switched off')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing is sent automatically. Withdrawals wait to be paid by hand.'), findsOneWidget);
    expect(find.text('\$12.00 of \$500.00'), findsOneWidget);
    expect(find.text('Not known yet'), findsOneWidget);
    expect(find.text('Not passed yet'), findsOneWidget);
    expect(find.text('2 waiting · Automatic EVC Plus payouts are switched off'), findsOneWidget);

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    expect(find.text('Test EVC Plus payouts'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_api.calls, isEmpty, reason: 'nothing changes without confirming');

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start test'));
    await tester.pumpAndSettle();
    expect(_api.calls, ['set evc_plus test - -']);
    expect(find.text('Only a \$0.10 test withdrawal is sent automatically.'), findsOneWidget);
  });

  testWidgets('test passed: going live is confirmed with the limits', (tester) async {
    await tester.pumpWidget(_app(_evc(mode: 'test', testPassed: true, balance: '42.50')));
    await tester.pumpAndSettle();
    expect(find.text('Passed (EXTEST01)'), findsOneWidget);
    expect(find.textContaining('\$42.50'), findsOneWidget);
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    expect(find.textContaining('up to \$500.00 a day, keeping at least \$5.00'), findsOneWidget);
    await tester.tap(find.text('Go live'));
    await tester.pumpAndSettle();
    expect(_api.calls, ['set evc_plus live - -']);
    expect(find.text('Every withdrawal is sent automatically within the limits below.'), findsOneWidget);
  });

  testWidgets('limits and balance are entered in dollars', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_app(_evc(mode: 'live', testPassed: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Limits'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('auto-daily')), '250');
    await tester.enterText(find.byKey(const Key('auto-min')), '10.5');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.calls, ['set evc_plus - 250.0 10.5']);

    await tester.tap(find.text('Enter balance'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('auto-balance')), '80');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.calls.last, 'balance evc_plus 80.0');
    expect(find.textContaining('\$80.00'), findsOneWidget);
  });
}
