import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/widgets/customer_bonus_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CustomerBonus _bonus({bool enabled = true, int? custom, bool programmeOn = true}) => CustomerBonus.fromJson({
      'balance': '1.25',
      'rate': !programmeOn || !enabled ? '0%' : '${(custom ?? 100) / 100}%'.replaceAll('.0%', '%'),
      'totalEarned': '3.25',
      'enabled': enabled,
      'customRateBp': custom,
      'defaultRateBp': 100,
      'programmeOn': programmeOn,
      'entries': [
        {'kind': 'moved', 'amount': '2.00', 'createdAt': '2026-10-28T10:00:00Z'},
        {'kind': 'earned', 'amount': '1.00', 'rate': '1%', 'withdrawal': '100.00', 'orderCode': 'EXBONUS1',
         'createdAt': '2026-10-27T10:00:00Z'},
      ],
    });

class _FakeApi extends AgentApi {
  CustomerBonus bonus;
  final bool forbidden;
  final calls = <String>[];
  _FakeApi(this.bonus, {this.forbidden = false});

  @override
  Future<CustomerBonus> getCustomerBonus(String id) async {
    if (forbidden) throw const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Forbidden');
    return bonus;
  }

  @override
  Future<CustomerBonus> setCustomerBonus(String id, {int? rateBp, bool? enabled}) async {
    calls.add('$id ${rateBp ?? '-'} ${enabled ?? '-'}');
    return bonus = _bonus(enabled: enabled ?? bonus.enabled, custom: rateBp ?? bonus.customRateBp);
  }
}

Widget _app(_FakeApi api) => MaterialApp(
      home: Scaffold(body: ListView(children: [CustomerBonusCard(api: api, customerId: 'c1')])),
    );

void main() {
  testWidgets('balance, rate chips, history; a manager sets 2%, then turns it off', (tester) async {
    final api = _FakeApi(_bonus());
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(find.text('\$1.25'), findsOneWidget);
    expect(find.textContaining('Earns 1% of every completed withdrawal'), findsOneWidget);
    expect(find.text('1% of \$100.00 · EXBONUS1'), findsOneWidget);
    expect(find.text('Moved to main wallet'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1%')).selected, isTrue);

    await tester.tap(find.widgetWithText(ChoiceChip, '2%'));
    await tester.pumpAndSettle();
    expect(api.calls, ['c1 200 -']);
    expect(find.textContaining('Earns 2%'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '2%')).selected, isTrue);

    await tester.tap(find.byKey(const Key('bonus-enabled')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'c1 - false');
    expect(find.text('Off for this customer: no bonus on their withdrawals.'), findsOneWidget);
  });

  testWidgets('switched off for everyone: says so', (tester) async {
    await tester.pumpWidget(_app(_FakeApi(_bonus(programmeOn: false))));
    await tester.pumpAndSettle();
    expect(find.text('The bonus is switched off for everyone.'), findsOneWidget);
  });

  testWidgets('an agent who cannot manage settings does not see it', (tester) async {
    await tester.pumpWidget(_app(_FakeApi(_bonus(), forbidden: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('customer-bonus')), findsNothing);
  });
}
