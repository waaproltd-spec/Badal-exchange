import 'package:flutter/material.dart';

import '../widgets/home_nav_bar.dart';
import '../state/history_filter.dart';
import 'account_screen.dart';
import 'commission_screen.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'reports_screen.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Tx(_titles[_index])),
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
