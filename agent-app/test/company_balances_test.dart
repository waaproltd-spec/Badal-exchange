import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/agent_profile.dart';
import 'package:badal_agent_app/models/company_balance.dart';
import 'package:badal_agent_app/screens/company/company_balances_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _period({String sent = '0.00', int sentCount = 0}) =>
    {'received': '120.00', 'receivedCount': 3, 'sent': sent, 'sentCount': sentCount, 'open': 1, 'failed': 2};

Map<String, dynamic> _company(String method, String label, String status,
        {String? balance, bool connected = true, int waiting = 0, String? topUp, String? error}) =>
    {
      'method': method,
      'label': label,
      'connected': connected,
      'source': connected ? 'CashdeskBot' : null,
      'status': status,
      'balance': balance,
      'limit': null,
      'lastSuccessAt': balance == null ? null : '2026-10-21T20:30:00Z',
      'lastCheckedAt': connected ? '2026-10-21T20:30:00Z' : null,
      'lastError': error,
      'lowThreshold': '50.00',
      'waitingWithdrawals': waiting,
      'waitingAmount': waiting > 0 ? '25.00' : '0.00',
      'topUpNeeded': topUp,
      'openWithdrawals': waiting,
      'openWithdrawalAmount': waiting > 0 ? '25.00' : '0.00',
      'period': _period(),
    };

Map<String, dynamic> _overview() => {
      'companies': [
        _company('onexbet', '1XBET', 'available', balance: '850.00'),
        _company('888starz', '888STARZ', 'low', balance: '10.29', waiting: 1, topUp: '14.71'),
        _company('melbet', 'MELBET', 'not_connected', connected: false),
        _company('dbbet', 'DBbet', 'not_connected', connected: false),
      ],
      'total': '860.29',
      'totalCompanies': 2,
      'openWithdrawalAmount': '25.00',
      'lowCount': 1,
      'unavailableCount': 0,
      'notConnectedCount': 2,
      'generatedAt': '2026-10-21T20:30:05Z',
    };

class _FakeApi extends AgentApi {
  Map<String, dynamic> overview = _overview();
  final calls = <String>[];
  Object? failNext;

  @override
  Future<CompanyBalancesOverview> getCompanyBalances({bool refresh = false, DateTime? from, DateTime? to}) async {
    calls.add(refresh ? 'refresh' : 'load');
    final e = failNext;
    if (e != null) {
      failNext = null;
      throw e;
    }
    return CompanyBalancesOverview.fromJson(overview);
  }

  @override
  Future<CompanyDetail> getCompanyDetail(String method, {DateTime? from, DateTime? to, String? status}) async {
    calls.add('detail $method ${status ?? 'all'} ${DateTime.now().difference(from!).inDays}');
    final c = (overview['companies'] as List).cast<Map<String, dynamic>>().firstWhere((x) => x['method'] == method);
    return CompanyDetail.fromJson({
      ...c,
      'checks': [
        {'ok': true, 'balance': '10.29', 'error': null, 'checkedAt': '2026-10-21T20:30:00Z'},
        {'ok': false, 'balance': null, 'error': 'CashdeskBot request failed with HTTP 500', 'checkedAt': '2026-10-21T20:25:00Z'},
      ],
      'orders': [
        if (status == null || status == 'open')
          {
            'id': 'o1', 'orderCode': 'EXDL7XXK', 'direction': 'withdraw', 'status': 'processing', 'amount': '25.00',
            'accountId': '1847412855', 'customerName': 'Yaasin', 'note': 'Waiting', 'waitingTopUp': true,
            'createdAt': '2026-10-21T19:50:00Z',
          },
        if (status == null || status == 'failed')
          {
            'id': 'o2', 'orderCode': 'EXFAIL01', 'direction': 'deposit', 'status': 'failed', 'amount': null,
            'accountId': '7841228', 'customerName': 'Yaasin', 'note': 'Code already used', 'waitingTopUp': false,
            'createdAt': '2026-10-21T20:03:00Z',
          },
      ],
    });
  }
}

late _FakeApi _api;

Widget _app({Duration autoRefresh = const Duration(minutes: 1), Object? failFirst}) {
  _api = _FakeApi()..failNext = failFirst;
  final api = _api;
  return ChangeNotifierProvider(
    key: UniqueKey(),
    create: (_) => Session(api: api),
    child: MaterialApp(home: CompanyBalancesScreen(autoRefresh: autoRefresh)),
  );
}

