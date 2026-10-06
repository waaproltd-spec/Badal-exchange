import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/console.dart';
import '../theme/app_theme.dart';

/// Shared building blocks for the Dashboard / Users / Reports / History /
/// Account tabs, so all five read as one card-based design.

final _shortDateTime = DateFormat('MMM d, yyyy • HH:mm');
final _shortDate = DateFormat('MMM d, yyyy');

String formatDateTime(DateTime d) => _shortDateTime.format(d.toLocal());
String formatDate(DateTime d) => _shortDate.format(d.toLocal());

/// Rounded white card with the app's border.
class ConsoleCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  const ConsoleCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color ?? AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Section title with an optional trailing action ("See all").
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SectionHeader({super.key, required this.title, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// Small uppercase group label used on the Account tab.
class GroupLabel extends StatelessWidget {
  final String text;
  const GroupLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: AppColors.textSecondary),
      ),
    );
  }
}

/// Round icon in a tinted circle.
class TintedIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const TintedIcon({super.key, required this.icon, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withOpacity(0.14), shape: BoxShape.circle),
      child: Icon(icon, color: color, size: size * 0.55),
    );
  }
}

/// Count/amount tile: icon, big value, label. Used on Dashboard, Reports and
/// Customer Info.
class StatCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final String? caption;
  final VoidCallback? onTap;

  const StatCard({
    super.key,
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
    this.caption,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      onTap: onTap,
      color: Color.alphaBlend(color.withOpacity(0.05), AppColors.surface),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TintedIcon(icon: icon, color: color, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(caption!, style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
          ],
        ],
      ),
    );
  }
}

/// Lays out [children] two per row with even spacing.
class TwoColumnGrid extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const TwoColumnGrid({super.key, required this.children, this.spacing = 12});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: children[i]),
          SizedBox(width: spacing),
          Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox.shrink()),
        ],
      ));
      if (i + 2 < children.length) rows.add(SizedBox(height: spacing));
    }
    return Column(children: rows);
  }
}

/// Row of single-select chips (All / Active / Blocked, Daily / Weekly ...).
class ChoiceChipsRow<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  const ChoiceChipsRow({super.key, required this.options, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (value, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: value == selected,
                onSelected: (_) => onSelected(value),
                showCheckmark: false,
                selectedColor: AppColors.purpleDark,
                backgroundColor: AppColors.surface,
                side: BorderSide(color: value == selected ? AppColors.purpleDark : AppColors.border),
                labelStyle: TextStyle(
                  color: value == selected ? AppColors.onHeader : AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Search box used on Users and History.
class SearchField extends StatelessWidget {
  final String hint;
  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;

  const SearchField({super.key, required this.hint, required this.controller, required this.onSubmitted});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search_rounded),
        fillColor: AppColors.surface,
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, value, __) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    controller.clear();
                    onSubmitted('');
                  },
                ),
        ),
      ),
    );
  }
}

/// Status pill: green active/completed/matched, amber pending, blue
/// processing, red failed/blocked, grey otherwise.
class StatusPill extends StatelessWidget {
  final String status;
  const StatusPill(this.status, {super.key});

  static Color colorFor(String status) {
    switch (status) {
      case 'active':
      case 'completed':
      case 'matched':
        return AppColors.statusCompleted;
      case 'pending':
        return AppColors.statusPending;
      case 'processing':
        return AppColors.statusProcessing;
      case 'failed':
      case 'blocked':
        return AppColors.statusFailed;
      case 'unmatched':
        return AppColors.statusUnmatched;
      default:
        return AppColors.statusDuplicate;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(status);
    final label = status.isEmpty ? '—' : status[0].toUpperCase() + status.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.13), borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

/// One line of activity (order or payment confirmation) as shown on the
/// Dashboard, History and Customer Info.
class ActivityTile extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback? onTap;
  final bool showCustomer;

  const ActivityTile({super.key, required this.item, this.onTap, this.showCustomer = true});

  @override
  Widget build(BuildContext context) {
    final failed = item.status == 'failed';
    final (IconData icon, Color color) = item.isConfirmation
        ? (Icons.verified_rounded, AppColors.purple)
        : failed
            ? (Icons.close_rounded, AppColors.statusFailed)
            : item.isDeposit
                ? (Icons.south_rounded, AppColors.statusCompleted)
                : (Icons.north_rounded, AppColors.accentOrange);
    final sign = item.isDeposit ? '+' : '-';
    final who = showCustomer
        ? (item.customerName ?? item.customerPhone ?? item.counterparty ?? '—')
        : (item.counterparty ?? '—');

    return ConsoleCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          TintedIcon(icon: icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  '$who • ${formatDateTime(item.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$sign\$${item.amount}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: failed
                      ? AppColors.statusFailed
                      : (item.isDeposit ? AppColors.statusCompleted : AppColors.textPrimary),
                ),
              ),
              const SizedBox(height: 4),
              StatusPill(item.status),
            ],
          ),
        ],
      ),
    );
  }
}

/// Label/value line used in detail sheets.
class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const InfoRow(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet with every detail of a history item (read-only).
Future<void> showActivityDetails(BuildContext context, HistoryItem item) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
              ),
              StatusPill(item.status),
            ],
          ),
          const SizedBox(height: 12),
          InfoRow('Amount', '\$${item.amount}'),
          if (item.orderCode != null) InfoRow('Order code', item.orderCode!),
          InfoRow('Payment method', item.methodLabel),
          InfoRow(item.isConfirmation ? 'Sender / account' : 'Phone / account', item.counterparty ?? '—'),
          InfoRow('Customer', [item.customerName, item.customerPhone].whereType<String>().join(' • ').ifEmpty('—')),
          InfoRow('Reference', item.reference ?? '—'),
          InfoRow('Date', formatDateTime(item.createdAt)),
        ],
      ),
    ),
  );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
