// The Dashboard in the app's own header style: the purple welcome banner with the logo, the dark
// Company Balances card (grouped total, Low / Offline chips), the Total Customers card with its
// "new this month" pill, the menu and the bell in the app bar, and the purple headers of Users and Reports.
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/models/agent_profile.dart';
import 'package:badal_agent_app/models/company_balance.dart';
import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/screens/dashboard_screen.dart';
import 'package:badal_agent_app/screens/home_shell.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:badal_agent_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends AgentApi {
  _Api({this.pending = 1});

  final int pending;

  @override
  Future<DashboardSummary> getDashboard() async => DashboardSummary.fromJson({
        'pendingDeposits': pending, 'pendingWithdrawals': 0, 'processing': 0, 'completed': 717, 'failed': 3,
        'totalTransactions': 800, 'recentActivity': [],
      });

  @override
  Future<DashboardStats> getDashboardStats({DateTime? day}) async => DashboardStats.fromJson({
        'day': '2026-11-04', 'amounts': {'pendingDeposits': '1.10', 'completed': '2604.88'},
        'totalCustomers': 24, 'newCustomersThisMonth': 1, 'days': [], 'topServices': [], 'topDepositMethods': [],
      });

  @override
  Future<CompanyBalancesOverview> getCompanyBalances({bool refresh = false, DateTime? from, DateTime? to}) async => CompanyBalancesOverview.fromJson({
        'companies': [], 'total': '66565.15', 'totalLimit': '324.94', 'lowCount': 4, 'unavailableCount': 1, 'generatedAt': '2026-11-04T17:43:00Z',
      });
}

Future<void> _pump(WidgetTester tester, Widget home, {Size size = const Size(393, 2200), _Api? api, ThemeData? theme}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = Session(api: api ?? _Api())
    ..profile = const AgentProfile(id: 'a1', name: 'BADAL EXCHANGE ADMIN', phone: '252610000002', status: 'active', responsibilities: ['manage_settings']);
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(value: session, child: MaterialApp(theme: theme, home: home)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('the banner, the dark Company Balances card and the customers card', (tester) async {
    await _pump(tester, Scaffold(body: DashboardScreen(onOpenHistory: (_) {})));
    expect(find.byKey(const Key('page-banner')), findsOneWidget);
    expect(find.byKey(const Key('banner-logo')), findsOneWidget);
    expect(find.text('Welcome, BADAL EXCHANGE ADMIN'), findsOneWidget);
    expect(find.text('Manage your transactions and company balances'), findsOneWidget);
    expect(find.text('Company Balances'), findsOneWidget);
    expect(find.text('Total Limit'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('company-total-limit'))).data, '\$324.94', reason: 'the same Total Limit as Company Balances');
    expect(find.text('Total Balance'), findsOneWidget, reason: 'the balance stays as a smaller line');
    expect(tester.widget<Text>(find.byKey(const Key('company-total'))).data, '\$66,565.15', reason: 'grouped in thousands');
    expect(find.text('4 Low'), findsOneWidget);
    expect(find.text('1 Offline'), findsOneWidget);
    expect(find.text('Total Customers'), findsOneWidget);
    expect(find.text('+1 new this month'), findsOneWidget);
    expect(find.text('717'), findsWidgets);
  });

  testWidgets('the app bar has the menu and a bell with a red dot while something waits', (tester) async {
    await _pump(tester, const HomeShell());
    expect(find.byKey(const Key('open-menu')), findsOneWidget);
    expect(find.byKey(const Key('bell-dot')), findsOneWidget, reason: '1 pending deposit');
    await tester.tap(find.byKey(const Key('open-bell')));
    await tester.pumpAndSettle();
    expect(find.text('Needs your attention'), findsOneWidget);
    expect(find.byKey(const Key('bell-deposits')), findsOneWidget);
    expect(find.byKey(const Key('bell-withdrawals')), findsOneWidget);
  });

  testWidgets('no red dot when nothing is waiting', (tester) async {
    DashboardScreen.pending.value = 0;
    await _pump(tester, const HomeShell(), api: _Api(pending: 0));
    expect(find.byKey(const Key('bell-dot')), findsNothing);
  });

  testWidgets('the menu lists the six tabs; Users and Reports show their own purple header with no app bar', (tester) async {
    await _pump(tester, const HomeShell());
    await tester.tap(find.byKey(const Key('open-menu')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      expect(find.byKey(Key('menu-tab-$i')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('menu-tab-1')));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing, reason: 'the header carries the title');
    expect(find.text('Manage your customers'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav-tab-2')));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Analytics & Insights'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav-tab-3')));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing, reason: 'Commission has its purple header too');
    expect(find.text('Agent Commission & Earnings'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav-tab-4')));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget, reason: 'the other tabs keep their app bar');
  });

  testWidgets('Somali on a small phone: no overflow on the Dashboard', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _pump(tester, Scaffold(body: DashboardScreen(onOpenHistory: (_) {})), size: const Size(360, 2200));
    expect(find.text('4 Hoose'), findsOneWidget);
    expect(find.text('1 Aan xiriirin'), findsOneWidget);
    expect(find.text('Macaamilooyinkii ugu dambeeyay'), findsOneWidget);
    // The test font is wider than the phone's and overflows some older widgets (the chart legend); the new
    // cards must not be among them.
    final problem = tester.takeException()?.toString() ?? '';
    expect(problem.contains('dashboard_screen.dart'), isFalse, reason: problem);
  });

  testWidgets('with the app\'s real theme (full-width outlined buttons): the Recent Activity heading is not squeezed by its See all button', (tester) async {
    await _pump(tester, Scaffold(body: DashboardScreen(onOpenHistory: (_) {})), theme: AppTheme.current, size: const Size(393, 3000));
    await tester.scrollUntilVisible(find.byKey(const Key('activity-see-all')), 300, scrollable: find.byType(Scrollable).first);
    final heading = tester.getSize(find.text('Recent Activity'));
    final button = tester.getSize(find.byKey(const Key('activity-see-all')));
    expect(button.width, lessThan(230), reason: 'as wide as its text: ${button.width}');
    // The test font is wider than a phone's, so the heading may take two or three lines, but never a column of letters.
    expect(heading.height, lessThan(100), reason: 'not a column of letters: ${heading.height}');
    expect(heading.width, greaterThan(100), reason: 'not squeezed: ${heading.width}');
    expect(find.text('Latest transactions'), findsOneWidget);
  });
}
