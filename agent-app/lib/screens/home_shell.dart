import 'package:flutter/material.dart';

import '../widgets/app_drawer.dart';
import 'completed_screen.dart';
import 'dashboard_screen.dart';
import 'failed_screen.dart';
import 'pending_deposits_screen.dart';
import 'pending_withdrawals_screen.dart';
import 'profile_screen.dart';
import 'sms_transactions_screen.dart';

/// Top-level shell hosting drawer navigation across the seven required
/// sections. Each screen manages its own data fetching/refresh; the shell
/// only tracks which one is currently selected.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  void _goTo(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      DashboardScreen(onNavigate: _goTo),
      const PendingDepositsScreen(),
      const PendingWithdrawalsScreen(),
      const SmsTransactionsScreen(),
      const CompletedScreen(),
      const FailedScreen(),
      const ProfileScreen(),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(navSections[_selectedIndex].label)),
      drawer: AppDrawer(selectedIndex: _selectedIndex, onSelect: _goTo),
      body: IndexedStack(
        index: _selectedIndex,
        children: screens,
      ),
    );
  }
}
