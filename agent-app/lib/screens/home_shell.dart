import 'package:flutter/material.dart';

import '../state/history_filter.dart';
import 'account_screen.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'reports_screen.dart';
import 'users_screen.dart';

/// Bottom navigation with exactly five tabs:
/// Dashboard | Users | Reports | History | Account.
///
/// Tabs stay alive in an IndexedStack. Other tabs can jump to History with
/// a filter applied via [openHistory].
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _historyTab = 3;
  int _index = 0;
  final _historyRequest = ValueNotifier<HistoryFilter?>(null);

  static const _titles = ['Dashboard', 'Users', 'Reports', 'History', 'Account'];

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
      appBar: AppBar(title: Text(_titles[_index])),
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(onOpenHistory: _openHistory),
          const UsersScreen(),
          ReportsScreen(onOpenHistory: _openHistory),
          HistoryScreen(requests: _historyRequest),
          const AccountScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline_rounded),
            selectedIcon: Icon(Icons.people_rounded),
            label: 'Users',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart_rounded),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            selectedIcon: Icon(Icons.history_toggle_off_rounded),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}
