import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/models/order.dart';
import 'package:badal_agent_app/screens/admin/agent_reports_screens.dart';
import 'package:badal_agent_app/screens/admin/agents_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

AgentListItem _agent({bool fullAdmin = false}) => AgentListItem.fromJson({
      'id': 'a1',
      'name': 'Cali Agent',
      'phone': '252610111222',
      'status': 'active',
      'responsibilities': ['evc_deposit'],
      'last_login_at': '2026-10-28T09:00:00Z',
      'full_admin': fullAdmin,
    });

class _FakeApi extends AgentApi {
  final calls = <String>[];
  bool lastAdmin = false;

  @override
  Future<List<AgentListItem>> getAgents() async => [_agent()];

  @override
  Future<List<AgentDevice>> getAgentDevices(String id) async => const [];

  @override
  Future<List<Order>> getAgentOrders(String id) async => const [];

  @override
  Future<List<LoginEvent>> getLoginHistory({String? userId}) async => [
        LoginEvent.fromJson({'action': 'user.login', 'createdAt': '2026-10-28T09:00:00Z', 'actorName': 'Cali Agent', 'userName': 'Cali Agent'}),
        LoginEvent.fromJson({'action': 'agent.reset_password', 'createdAt': '2026-10-28T08:00:00Z', 'actorName': 'Boss', 'userName': 'Cali Agent'}),
      ];

  @override
  Future<void> updateAgent(String id, {required String name, required String phone}) async => calls.add('edit $name $phone');

  @override
  Future<void> resetAgentPassword(String id, String newPassword) async => calls.add('reset $newPassword');

  @override
  Future<void> deleteAgent(String id, String reason) async {
    if (lastAdmin) {
      throw const ApiException(statusCode: 409, code: 'LAST_ADMIN', message: 'This is the last full administrator');
    }
    calls.add('delete $reason');
  }

  @override
  Future<List<AgentPerformance>> getAgentPerformance({required DateTime from, required DateTime to}) async => [
        AgentPerformance.fromJson({'id': 'a1', 'name': 'Cali Agent', 'status': 'active', 'deposits': 4, 'depositAmount': '40.00',
          'withdrawals': 2, 'withdrawalAmount': '12.50', 'failed': 1, 'adjustments': 0}),
      ];
}

Future<_FakeApi> _pump(WidgetTester tester, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final api = _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider(create: (_) => Session(api: api), child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('agent detail: last login, login history, edit, reset password, delete with a reason', (tester) async {
    final api = await _pump(tester, AgentDetailScreen(agent: _agent()));
    expect(find.text('Last login'), findsOneWidget);
    expect(find.text('Logged in'), findsOneWidget);
    expect(find.text('Password reset by Boss'), findsOneWidget);

    await tester.tap(find.byKey(const Key('agent-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('edit-name')), 'Cali Xasan');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'edit Cali Xasan 252610111222');

    await tester.tap(find.byKey(const Key('agent-reset-password')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-agent-password')), 'short');
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('At least 8 characters'), findsOneWidget, reason: 'checked before sending');
    await tester.enterText(find.byKey(const Key('new-agent-password')), 'NewPass-2026');
    await tester.enterText(find.byKey(const Key('confirm-agent-password')), 'NewPass-2026');
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'reset NewPass-2026');
    expect(find.text('NewPass-2026'), findsNothing, reason: 'the password is not shown afterwards');

    await tester.tap(find.byKey(const Key('agent-delete')));
    await tester.pumpAndSettle();
    final delete = find.widgetWithText(FilledButton, 'Delete');
    expect(tester.widget<FilledButton>(delete).onPressed, isNull, reason: 'a reason is required');
    await tester.enterText(find.byKey(const Key('delete-reason')), 'Left the company');
    await tester.pump();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'delete Left the company');
  });

  testWidgets('the last full administrator cannot be deleted: the server says why', (tester) async {
    final api = await _pump(tester, AgentDetailScreen(agent: _agent(fullAdmin: true)));
    api.lastAdmin = true;
    expect(find.text('Full administrator'), findsOneWidget);
    await tester.tap(find.byKey(const Key('agent-delete')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('delete-reason')), 'test');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('This is the last full administrator'), findsOneWidget);
    expect(find.byType(AgentDetailScreen), findsOneWidget, reason: 'still open');
  });

  testWidgets('agent performance and login history', (tester) async {
    await _pump(tester, const AgentPerformanceScreen());
    expect(find.text('4 · \$40.00'), findsOneWidget);
    expect(find.text('2 · \$12.50'), findsOneWidget);
    await _pump(tester, const LoginHistoryScreen());
    expect(find.text('Cali Agent · Logged in'), findsOneWidget);
    expect(find.textContaining('by Boss'), findsOneWidget);
  });
}
