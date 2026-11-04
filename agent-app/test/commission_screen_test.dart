import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/commission.dart';
import 'package:badal_agent_app/screens/commission_screen.dart';
import 'package:badal_agent_app/state/session.dart';
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
      'series': {
        'granularity': 'day', 'from': '2026-10-26', 'to': '2026-10-28',
        'points': [
          {'start': '2026-10-26', 'deposits': 2, 'withdrawals': 1, 'transactions': 3, 'commission': '1.00'},
          {'start': '2026-10-27', 'deposits': 0, 'withdrawals': 0, 'transactions': 0, 'commission': '0.00'},
          {'start': '2026-10-28', 'deposits': 5, 'withdrawals': 3, 'transactions': 8, 'commission': '3.07'},
        ],
      },
      'topCompanies': [
        {'method': 'winwin', 'label': 'WINWIN', 'transactions': 16, 'amount': '900.00', 'commission': '65.50'},
        {'method': 'onexbet', 'label': '1XBET', 'transactions': 12, 'amount': '700.00', 'commission': '48.20'},
        {'method': 'melbet', 'label': 'MELBET', 'transactions': 9, 'amount': '500.00', 'commission': '32.70'},
        {'method': 'betwinner', 'label': 'BETWINNER', 'transactions': 2, 'amount': '50.00', 'commission': '1.10'},
      ],
      'topAgents': manager
          ? [
              {'id': 'a1', 'name': 'sasaamow', 'phone': '252612118292', 'automatic': false, 'transactions': 24, 'amount': '1000.00', 'commission': '121.00'},
              {'id': null, 'name': null, 'phone': null, 'automatic': true, 'transactions': 11, 'amount': '300.00', 'commission': '56.89'},
              {'id': 'a2', 'name': 'Nuur awaadir', 'phone': '252615859634', 'automatic': false, 'transactions': 8, 'amount': '100.00', 'commission': '24.41'},
              {'id': 'a3', 'name': 'Yaasiin', 'phone': '252610346060', 'automatic': false, 'transactions': 1, 'amount': '10.00', 'commission': '0.40'},
            ]
          : [
              {'id': 'me', 'name': 'Me', 'phone': '252610000001', 'automatic': false, 'transactions': 2, 'amount': '2000.00', 'commission': '60.00'},
            ],
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

