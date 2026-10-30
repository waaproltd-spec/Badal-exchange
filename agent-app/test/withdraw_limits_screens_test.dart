import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/withdraw_limits.dart';
import 'package:badal_agent_app/screens/admin/withdraw_limits_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends AgentApi {
  final calls = <String>[];
  var defaults = const WithdrawLimitDefaults(unverifiedDaily: '50.00', unverifiedMonthly: '500.00', verifiedDaily: '500.00', verifiedMonthly: '5000.00');
  bool custom = false;

  @override
  Future<({WithdrawLimitDefaults defaults, List<LimitCustomer> customers})> getWithdrawLimitCustomers({String? query, String filter = 'all'}) async {
    calls.add('list $filter ${query ?? ''}');
    return (
      defaults: defaults,
      customers: [
        LimitCustomer.fromJson({
          'id': 'c1', 'name': 'Ahmed Ali', 'phone': '252611234567', 'kycStatus': 'not_submitted', 'verified': false,
          'dailyLimit': '50.00', 'dailyUsed': '42.00', 'dailyRemaining': '8.00',
          'monthlyLimit': '500.00', 'monthlyUsed': '120.00', 'monthlyRemaining': '380.00', 'custom': custom, 'warning': 'near_daily',
        }),
      ],
    );
  }

  @override
  Future<WithdrawLimitDefaults> setWithdrawLimitDefaults(
      {required String unverifiedDaily, required String unverifiedMonthly, required String verifiedDaily, required String verifiedMonthly}) async {
    calls.add('defaults $unverifiedDaily/$unverifiedMonthly/$verifiedDaily/$verifiedMonthly');
    return defaults = WithdrawLimitDefaults(
        unverifiedDaily: unverifiedDaily, unverifiedMonthly: unverifiedMonthly, verifiedDaily: verifiedDaily, verifiedMonthly: verifiedMonthly);
  }

  @override
  Future<CustomerWithdrawLimits> getCustomerWithdrawLimits(String customerId) async => CustomerWithdrawLimits.fromJson({
        'customer': {'id': 'c1', 'name': 'Ahmed Ali', 'phone': '252611234567', 'accountId': 'BX00000001'},
        'kyc': {'status': 'not_submitted', 'verified': false},
        'daily': {'limit': custom ? '200.00' : '50.00', 'used': '42.00', 'remaining': custom ? '158.00' : '8.00'},
        'monthly': {'limit': '500.00', 'used': '120.00', 'remaining': '380.00'},
        'custom': {'daily': custom, 'monthly': false, 'note': custom ? 'trusted' : null},
        'defaults': {'unverifiedDaily': '50.00', 'unverifiedMonthly': '500.00', 'verifiedDaily': '500.00', 'verifiedMonthly': '5000.00'},
        'history': [
          {'orderCode': 'EX1', 'method': 'evc_plus', 'amount': '42.00', 'status': 'completed', 'counted': true, 'createdAt': '2026-10-30T10:00:00Z'},
          {'orderCode': 'EX2', 'method': 'evc_plus', 'amount': '9.00', 'status': 'failed', 'counted': false, 'createdAt': '2026-10-30T11:00:00Z'},
        ],
      });

  @override
  Future<void> setCustomerWithdrawLimits(String customerId, {String? daily, String? monthly, String? note}) async {
    calls.add('custom ${daily ?? '-'}/${monthly ?? '-'}/${note ?? '-'}');
    custom = daily != null || monthly != null;
  }
}

Future<_FakeApi> _pump(WidgetTester tester, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 5000);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final api = _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider(create: (_) => Session(api: api), child: MaterialApp(home: home)));
  await tester.pump();
  await tester.pump();
  return api;
}

void main() {
  testWidgets('lists defaults and customers with used and remaining; filters call the server', (tester) async {
    final api = await _pump(tester, const WithdrawLimitsScreen());
    expect(find.textContaining('Not verified: \$50.00 a day · \$500.00 a month'), findsOneWidget);
    expect(find.textContaining('KYC approved: \$500.00 a day · \$5000.00 a month'), findsOneWidget);
    expect(find.text('Today \$42.00 of \$50.00 · left \$8.00'), findsOneWidget);
    expect(find.text('Month \$120.00 of \$500.00 · left \$380.00'), findsOneWidget);
    expect(find.text('Close to the limit'), findsOneWidget);
    await tester.ensureVisible(find.text('Limit reached'));
    await tester.pump();
    await tester.tap(find.text('Limit reached'));
    await tester.pump();
    await tester.pump();
    expect(api.calls.last, 'list reached ');
  });

  testWidgets('the default limits are edited and saved', (tester) async {
    final api = await _pump(tester, const WithdrawLimitsScreen());
    await tester.tap(find.byKey(const Key('limit-defaults')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('unverified-daily')), '40');
    await tester.enterText(find.byKey(const Key('verified-monthly')), '8000');
    await tester.tap(find.byKey(const Key('save-defaults')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('defaults 40/500.00/500.00/8000'));
    expect(find.textContaining('Not verified: \$40 a day'), findsOneWidget);
  });

  testWidgets('a customer: status, remaining, history; own limits set and removed', (tester) async {
    final api = await _pump(tester, const CustomerLimitsScreen(customerId: 'c1'));
    expect(find.text('Ahmed Ali'), findsOneWidget);
    expect(find.text('Today: \$42.00 of \$50.00 · left \$8.00'), findsOneWidget);
    expect(find.textContaining('9.00'), findsOneWidget);
    expect(find.textContaining('not counted'), findsOneWidget);
    expect(find.byKey(const Key('reset-custom')), findsNothing);
    await tester.enterText(find.byKey(const Key('custom-daily')), '200');
    await tester.enterText(find.byKey(const Key('custom-note')), 'trusted');
    await tester.tap(find.byKey(const Key('save-custom')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('custom 200/-/trusted'));
    expect(find.text('Today: \$42.00 of \$200.00 · left \$158.00 (custom)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reset-custom')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'custom -/-/-');
    expect(find.byKey(const Key('reset-custom')), findsNothing);
  });
}
