// Users: the period filters are calendar periods (This Month, Last Month, Last 3 Months, a custom
// range) and the six tabs have their Somali names.
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/screens/users_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:badal_agent_app/widgets/home_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends AgentApi {
  final ranges = <DateTimeRange>[];

  @override
  Future<List<CustomerSummary>> getCustomers(
          {String? query,
          String status = 'all',
          String sort = 'newest',
          int offset = 0}) async =>
      [];

  @override
  Future<CustomerOverview> getCustomerOverview(
      {required DateTime from, required DateTime to}) async {
    ranges.add(DateTimeRange(start: from, end: to));
    return CustomerOverview.fromJson(
        {'total': 24, 'active': 24, 'blocked': 0, 'new': 1});
  }
}

Future<_Api> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(760, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _Api();
  await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => Session(api: api),
      child: const MaterialApp(home: Scaffold(body: UsersScreen()))));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets(
      'the filters: Today, Yesterday, This Month, Last Month, Last 3 Months, Custom Date Range',
      (tester) async {
    final api = await _pump(tester);
    for (final id in [
      'today',
      'yesterday',
      'month',
      'last_month',
      'last_3m',
      'custom'
    ]) {
      expect(find.byKey(Key('users-period-$id')), findsOneWidget, reason: id);
    }
    final now = DateTime.now();
    DateTime d(int y, int m, int day) => DateTime(y, m, day);
    Future<DateTimeRange> pick(String id) async {
      await tester.ensureVisible(find.byKey(Key('users-period-$id')));
      await tester.tap(find.byKey(Key('users-period-$id')));
      await tester.pumpAndSettle();
      return api.ranges.last;
    }

    final month = await pick('month');
    expect([
      month.start,
      month.end
    ], [
      d(now.year, now.month, 1),
      d(now.year, now.month + 1, 0)
    ], reason: 'the whole of this month');
    final last = await pick('last_month');
    expect([
      last.start,
      last.end
    ], [
      d(now.year, now.month - 1, 1),
      d(now.year, now.month, 0)
    ], reason: 'the whole previous month');
    final three = await pick('last_3m');
    expect([
      three.start,
      three.end
    ], [
      d(now.year, now.month - 3, 1),
      d(now.year, now.month, 0)
    ], reason: 'the three complete months before this one');
    // November 2026 -> Aug 1 .. Oct 31 (the calendar arithmetic, whatever today is).
    expect([DateTime(2026, 11 - 3, 1), DateTime(2026, 11, 0)],
        [DateTime(2026, 8, 1), DateTime(2026, 10, 31)]);
    final yesterday = await pick('yesterday');
    expect(yesterday.start, yesterday.end);
  });

  test('the six tabs in Somali', () {
    AppLanguage.current.value = AppLanguage.somali;
    expect(HomeNavBar.labels, [
      'Bogga Hore',
      'Macaamiil',
      'Warbixinno',
      'Guddiga (Commission)',
      'Taariikh',
      'Koontada'
    ]);
  });
}
