import 'package:flutter/material.dart';

import '../widgets/home_nav_bar.dart';
import '../theme/app_theme.dart';
import '../state/history_filter.dart';
import 'account_screen.dart';
import 'commission_screen.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'reports_screen.dart';
import 'pending_deposits_screen.dart';
import 'pending_withdrawals_screen.dart';
import 'users_screen.dart';
import '../l10n/tr.dart';

/// Bottom navigation with six tabs:
/// Dashboard | Users | Reports | Commission | History | Account.
///
/// Tabs stay alive in an IndexedStack. Other tabs can jump to History with
/// a filter applied via [openHistory].
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _historyTab = 4;
  int _index = 0;
  final _historyRequest = ValueNotifier<HistoryFilter?>(null);

  static List<String> get _titles => [tr('Dashboard'), tr('Users'), tr('Reports'), tr('Commission'), tr('History'), tr('Account')];

  void _openHistory(HistoryFilter filter) {
    _historyRequest.value = filter;
    setState(() => _index = _historyTab);
  }

  @override
  void dispose() {
    _historyRequest.dispose();
    super.dispose();
  }

  static const _icons = [
    Icons.grid_view_rounded,
    Icons.people_rounded,
    Icons.bar_chart_rounded,
    Icons.payments_rounded,
    Icons.history_rounded,
    Icons.person_rounded,
  ];

  /// Users, Reports and Commission draw their own purple header (with the title in it); the others use the app bar.
  bool get _ownHeader => _index == 1 || _index == 2 || _index == 3;

  Future<void> _openPending(String title, Widget body) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(appBar: AppBar(title: Tx(title)), body: body),
    ));
  }

  /// The bell: what is waiting for the agent (pending deposits and withdrawals).
  void _showAttention() {
    final n = DashboardScreen.pending.value;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Tx('Needs your attention', style: const TextStyle(fontWeight: FontWeight.w800))),
            if (n == 0)
              ListTile(leading: const Icon(Icons.check_circle_rounded, color: AppColors.statusCompleted), title: const Tx('Nothing is waiting. All caught up.')),
            ListTile(
              key: const Key('bell-deposits'),
              leading: const Icon(Icons.south_rounded, color: AppColors.statusPending),
              title: const Tx('Pending Deposits'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.pop(ctx);
                _openPending(tr('Pending Deposits'), const PendingDepositsScreen());
              },
            ),
            ListTile(
              key: const Key('bell-withdrawals'),
              leading: const Icon(Icons.north_rounded, color: AppColors.statusProcessing),
              title: const Tx('Pending Withdrawals'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.pop(ctx);
                _openPending(tr('Pending Withdrawals'), const PendingWithdrawalsScreen());
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _ownHeader
          ? null
          : AppBar(
              title: Tx(_titles[_index]),
              // Dashboard only: the menu (the six tabs) and the bell.
              leading: _index == 0
                  ? Builder(
                      builder: (context) => IconButton(
                        key: const Key('open-menu'),
                        tooltip: tr('Menu'),
                        icon: const Icon(Icons.menu_rounded),
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    )
                  : null,
              actions: [
                if (_index == 0)
                  ValueListenableBuilder<int>(
                    valueListenable: DashboardScreen.pending,
                    builder: (_, n, __) => IconButton(
                      key: const Key('open-bell'),
                      tooltip: tr('Notifications'),
                      onPressed: _showAttention,
                      icon: Stack(clipBehavior: Clip.none, children: [
                        const Icon(Icons.notifications_none_rounded),
                        if (n > 0)
                          Positioned(
                            right: -1,
                            top: -1,
                            child: Container(
                              key: const Key('bell-dot'),
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(color: AppColors.statusFailed, shape: BoxShape.circle),
                            ),
                          ),
                      ]),
                    ),
                  ),
              ],
            ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('BADAL EXCHANGE', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5))),
              const Divider(),
              for (var i = 0; i < _titles.length; i++)
                ListTile(
                  key: Key('menu-tab-$i'),
                  leading: Icon(_icons[i]),
                  title: Tx(_titles[i]),
                  selected: _index == i,
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _index = i);
                  },
                ),
            ],
          ),
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(onOpenHistory: _openHistory, onOpenUsers: () => setState(() => _index = 1)),
          const UsersScreen(),
          ReportsScreen(onOpenHistory: _openHistory),
          const CommissionScreen(),
          HistoryScreen(requests: _historyRequest),
          const AccountScreen(),
        ],
      ),
      bottomNavigationBar: HomeNavBar(selectedIndex: _index, onSelected: (i) => setState(() => _index = i)),
    );
  }
}
