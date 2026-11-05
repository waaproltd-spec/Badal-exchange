import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/deposit_board.dart';
import 'package:badal_agent_app/screens/admin/unconfirmed_deposits_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _row(String id, String status, String text, {bool overdue = false, String? order, int wait = 300}) => {
      'id': id, 'orderId': order, 'orderCode': order == null ? null : 'EX$id', 'customerId': 'c$id',
      'customerName': 'Customer $id', 'customerPhone': '25261000000$id', 'method': 'evc_plus', 'amount': '12.50',
      'status': status, 'statusText': text, 'overdue': overdue,
      'startedAt': '2026-10-28T10:00:00Z', 'submittedAt': order == null ? null : '2026-10-28T10:03:00Z',
      'waitingSeconds': wait,
    };

class _FakeApi extends AgentApi {
  DateTime? from;

  @override
  Future<UnconfirmedDeposits> getUnconfirmedDeposits({DateTime? from, DateTime? to}) async {
    this.from = from;
    return UnconfirmedDeposits.fromJson({
      'summary': {'notConfirmed': 1, 'pendingVerification': 1, 'overdue': 1, 'expired': 1},
      'deposits': [
        _row('1', 'not_confirmed', 'Customer has not confirmed the deposit yet.'),
        _row('2', 'pending_verification', 'Pending Admin Verification.', order: 'o2'),
        _row('3', 'pending_verification', 'Pending Admin Verification.', order: 'o3', overdue: true, wait: 50 * 3600),
        _row('4', 'expired', 'Expired unpaid. Nothing was credited.', order: 'o4'),
      ],
    });
  }
}

void main() {
  testWidgets('both statuses apart, with phone, amount, times; overdue marked and kept; filters', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final api = _FakeApi();
    await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => Session(api: api), child: const MaterialApp(home: UnconfirmedDepositsScreen())));
    await tester.pumpAndSettle();

    expect(api.from, isNotNull, reason: 'a period is asked for (the last 7 days)');
    expect(find.text('Customer has not confirmed the deposit yet.'), findsOneWidget);
    expect(find.text('Pending Admin Verification.'), findsNWidgets(2));
    expect(find.text('252610000001'), findsOneWidget);
    expect(find.text('\$12.50'), findsNWidgets(4));
    expect(find.text('Waiting 5 min'), findsNWidgets(3));
    expect(find.byKey(const Key('overdue-3')), findsOneWidget);
    expect(find.text('Waiting 2 days 2 h'), findsOneWidget);
    expect(find.textContaining('Confirmed by customer'), findsNWidgets(3));
    expect(find.textContaining('Nothing was credited'), findsOneWidget, reason: 'expired: still listed');

    await tester.tap(find.text('Not confirmed'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('row-1')), findsOneWidget);
    expect(find.byKey(const Key('row-2')), findsNothing);

    await tester.tap(find.text('Overdue'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('row-3')), findsOneWidget);
    expect(find.byKey(const Key('row-1')), findsNothing);
  });
}
