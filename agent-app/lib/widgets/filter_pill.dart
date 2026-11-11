import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../theme/app_theme.dart';

/// A rounded filter button: the selected one filled in the app's purple, the others outlined.
/// Used for the date ranges (Today, This Month ...) and the company choice.
class FilterPill extends StatelessWidget {
  const FilterPill(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap,
      this.icon = Icons.calendar_month_rounded,
      this.leading});
  final IconData? icon;

  /// A picture in place of the icon (a company's logo).
  final Widget? leading;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.onPrimary : AppColors.primaryDark;
    return Material(
      color: selected ? AppColors.selected : Colors.transparent,
      shape: StadiumBorder(
          side: BorderSide(
              color: selected
                  ? AppColors.selected
                  : AppColors.primary.withOpacity(0.55),
              width: 1.4)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 8)
            ] else if (icon != null) ...[
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 8)
            ],
            Tx(label,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
          ]),
        ),
      ),
    );
  }
}