/// The page's own list (the filter rows scroll sideways too).
final _page = find.byType(Scrollable).first;

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
    expect(find.text('1 deposit'), findsOneWidget);
    expect(find.text('2% = \$20.00'), findsOneWidget);
    expect(find.text('1 withdrawal'), findsOneWidget);
    expect(find.text('5% = \$50.00'), findsOneWidget);
    expect(find.text('Your commission: the orders you handled.'), findsOneWidget, reason: 'an agent: their own');
    expect(find.byKey(const Key('agent-filter')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('commission-breakdown')), 300, scrollable: _page);
    expect(find.text('- \$10.00'), findsWidgets);
    expect(find.text('Net Commission'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('tx-EXF1')), 300, scrollable: _page);
    expect(find.text('\$0.006'), findsWidgets);
    expect(find.text('Not earned'), findsOneWidget);
  });

  testWidgets('date and company filters reload; managers pick an agent', (tester) async {
    final api = await _pump(tester, _FakeApi(manager: true));
    await tester.tap(find.text('Yesterday'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'yesterday|null|null');
    await tester.ensureVisible(find.text('All Time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All Time'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|null|null');
    await tester.ensureVisible(find.text('MELBET').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MELBET').first);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|melbet|null');
    await tester.ensureVisible(find.text('All Companies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All Companies'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|null|null');

    await tester.ensureVisible(find.byKey(const Key('agent-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('agent-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent One').last);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'all_time|null|a1');
  });

  testWidgets('a small phone: no overflow', (tester) async {
    await _pump(tester, _FakeApi(manager: true), size: const Size(320, 568));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('tx-EXF1')), 300, scrollable: _page);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the date filters: Today, Yesterday, This Month, Last Month, Last 3 Months, All Time, and a custom range', (tester) async {
    final api = await _pump(tester, _FakeApi());
    for (final id in ['today', 'yesterday', 'this_month', 'last_month', 'last_3_months', 'all_time']) {
      expect(find.byKey(Key('range-$id')), findsOneWidget, reason: id);
    }
    expect(find.byKey(const Key('range-custom')), findsOneWidget);
    String rangeText() => tester.widget<Text>(find.byKey(const Key('range-label'))).textSpan!.toPlainText();
    expect(rangeText(), contains('Oct 28, 2026'), reason: 'the range the server used is shown');
    for (final (id, label) in [('last_month', 'Last Month'), ('this_month', 'This Month'), ('last_3_months', 'Last 3 Months')]) {
      await tester.ensureVisible(find.byKey(Key('range-$id')));
      await tester.tap(find.byKey(Key('range-$id')));
      await tester.pumpAndSettle();
      expect(api.calls.last, '$id|null|null');
      expect(rangeText(), contains('($label)'));
    }
  });

  testWidgets('the trend chart draws the server\'s points; an empty period says so', (tester) async {
    await _pump(tester, _FakeApi(), size: const Size(393, 1400));
    await tester.scrollUntilVisible(find.byKey(const Key('commission-trend')), 300, scrollable: _page);
    expect(find.byKey(const Key('trend-chart')), findsOneWidget);
    expect(find.text('Deposits'), findsWidgets);
    expect(find.text('Withdrawals'), findsWidgets);
    expect(find.text('per day'), findsOneWidget);
  });

  testWidgets('Top Companies and Top Agents: ranked, with transactions and net commission; View All shows the whole list', (tester) async {
    await _pump(tester, _FakeApi(manager: true), size: const Size(393, 1600));
    await tester.scrollUntilVisible(find.byKey(const Key('top-companies')), 300, scrollable: _page);
    expect(find.text('Top Companies'), findsOneWidget);
    expect(find.text('Ranked by net commission'), findsWidgets);
    expect(find.byKey(const Key('rank-company-winwin')), findsOneWidget);
    expect(find.text('16 txns'), findsOneWidget);
    expect(find.text('\$65.50'), findsOneWidget);
    expect(find.byKey(const Key('rank-company-betwinner')), findsNothing, reason: 'the first three; the rest under View All');
    await tester.ensureVisible(find.byKey(const Key('companies-view-all')));
    await tester.tap(find.byKey(const Key('companies-view-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ranking-list')), findsOneWidget);
    expect(find.byKey(const Key('rank-company-betwinner')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const Key('top-agents')), 300, scrollable: _page);
    expect(find.text('sasaamow'), findsOneWidget);
    expect(find.text('252612118292'), findsOneWidget, reason: 'a manager sees the number');
    expect(find.text('\$121.00'), findsOneWidget);
    expect(find.text('Automatic (no agent)'), findsOneWidget);
    expect(find.byIcon(Icons.emoji_events_rounded), findsOneWidget, reason: 'the trophy for #1');
    expect(find.byKey(const Key('rank-agent-a3')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('agents-view-all')));
    await tester.tap(find.byKey(const Key('agents-view-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rank-agent-a3')), findsOneWidget);
  });

  testWidgets('an agent sees their own commission in the ranking and no other agents', (tester) async {
    await _pump(tester, _FakeApi(), size: const Size(393, 1600));
    await tester.scrollUntilVisible(find.byKey(const Key('top-agents')), 300, scrollable: _page);
    expect(find.byKey(const Key('rank-agent-me')), findsOneWidget);
    expect(find.byKey(const Key('agents-view-all')), findsNothing);
  });

  testWidgets('a larger system font: no overflow in the new cards', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(393, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => Session(api: _FakeApi(manager: true)),
        child: MaterialApp(
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
          home: const Scaffold(body: CommissionScreen()),
        )));
    await tester.pumpAndSettle();
    // The test font is wider than the phone's and overflows older widgets; the new ones must not be among them.
    final problem = tester.takeException()?.toString() ?? '';
    expect(problem.contains('commission_screen.dart'), isFalse, reason: problem);
    await tester.scrollUntilVisible(find.byKey(const Key('top-agents')), 300, scrollable: _page);
    final later = tester.takeException()?.toString() ?? '';
    expect(later.contains('commission_screen.dart'), isFalse, reason: later);
  });
}
