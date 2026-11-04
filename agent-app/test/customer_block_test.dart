// Block / Unblock customers in the Agent App: the button in the customer's profile, the confirmation
// and the reason, the status, the Blocked tab and the counters following, the history, and a refusal
// (an agent without the permission sees no button; the server enforces it too).
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/models/customer_block.dart';
import 'package:badal_agent_app/screens/customer_info_screen.dart';
import 'package:badal_agent_app/screens/users_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The server in a few lines: one customer who is blocked or not, the history, the counters.
class _Api extends AgentApi {
  _Api({this.manager = true});

  final bool manager;
  bool blocked = false;
  final history = <Map<String, dynamic>>[];
  final calls = <String>[];
  ApiException? failWith;

  Map<String, dynamic> get _customer => {
        'id': 'c1',
        'name': 'Asha Warsame',
        'phone': '252611111111',
        'status': blocked ? 'blocked' : 'active',
        'walletBalance': '12.50',
        'registeredAt': '2026-11-03T10:00:00Z',
      };

  CustomerBlockInfo get _info => CustomerBlockInfo.fromJson({
        'status': blocked ? 'blocked' : 'active',
        'blockedReason': blocked ? history.first['reason'] : null,
        'blockedAt': blocked ? history.first['at'] : null,
        'history': history,
      });

  @override
  Future<List<CustomerSummary>> getCustomers(
      {String? query,
      String status = 'all',
      String sort = 'newest',
      int offset = 0}) async {
    calls.add('list $status');
    final c = CustomerSummary.fromJson(_customer);
    return switch (status) {
      'blocked' => blocked ? [c] : [],
      'active' => blocked ? [] : [c],
      _ => [c],
    };
  }

  @override
  Future<CustomerOverview> getCustomerOverview(
          {required DateTime from, required DateTime to}) async =>
      CustomerOverview.fromJson({
        'total': 24,
        'active': blocked ? 23 : 24,
        'blocked': blocked ? 1 : 0,
        'new': 0,
      });

  @override
  Future<CustomerDetail> getCustomer(String id) async =>
      CustomerDetail.fromJson({
        ..._customer,
        'pendingBalance': '0',
        'totalOrders': 0,
        'totalDeposits': '0',
        'totalWithdrawals': '0',
        'totalTransactions': 0,
        'recentOrders': [],
        'recentTransactions': [],
      });

  @override
  Future<CustomerBlockInfo> getCustomerBlockInfo(String id) async {
    if (!manager)
      throw const ApiException(
          statusCode: 403, code: 'FORBIDDEN', message: 'Forbidden');
    return _info;
  }

  @override
  Future<CustomerBlockInfo> setCustomerBlocked(String id,
      {required bool blocked, String? reason}) async {
    calls.add('${blocked ? 'block' : 'unblock'} ${reason ?? '-'}');
    if (failWith != null) throw failWith!;
    this.blocked = blocked;
    history.insert(0, {
      'action': blocked ? 'blocked' : 'unblocked',
      'reason': reason,
      'by': 'Demo Manager',
      'byRole': 'agent',
      'at': '2026-11-04T15:30:00Z',
    });
    return _info;
  }
}

Future<_Api> _pump(WidgetTester tester, Widget home,
    {_Api? api, Size size = const Size(393, 2000)}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final a = api ?? _Api();
  await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: a), child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
  return a;
}

