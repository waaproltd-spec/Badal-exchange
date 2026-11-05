import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/screens/admin/bonus_settings_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _methods = [
  ('evc_plus', 'EVC Plus', 'mobile_money'),
  ('telesom', 'ZAAD', 'mobile_money'),
  ('edahab', 'eDahab', 'mobile_money'),
  ('888starz', '888STARZ', 'platform'),
];

BonusSettings _settings({bool enabled = true, int bp = 100, Set<String> eligible = const {'withdraw:edahab', 'withdraw:888starz'}}) =>
    BonusSettings.fromJson({
      'enabled': enabled,
      'defaultRateBp': bp,
      'totalBalance': '1.006',
      'totalEarned': '3.006',
      'totalMoved': '2.00',
      'dailyLimit': '1.50',
      'monthlyLimit': null,
      'types': [
        for (final d in ['deposit', 'withdraw'])
          for (final (m, label, kind) in _methods)
            {'direction': d, 'method': m, 'label': label, 'kind': kind, 'eligible': eligible.contains('$d:$m')},
      ],
      'customers': [
        {'id': 'c1', 'name': 'Yaasiin', 'phone': '252638882065', 'balance': '0.006', 'totalEarned': '0.006', 'rate': '2%'},
      ],
      'history': [
        {'kind': 'earned', 'amount': '0.006', 'rate': '2%', 'createdAt': '2026-10-28T04:42:00Z', 'orderCode': 'EX888',
         'orderAmount': '0.30', 'direction': 'withdraw', 'methodLabel': '888STARZ', 'customerName': 'Yaasiin'},
        {'kind': 'moved', 'amount': '2.00', 'movedToMain': '2.00', 'createdAt': '2026-10-28T04:00:00Z', 'customerName': 'Nuur'},
      ],
    });

class _FakeApi extends AgentApi {
  BonusSettings settings;
  final calls = <String>[];
  _FakeApi(this.settings);

  @override
  Future<BonusSettings> getBonusSettings() async => settings;

  @override
  Future<BonusSettings> setBonusLimits({required String daily, required String monthly}) async {
    calls.add('limits $daily $monthly');
    return settings;
  }

  @override
  Future<BonusSettings> setBonusSettings({bool? enabled, int? defaultRateBp, List<String>? eligible}) async {
    calls.add('${enabled ?? '-'} ${defaultRateBp ?? '-'} ${eligible?.join(',') ?? '-'}');
    return settings = _settings(
      enabled: enabled ?? settings.enabled,
      bp: defaultRateBp ?? settings.defaultRateBp,
      eligible: eligible?.toSet() ?? settings.eligibleKeys.toSet(),
    );
  }
}

Future<_FakeApi> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 7000); // the whole screen, history included
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final api = _FakeApi(_settings());
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => Session(api: api),
    child: const MaterialApp(home: BonusSettingsScreen()),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('on/off, the rate, eligible types, balances and history', (tester) async {
    final api = await _pump(tester);
    expect(tester.widget<Switch>(find.byKey(const Key('bonus-system'))).value, isTrue);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1%')).selected, isTrue);
    expect(find.text('\$1.006'), findsOneWidget);
    // ZAAD withdrawals are off until switched on.
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('bonus-type-withdraw:telesom'))).value, isFalse);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('bonus-type-withdraw:edahab'))).value, isTrue);
    expect(find.text('Yaasiin'), findsNWidgets(2)); // customers and history
    expect(find.text('\$0.006'), findsOneWidget);
    expect(find.text('2% of \$0.30 888STARZ withdrawal · EX888'), findsOneWidget);
    expect(find.text('Transferred to main wallet (\$2.00)'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '2%'));
    await tester.pumpAndSettle();
    expect(api.calls.last, '- 200 -');
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '2%')).selected, isTrue);

    await tester.tap(find.byKey(const Key('bonus-type-withdraw:telesom')));
    await tester.pumpAndSettle();
    expect(api.calls.last, '- - withdraw:888starz,withdraw:edahab,withdraw:telesom');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('bonus-type-withdraw:telesom'))).value, isTrue);

    await tester.tap(find.byKey(const Key('bonus-system')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'false - -');
    expect(find.textContaining('Off: nobody earns a bonus'), findsOneWidget);
  });

  testWidgets('bonus limits: shown, changed in a dialog that checks the amounts', (tester) async {
    final api = await _pump(tester);
    expect(find.text('\$1.50'), findsOneWidget);
    expect(find.text('No limit'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bonus-limits-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bonus-monthly-limit')), 'abc');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount, or leave empty'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('bonus-monthly-limit')), '20');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'limits 1.50 20');
  });
}
