import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/withdrawal_verification.dart';
import 'package:badal_agent_app/screens/admin/withdrawal_verification_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends AgentApi {
  String status = 'pending';
  String? reason;
  final calls = <String>[];

  @override
  Future<({List<WithdrawalVerification> requests, Map<String, int> counts, String? whatsapp})> getWithdrawalVerifications(
      {String status = 'pending'}) async {
    calls.add('list $status');
    final row = WithdrawalVerification.fromJson({
      'customerId': 'c1', 'accountId': 'BX12AB34CD', 'name': 'Yaasiin', 'phone': '252610346060',
      'status': this.status, 'requestedAt': '2026-10-28T18:00:00Z', 'reason': reason,
      'decidedAt': this.status == 'pending' ? null : '2026-10-28T18:05:00Z', 'decidedBy': this.status == 'pending' ? null : 'Demo Agent',
      'balance': '86.90', 'deposits': {'count': 4, 'total': '172.00'}, 'withdrawals': {'count': 0, 'total': '0.00'},
      'recent': [{'orderCode': 'EXTN7X83', 'direction': 'deposit', 'method': 'evc_plus', 'amount': '28.00', 'status': 'completed'}],
    });
    return (requests: [row], counts: {'pending': this.status == 'pending' ? 1 : 0}, whatsapp: '+252612345678');
  }

  @override
  Future<void> decideWithdrawalVerification(String customerId, String decision, {String? reason}) async {
    calls.add('$decision $customerId $reason');
    status = {'approve': 'approved', 'reject': 'rejected', 'restrict': 'restricted'}[decision]!;
    this.reason = reason;
  }
}

Future<_FakeApi> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final api = _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: api), child: const MaterialApp(home: WithdrawalVerificationScreen())));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('a pending account: ID, number, balance and history; approve', (tester) async {
    final api = await _pump(tester);
    expect(api.calls.first, 'list pending');
    expect(find.textContaining('BX12AB34CD'), findsWidgets);
    expect(find.textContaining('+252610346060'), findsOneWidget);
    expect(find.text('\$86.90'), findsOneWidget);
    expect(find.text('4 · \$172.00'), findsOneWidget);
    expect(find.textContaining('EXTN7X83'), findsOneWidget);
    await tester.tap(find.byKey(const Key('approve-c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await tester.pumpAndSettle();
    expect(api.calls, contains('approve c1 null'));
    expect(find.textContaining('Demo Agent'), findsOneWidget, reason: 'who decided, and when');
    expect(find.byKey(const Key('restrict-c1')), findsOneWidget);
  });

  testWidgets('reject needs a reason', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.byKey(const Key('reject-c1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('verify-reason')), 'Name does not match');
    await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('reject c1 Name does not match'));
    expect(find.text('Name does not match'), findsOneWidget);
  });
}
