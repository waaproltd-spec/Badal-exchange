import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/screens/users_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeApi extends AgentApi {
  final overviews = <String>[];
  final lists = <String>[];

  @override
  Future<CustomerOverview> getCustomerOverview({required DateTime from, required DateTime to}) async {
    overviews.add('${to.difference(from).inDays}');
    return CustomerOverview(total: 1248, active: 1180, blocked: 68, joined: overviews.length == 1 ? 24 : 310);
  }

  @override
  Future<List<CustomerSummary>> getCustomers({String? query, String status = 'all', String sort = 'newest', int offset = 0}) async {
    lists.add(status);
    return [
      CustomerSummary(
        id: 'c1',
        name: 'Abdirashiid maxamed aadan',
        phone: '252617950403',
        status: 'active',
        walletBalance: '0.00',
        registeredAt: DateTime(2026, 10, 25),
        orders: 7,
        deposits: 5,
        withdrawals: 2,
        transactions: 11,
      ),
    ];
  }
}

void main() {
  testWidgets('counts, tabs with counts, period for new customers, the customer tile', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _FakeApi();
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: api),
      child: const MaterialApp(home: Scaffold(body: UsersScreen())),
    ));
    await tester.pumpAndSettle();

    expect(find.text('1248'), findsOneWidget);
    expect(find.text('1180'), findsOneWidget);
    expect(find.text('68'), findsOneWidget);
    expect(find.text('24'), findsOneWidget, reason: 'new today');
    expect(find.text('All (1248)'), findsOneWidget);
    expect(find.text('Blocked (68)'), findsOneWidget);
    expect(find.text('Abdirashiid maxamed aadan'), findsOneWidget);
    expect(find.text('7 orders'), findsOneWidget);
    expect(find.text('11 transactions'), findsOneWidget);
    expect(api.overviews, ['0'], reason: 'today: one day');

    await tester.tap(find.byKey(const Key('users-period-month')));
    await tester.pumpAndSettle();
    expect(api.overviews.length, 2);
    expect(find.text('310'), findsOneWidget);

    await tester.tap(find.text('Blocked Customers'));
    await tester.pumpAndSettle();
    expect(api.lists.last, 'blocked');
    expect(tester.takeException(), isNull);
  });
}