const _info = CustomerInfoScreen(customerId: 'c1', name: 'Asha Warsame');

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets(
      'a manager sees Active and a Block Customer button; Cancel changes nothing',
      (tester) async {
    final api = await _pump(tester, _info);
    expect(find.text('Active'), findsWidgets);
    expect(find.byKey(const Key('block-customer')), findsOneWidget);
    expect(find.byKey(const Key('unblock-customer')), findsNothing);
    await tester.tap(find.byKey(const Key('block-customer')));
    await tester.pumpAndSettle();
    expect(find.text('Block Asha Warsame?'), findsOneWidget,
        reason: 'it asks first');
    await tester.tap(find.byKey(const Key('block-cancel')));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.contains('block')), isEmpty);
    expect(find.byKey(const Key('block-notice')), findsNothing);
  });

  testWidgets(
      'blocking needs a reason; then the customer shows as Blocked with the reason and the history',
      (tester) async {
    final api = await _pump(tester, _info);
    await tester.tap(find.byKey(const Key('block-customer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('block-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Write the reason for blocking'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('block')), isEmpty,
        reason: 'nothing is sent without a reason');
    await tester.enterText(
        find.byKey(const Key('block-reason-field')), 'Fraud: stolen account');
    await tester.tap(find.byKey(const Key('block-confirm')));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('block')).toList(),
        ['block Fraud: stolen account']);
    expect(find.byKey(const Key('block-notice')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('block-reason'))).data,
        'Fraud: stolen account');
    expect(find.text('Blocked'), findsWidgets,
        reason: 'the status says Blocked');
    expect(find.byKey(const Key('unblock-customer')), findsOneWidget);
    expect(find.byKey(const Key('block-customer')), findsNothing);
    expect(find.byKey(const Key('block-history-entry-0')), findsOneWidget);
    expect(find.textContaining('By Demo Manager'), findsOneWidget);
  });

  testWidgets(
      'unblocking asks first, the reason is optional, and the history keeps both',
      (tester) async {
    final api = _Api()
      ..blocked = true
      ..history.add({
        'action': 'blocked',
        'reason': 'Fraud',
        'by': 'Demo Manager',
        'byRole': 'agent',
        'at': '2026-11-03T09:00:00Z'
      });
    await _pump(tester, _info, api: api);
    expect(find.byKey(const Key('block-notice')), findsOneWidget);
    await tester.tap(find.byKey(const Key('unblock-customer')));
    await tester.pumpAndSettle();
    expect(find.text('Unblock Asha Warsame?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('block-confirm')));
    await tester.pumpAndSettle();
    expect(
        api.calls.where((c) => c.contains('unblock')).toList(), ['unblock -']);
    expect(find.byKey(const Key('block-notice')), findsNothing);
    expect(find.byKey(const Key('block-customer')), findsOneWidget);
    expect(find.byKey(const Key('block-history-entry-1')), findsOneWidget);
  });

  testWidgets('a refusal from the server is shown and nothing changes',
      (tester) async {
    final api = _Api()
      ..failWith = const ApiException(
          statusCode: 409,
          code: 'ALREADY_BLOCKED',
          message: 'This customer is already blocked');
    await _pump(tester, _info, api: api);
    await tester.tap(find.byKey(const Key('block-customer')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('block-reason-field')), 'Because');
    await tester.tap(find.byKey(const Key('block-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('This customer is already blocked'), findsOneWidget);
    expect(find.byKey(const Key('block-notice')), findsNothing);
  });

  testWidgets(
      'an agent without the permission sees the status but no Block button',
      (tester) async {
    await _pump(tester, _info, api: _Api(manager: false));
    expect(find.text('Active'), findsWidgets);
    expect(find.byKey(const Key('block-customer')), findsNothing);
    expect(find.byKey(const Key('unblock-customer')), findsNothing);
  });

  testWidgets(
      'Users: after blocking, the Blocked tab lists the customer and the counters follow',
      (tester) async {
    // A wider screen: the test font is wider than the real one and would overflow the tile's count row.
    final api = await _pump(tester, const Scaffold(body: UsersScreen()), size: const Size(760, 2000));
    expect(find.text('Blocked (0)'), findsOneWidget);
    expect(find.text('Active (24)'), findsOneWidget);
    await tester.tap(find.text('Asha Warsame'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('block-customer')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('block-reason-field')), 'Fraud');
    await tester.tap(find.byKey(const Key('block-confirm')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Blocked (1)'), findsOneWidget,
        reason: 'the counter follows at once');
    expect(find.text('Active (23)'), findsOneWidget);
    await tester.ensureVisible(find.text('Blocked (1)'));
    await tester.tap(find.text('Blocked (1)'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'list blocked');
    expect(find.text('Asha Warsame'), findsOneWidget);
  });

  testWidgets('Somali, on a small phone', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _pump(tester, _info, size: const Size(320, 1400));
    expect(find.text('Xannibo Macmiilka'), findsOneWidget);
    await tester.tap(find.byKey(const Key('block-customer')));
    await tester.pumpAndSettle();
    expect(find.text('Ma xannibaysaa Asha Warsame?'), findsOneWidget);
    expect(find.text('Sababta xannibaadda'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
