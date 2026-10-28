import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/commission.dart';
import 'package:badal_agent_app/screens/commission_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:badal_agent_app/widgets/console_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _json({required bool manager, String? method}) => {
      'range': 'today', 'from': '2026-10-28', 'to': '2026-10-28', 'method': method,
      'scope': manager ? 'all' : 'agent', 'agentId': manager ? null : 'me', 'canSeeAll': manager,
      'rates': {'depositBp': 200, 'withdrawBp': 500, 'bonusBp': 100},
      'summary': {
        'deposit': {'count': 1, 'total': '1000.00', 'commission': '20.00'},
        'withdrawal': {'count': 1, 'total': '1000.00', 'grossCommission': '50.00', 'commission': '40.00'},
        'grossCommission': '70.00', 'bonus': '10.00', 'commission': '60.00', 'transactions': 2,
      },
      'companies': [
        {'method': 'onexbet', 'label': '1XBET'}, {'method': 'melbet', 'label': 'MELBET'},
        {'method': 'betwinner', 'label': 'BETWINNER'}, {'method': 'winwin', 'label': 'WINWIN'},
      ],
      'agents': manager ? [{'id': 'a1', 'name': 'Agent One', 'phone': '252610000011'}] : null,
      'transactions': [
        {'orderCode': 'EXW1', 'method': 'melbet', 'label': 'MELBET', 'direction': 'withdraw', 'status': 'completed',
         'amount': '1000.00', 'commission': '50.00', 'bonus': '10.00', 'netCommission': '40.00', 'at': '2026-10-28T10:00:00Z'},
        {'orderCode': 'EXD1', 'method': 'melbet', 'label': 'MELBET', 'direction': 'deposit', 'status': 'completed',
         'amount': '0.30', 'commission': '0.006', 'bonus': '0.00', 'netCommission': '0.006', 'at': '2026-10-28T09:00:00Z'},
        {'orderCode': 'EXF1', 'method': 'melbet', 'label': 'MELBET', 'direction': 'deposit', 'status': 'failed',
         'amount': '500.00', 'commission': null, 'bonus': null, 'netCommission': null, 'at': '2026-10-28T08:00:00Z'},
      ],
    };

class _FakeApi extends AgentApi {
  _FakeApi({this.manager = false});
  final bool manager;
  final calls = <String>[];

  @override
  Future<CommissionReport> getCommission({required String range, String? from, String? to, String? method, String? agent}) async {
    calls.add('$range|$method|$agent');
    return CommissionReport.fromJson(_json(manager: manager, method: method));
  }
}

Future<_FakeApi> _pump(WidgetTester tester, _FakeApi api, {Size size = const Size(393, 851)}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size * 2.75;
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: api), child: const MaterialApp(home: Scaffold(body: CommissionScreen()))));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  test('money and rates as shown', () {
    expect(commissionMoney('1000.00'), '\$1,000.00');
    expect(commissionMoney('0.006'), '\$0.006');
    expect(commissionMoney('40'), '\$40.00');
    expect(commissionMoney('12345.5'), '\$12,345.50');
    expect(percent(200), '2%');
    expect(percent(150), '1.5%');
  });

  testWidgets('the four totals, the breakdown and the transactions (only completed ones earn)', (tester) async {
    final api = await _pump(tester, _FakeApi());
    expect(api.calls, ['today|null|null']);
    expect(find.text('Total Deposit'), findsOneWidget);
    expect(find.text('Total Withdrawal'), findsOneWidget);
    expect(find.text('Total Commission'), findsOneWidget);
    expect(find.text('Total Bonus'), findsOneWidget);
    expect(find.text('\$60.00'), findsWidgets);
    expect(find.text('\$10.00'), findsOneWidget);
    expect(find.text('1 · 2% = \$20.00'), findsOneWidget);
    expect(find.text('1 · 5% = \$50.00'), findsOneWidget);
    expect(find.text('- \$10.00'), findsWidgets);
    expect(find.text('Your commission: the orders you handled.'), findsOneWidget, reason: 'an agent: their own');
    expect(find.byKey(const Key('agent-filter')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('tx-EXF1')), 300);
    expect(find.text('\$0.006'), findsWidgets);
    expect(find.text('Not earned'), findsOneWidget);
  });

  testWidgets('date and company filters reload; managers pick an agent', (tester) async {
    final api = await _pump(tester, _FakeApi(manager: true));
    await tester.tap(find.text('Yesterday'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'yesterday|null|null');
    await tester.drag(find.byType(ChoiceChipsRow<String>), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All Time'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|null|null');
    await tester.tap(find.text('MELBET').first);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|melbet|null');
    await tester.tap(find.text('All Companies'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|null|null');

    await tester.tap(find.byKey(const Key('agent-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent One').last);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|null|a1');
  });

  testWidgets('a small phone: no overflow', (tester) async {
    await _pump(tester, _FakeApi(manager: true), size: const Size(320, 568));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('tx-EXF1')), 300);
    expect(tester.takeException(), isNull);
  });
}
