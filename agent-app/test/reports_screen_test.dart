import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/report_overview.dart';
import 'package:badal_agent_app/screens/reports_screen.dart';
import 'package:badal_agent_app/state/history_filter.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _report(String range) => {
      'range': range,
      'from': range == 'all_time' ? null : '2026-10-28',
      'to': '2026-10-28',
      'overview': {
        'revenue': '5216.80', 'transactions': 4, 'fees': '5.00',
        'deposits': {'count': 3, 'total': '5206.80'}, 'withdrawals': {'count': 1, 'total': '10.00'},
      },
      'platforms': [
        {'method': 'betwinner', 'label': 'BET WINNER', 'count': 1, 'total': '5176.80'},
        {'method': 'melbet', 'label': 'MELBET', 'count': 2, 'total': '30.00'},
      ],
      'methods': [
        {'method': 'evc_plus', 'label': 'EVC Plus', 'count': 1, 'total': '10.00'},
      ],
      'users': [
        {'customerId': 'u1', 'name': 'Yaasiin maxamed adan', 'phone': '252610346060', 'count': 3, 'total': '5206.80'},
        {'customerId': 'u2', 'name': 'Baari Sarifle', 'phone': '252610625955', 'count': 1, 'total': '10.00'},
      ],
      'usersCount': 2,
      'transactions': [
        {'orderCode': 'EXBIG1', 'method': 'betwinner', 'label': 'BET WINNER', 'direction': 'deposit', 'amount': '5176.80',
         'customerName': 'Yaasiin maxamed adan', 'completedAt': '2026-10-28T18:00:00Z'},
      ],
      'statuses': {'completed': {'count': 4, 'total': '5216.80'}, 'failed': {'count': 2, 'total': '99.00'}},
      'series': range == 'all_time' ? null : [{'date': '2026-10-28', 'deposits': 3, 'withdrawals': 1, 'orders': 6}],
    };

class _FakeApi extends AgentApi {
  final ranges = <String>[];
  bool empty = false;
  bool fail = false;

  @override
  Future<ReportOverview> getReportOverview({required String range, String? from, String? to}) async {
    ranges.add(range);
    if (fail) throw const ApiException(statusCode: 500, code: 'ERR', message: 'Server unavailable');
    if (empty) {
      return ReportOverview.fromJson({'range': range, 'from': '2026-10-27', 'to': '2026-10-27', 'overview': {}, 'statuses': {}});
    }
    return ReportOverview.fromJson(_report(range));
  }
}

Future<_FakeApi> _pump(WidgetTester tester, {Size size = const Size(393, 851), _FakeApi? api, List<HistoryFilter>? opened}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size * 2.75;
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final fake = api ?? _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => Session(api: fake),
    child: MaterialApp(home: Scaffold(body: ReportsScreen(onOpenHistory: (f) => opened?.add(f)))),
  ));
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  test('money: thousands separators and two decimals', () {
    expect(usd('5176.80'), '\$5,176.80');
    expect(usd('500009.5'), '\$500,009.50');
    expect(usd('0.00'), '\$0.00');
    expect(usd('1234567.891'), '\$1,234,567.89');
    expect(usd('-12.5'), '-\$12.50');
  });

  testWidgets('today by default; overview, rankings and largest transactions from the report', (tester) async {
    final api = await _pump(tester);
    expect(api.ranges, ['today']);
    expect(find.text('\$5,216.80'), findsOneWidget, reason: 'revenue');
    expect(find.text('4'), findsWidgets);
    expect(find.text('Top Platforms'), findsOneWidget);
    final first = tester.getTopLeft(find.byKey(const Key('platform-betwinner'))).dy;
    final second = tester.getTopLeft(find.byKey(const Key('platform-melbet'))).dy;
    expect(first, lessThan(second), reason: 'ranked by amount');
    expect(find.text('#2'), findsWidgets);
    expect(find.text('1 transactions'), findsWidgets);
    await tester.scrollUntilVisible(find.byKey(const Key('user-u1')), 200);
    expect(find.text('+252610346060'), findsOneWidget);
    expect(find.text('3 txns'), findsOneWidget);
    expect(find.byIcon(Icons.emoji_events_rounded), findsOneWidget, reason: 'the top user');
    await tester.scrollUntilVisible(find.byKey(const Key('tx-EXBIG1')), 200);
    expect(find.text('\$5,176.80'), findsWidgets);
  });

  testWidgets('each filter reloads every section; All Time has no per-day chart', (tester) async {
    final api = await _pump(tester);
    for (final (key, range) in const [
      ('range-yesterday', 'yesterday'),
      ('range-last_month', 'last_month'),
      ('range-all_time', 'all_time'),
      ('range-today', 'today'),
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(api.ranges.last, range);
    }
    await tester.tap(find.byKey(const Key('range-all_time')));
    await tester.pumpAndSettle();
    expect(find.textContaining('All time'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Not in the revenue'), 300);
    expect(find.text('Transactions per Day'), findsNothing);
  });

  testWidgets('a small phone: no overflow; empty and error states', (tester) async {
    final api = _FakeApi();
    await _pump(tester, size: const Size(320, 568), api: api);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Not in the revenue'), 300);
    expect(tester.takeException(), isNull);

    api.empty = true;
    await tester.scrollUntilVisible(find.byKey(const Key('range-yesterday')), -300);
    await tester.tap(find.byKey(const Key('range-yesterday')));
    await tester.pumpAndSettle();
    expect(find.text('\$0.00'), findsWidgets);
    await tester.scrollUntilVisible(find.text('No completed platform transactions in this period.'), 200);

    final failing = _FakeApi()..fail = true;
    await _pump(tester, api: failing);
    expect(find.text('Server unavailable'), findsOneWidget);
  });

  testWidgets('a report type opens History for the same dates', (tester) async {
    final opened = <HistoryFilter>[];
    await _pump(tester, opened: opened);
    await tester.scrollUntilVisible(find.text('Failed'), 300);
    await tester.tap(find.text('Failed'));
    expect(opened.single.status, 'failed');
    expect(opened.single.from, '2026-10-28');
    expect(opened.single.to, '2026-10-28');
  });
}
