import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/payout.dart';
import 'package:badal_agent_app/screens/admin/payout_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

SahalPayoutSettings _sahal({String mode = 'off', bool testPassed = false}) => SahalPayoutSettings(
      mode: mode,
      dailyLimit: '500.00',
      testAmount: '0.10',
      paidToday: '0.10',
      testPassed: testPassed,
      waiting: 1,
      unclear: 0,
      recent: const [
        SahalPayoutAttempt(orderCode: 'EXGOLIS1', status: 'success', receiver: '905999914', receiverName: 'YAASIIN', amount: '0.10', transferId: '7501066868'),
      ],
    );

class _FakeApi extends AgentApi {
  SahalPayoutSettings sahal;
  final calls = <String>[];
  _FakeApi(this.sahal);

  @override
  Future<List<PayoutWallet>> getPayoutWallets() async => const [];

  @override
  Future<List<AutoPayoutSettings>> getAutoPayouts() async => const [];

  @override
  Future<SahalPayoutSettings> getSahalPayouts() async => sahal;

  @override
  Future<SahalPayoutSettings> setSahalPayouts({String? mode, double? dailyLimit}) async {
    calls.add('sahal ${mode ?? '-'} ${dailyLimit ?? '-'}');
    return sahal = _sahal(mode: mode ?? sahal.mode, testPassed: sahal.testPassed);
  }
}

late _FakeApi _api;

Widget _app(SahalPayoutSettings s) {
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

  testWidgets('Sahal card: off by default, Test is confirmed first, the last transfers show', (tester) async {
    await tester.pumpWidget(_app(_sahal()));
    await tester.pumpAndSettle();
    expect(find.text('Golis, ZAAD & EVC Plus (from Sahal)'), findsOneWidget);
    expect(find.text('Nothing is sent from Sahal automatically.'), findsOneWidget);
    expect(find.textContaining('EXGOLIS1 · \$0.10 → 905999914 (YAASIIN) · sent · 7501066868'), findsOneWidget);
    expect(find.text('Not read yet'), findsOneWidget, reason: 'Sahal balance not read yet');
    expect(find.text('Try again'), findsNothing, reason: 'a sent transfer cannot be sent again');

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();
    expect(find.text('Test Sahal payouts'), findsOneWidget);
    await tester.tap(find.text('Start test'));
    await tester.pumpAndSettle();
    expect(_api.calls, ['sahal test -']);
    expect(find.text('Only a \$0.10 Golis, ZAAD or EVC Plus withdrawal is sent from Sahal.'), findsOneWidget);
  });

  testWidgets('Sahal live is confirmed; the daily limit is entered in dollars', (tester) async {
    await tester.pumpWidget(_app(_sahal(mode: 'test', testPassed: true)));
    await tester.pumpAndSettle();
    expect(find.text('Passed'), findsOneWidget);
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    expect(find.textContaining('up to \$500.00 a day'), findsOneWidget);
    await tester.tap(find.text('Go live'));
    await tester.pumpAndSettle();
    expect(_api.calls, ['sahal live -']);

    // The "Live." message would sit over the button.
    ScaffoldMessenger.of(tester.element(find.text('Limit'))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Limit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Limit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sahal-daily')), '250');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.calls.last, 'sahal - 250.0');
  });
}