Future<void> _phone(WidgetTester tester, [Size size = const Size(393, 851)]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

String _text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('verified total, each company with its status; low shows what to top up', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(_text(tester, 'total-amount'), '\$860.29');
    expect(_text(tester, 'total-note'), 'Verified balances of 2 companies');
    expect(_text(tester, 'company-amount-onexbet'), '\$850.00');
    expect(find.byKey(const Key('company-status-available')), findsOneWidget);
    expect(_text(tester, 'company-amount-888starz'), '\$10.29');
    expect(find.byKey(const Key('company-status-low')), findsOneWidget);
    expect(_text(tester, 'company-warning-888starz'), '1 withdrawal (\$25.00) waiting for a top-up. Top up at least \$14.71.');
    // No balance connection: no amount at all.
    await tester.scrollUntilVisible(find.byKey(const Key('company-dbbet')), 100, scrollable: find.byType(Scrollable).first);
    expect(_text(tester, 'company-amount-melbet'), '—');
    expect(find.text('No balance connection · orders handled by agents'), findsNWidgets(2));
    expect(_api.calls, ['load']);
  });

  testWidgets('offline and stale: no zero, last known labelled; left out of the total', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    _api.overview = _overview()
      ..['companies'] = [
        _company('onexbet', '1XBET', 'offline', error: 'CashdeskBot request failed with HTTP 500'),
        _company('888starz', '888STARZ', 'stale', balance: '10.29'),
      ]
      ..['total'] = '0.00'
      ..['totalCompanies'] = 0
      ..['unavailableCount'] = 2;
    await tester.tap(find.byKey(const Key('refresh-balances')));
    await tester.pumpAndSettle();
    expect(_text(tester, 'company-amount-onexbet'), 'Unavailable');
    expect(_text(tester, 'company-warning-onexbet'), 'Could not read the balance: CashdeskBot request failed with HTTP 500');
    expect(find.byKey(const Key('company-status-stale')), findsOneWidget);
    expect(find.textContaining('not updated since'), findsOneWidget);
    expect(_text(tester, 'total-note'), 'Verified balances of 0 companies · 2 not included (offline or not updated)');
    expect(_api.calls, ['load', 'refresh']);
  });

  testWidgets('refreshes on its own while open; a failed refresh keeps the last data', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(autoRefresh: const Duration(seconds: 30)));
    await tester.pumpAndSettle();
    _api.failNext = const ApiException(statusCode: 0, code: 'NETWORK_ERROR', message: 'No connection.');
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(_api.calls, ['load', 'load']);
    expect(_text(tester, 'total-amount'), '\$860.29');
    await tester.scrollUntilVisible(find.byKey(const Key('balances-error')), -100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Could not refresh: No connection.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('balances-error')), findsNothing);
  });

  testWidgets('not allowed: the server\'s refusal is shown, nothing else', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(
        failFirst: const ApiException(
            statusCode: 403, code: 'FORBIDDEN', message: 'You are not allowed to see company balances')));
    await tester.pumpAndSettle();
    expect(find.text('You are not allowed to see company balances'), findsOneWidget);
    expect(find.byKey(const Key('total-amount')), findsNothing);
  });

  testWidgets('company details: balance, checks, period and transaction filters', (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('company-888starz')));
    await tester.pumpAndSettle();
    expect(_text(tester, 'detail-balance'), '\$10.29');
    expect(find.byKey(const Key('detail-warning')), findsOneWidget);
    expect(find.text('Received · 3 deposits'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('company-order-EXDL7XXK')), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Waiting for a cash register top-up'), findsOneWidget);
    expect(_api.calls.last, 'detail 888starz all 0');

    await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, '7 days'), -100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(ChoiceChip, '7 days'));
    await tester.pumpAndSettle();
    expect(_api.calls.last, startsWith('detail 888starz all '));
    expect(int.parse(_api.calls.last.split(' ').last), 6);

    await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, 'Failed'), 100, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Failed'));
    await tester.pumpAndSettle();
    expect(_api.calls.last, startsWith('detail 888starz failed'));
    expect(find.byKey(const Key('company-order-EXDL7XXK')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('company-order-EXFAIL01')), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Amount pending'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Balance checks'), 100, scrollable: find.byType(Scrollable).first);
    expect(find.text('Failed: CashdeskBot request failed with HTTP 500'), findsOneWidget);
  });

  testWidgets('a 320x568 phone: the list and details fit', (tester) async {
    await _phone(tester, const Size(320, 568));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('company-888starz')), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('company-888starz')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('who sees Company Balances in the app: managers and view_company_balances', () {
    AgentProfile profile(List<String> r) =>
        AgentProfile(id: 'a', name: 'A', phone: '1', status: 'active', responsibilities: r);
    final s = Session(api: _FakeApi());
    expect(s.canViewCompanyBalances, isFalse);
    s.profile = profile(['evc_withdraw']);
    expect(s.canViewCompanyBalances, isFalse);
    s.profile = profile(['view_company_balances']);
    expect(s.canViewCompanyBalances, isTrue);
    s.profile = profile(['manage_settings']);
    expect(s.canViewCompanyBalances, isTrue);
  });
}
