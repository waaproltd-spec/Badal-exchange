import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../home/home_screen.dart';
import '../orders/orders_list_screen.dart';
import '../profile/profile_screen.dart';

/// Bottom navigation shell with exactly three tabs: Home, Orders, Profile.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const List<Widget> _tabs = [
    HomeScreen(),
    OrdersListScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: AppStrings.home,
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: AppStrings.orders,
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: AppStrings.profile,
          ),
        ],
      ),
    );
  }
}
