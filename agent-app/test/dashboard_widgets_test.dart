import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/widgets/dashboard_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  final stats = DashboardStats.fromJson({
    'day': '2026-10-28',
    'amounts': {'pendingDeposits': '0.00', 'pendingWithdrawals': '30.00', 'processing': '0.00', 'completed': '6450.75', 'failed': '320.50'},
    'totalCustomers': 1248,
    'newCustomersThisMonth': 24,
    'days': [
      for (var d = 22; d <= 28; d++) {'day': '2026-10-$d', 'deposits': d - 20, 'withdrawals': 1, 'orders': d == 28 ? 0 : 3},
    ],
    'topServices': [
      {'method': 'onexbet', 'label': '1XBET', 'orders': 48, 'amount': '96.00'},
      {'method': 'melbet', 'label': 'MELBET', 'orders': 36, 'amount': '72.00'},
    ],
    'topDepositMethods': [
      {'method': 'evc_plus', 'label': 'EVC Plus', 'count': 16, 'amount': '620.00'},
    ],
  });

  test('the figures are read as sent', () {
    expect(stats.day, DateTime(2026, 10, 28));
    expect(stats.amount('completed'), '6450.75');
    expect(stats.amount('unknown'), '0.00');
    expect(stats.days, hasLength(7));
    expect(stats.days.last.orders, 0);
    expect(stats.topServices.first.count, 48);
    expect(stats.topDepositMethods.single.count, 16);
  });

  testWidgets('customers, the 7-day chart, the status ring and the top lists', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(Column(children: [
      CustomersCard(total: stats.totalCustomers, newThisMonth: stats.newCustomersThisMonth),
      TransactionsOverviewCard(days: stats.days),
      const TransactionStatusCard(completed: 243, pending: 1, processing: 0, failed: 24),
      TopListCard(title: 'Top Services / Orders', countLabel: 'orders', rows: stats.topServices, emptyText: 'none'),
      const TopListCard(title: 'Top Deposit Methods', countLabel: 'txns', rows: [], emptyText: 'No completed deposits'),
    ])));
    expect(find.text('1248'), findsOneWidget);
    expect(find.text('+24 new this month'), findsOneWidget);
    expect(find.text('Oct 22'), findsOneWidget);
    expect(find.text('Oct 28'), findsOneWidget);
    expect(find.text('268'), findsOneWidget, reason: 'the ring total');
    expect(find.text('1XBET'), findsOneWidget);
    expect(find.text('\$96.00'), findsOneWidget);
    expect(find.text('48 orders'), findsOneWidget);
    expect(find.text('No completed deposits'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty week draws without dividing by zero', (tester) async {
    await tester.pumpWidget(_host(Column(children: [
      TransactionsOverviewCard(days: [
        for (var d = 1; d <= 7; d++) DashboardDay(day: DateTime(2026, 10, d), deposits: 0, withdrawals: 0, orders: 0),
      ]),
      const TransactionStatusCard(completed: 0, pending: 0, processing: 0, failed: 0),
    ])));
    expect(find.text('0'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('day labels', () {
    expect(shortDay(DateTime(2026, 10, 28)), 'Oct 28');
    expect(longDay(DateTime(2026, 10, 28)), 'Wed, Oct 28, 2026');
  });
}
