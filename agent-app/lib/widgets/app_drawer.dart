import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';

class NavSection {
  final String label;
  final IconData icon;
  const NavSection(this.label, this.icon);
}

const List<NavSection> navSections = [
  NavSection('Dashboard', Icons.dashboard_rounded),
  NavSection('Pending Deposits', Icons.arrow_circle_down_rounded),
  NavSection('Pending Withdrawals', Icons.arrow_circle_up_rounded),
  NavSection('SMS Transactions', Icons.sms_rounded),
  NavSection('Completed', Icons.check_circle_rounded),
  NavSection('Failed', Icons.cancel_rounded),
  NavSection('Profile', Icons.person_rounded),
];

/// Drawer navigation covering all seven required sections. A drawer (rather
/// than a bottom nav bar) fits seven destinations comfortably without
/// crowding tap targets — the product brief lists "bottom nav / drawer" as
/// interchangeable.
class AppDrawer extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const AppDrawer({super.key, required this.selectedIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return Drawer(
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 22,
                    backgroundColor: AppColors.primary,
                    child: Icon(Icons.badge_rounded, color: Colors.black),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.agentDisplayName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const Text(
                          'Badal Exchange Agent',
                          style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: navSections.length,
                itemBuilder: (context, index) {
                  final section = navSections[index];
                  final selected = index == selectedIndex;
                  return ListTile(
                    leading: Icon(
                      section.icon,
                      color: selected ? AppColors.primary : AppColors.textSecondary,
                    ),
                    title: Text(
                      section.label,
                      style: TextStyle(
                        color: selected ? AppColors.primary : AppColors.textPrimary,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    selected: selected,
                    selectedTileColor: AppColors.primary.withOpacity(0.10),
                    onTap: () {
                      Navigator.of(context).pop();
                      onSelect(index);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
