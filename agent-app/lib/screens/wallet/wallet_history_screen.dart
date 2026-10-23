import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../l10n/wallet_strings.dart';
import '../../models/wallet_adjustment.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';

/// Wallet adjustments (Add / Deduct Money), newest first, filterable. For
/// one customer when [customerId] is set; otherwise every adjustment the
/// caller may see (their own, or everyone's for managers). Staff-only.
class WalletHistoryScreen extends StatefulWidget {
  final String? customerId;
  final String? name;
  final String? phone;
  final String? balance;

  const WalletHistoryScreen({super.key, this.customerId, this.name, this.phone, this.balance});

  @override
  State<WalletHistoryScreen> createState() => _WalletHistoryScreenState();
}

class _WalletHistoryScreenState extends State<WalletHistoryScreen> {
  String? _direction; // null = all
  List<WalletAdjustment>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items =
          await context.read<Session>().api.getWalletAdjustments(customerId: widget.customerId, direction: _direction);
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : WalletStrings.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.customerId == null ? WalletStrings.walletAdjustments : WalletStrings.walletHistory)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            if (widget.name != null) ...[
              ConsoleCard(
                child: Row(
                  children: [
                    const TintedIcon(icon: Icons.person_rounded, color: AppColors.purple, size: 52),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.name!,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                          if (widget.phone != null)
                            Text(widget.phone!, style: const TextStyle(color: AppColors.textSecondary)),
                          if (widget.balance != null) ...[
                            const SizedBox(height: 4),
                            Text(WalletStrings.walletBalance,
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                            Text('\$${widget.balance}',
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            ChoiceChipsRow<String?>(
              options: [
                (null, WalletStrings.all),
                ('add', WalletStrings.addMoney),
                ('deduct', WalletStrings.deductMoney)
              ],
              selected: _direction,
              onSelected: (d) {
                setState(() {
                  _direction = d;
                  _items = null;
                });
                _load();
              },
            ),
            const SizedBox(height: 6),
            Text(WalletStrings.privateNote, style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
            const SizedBox(height: 10),
            if (_error != null)
              ErrorStateView(message: _error!, onRetry: _load)
            else if (items == null)
              const Padding(padding: EdgeInsets.only(top: 40), child: LoadingView())
            else if (items.isEmpty)
              ConsoleCard(child: Text(WalletStrings.none, style: const TextStyle(color: AppColors.textSecondary)))
            else
              for (final a in items) ...[
                _AdjustmentTile(adjustment: a, showCustomer: widget.customerId == null),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

class _AdjustmentTile extends StatelessWidget {
  final WalletAdjustment adjustment;
  final bool showCustomer;

  const _AdjustmentTile({required this.adjustment, required this.showCustomer});

  @override
  Widget build(BuildContext context) {
    final a = adjustment;
    final color = a.isAdd ? AppColors.statusCompleted : AppColors.accentOrange;
    return ConsoleCard(
      key: Key('adjustment-${a.reference}'),
      padding: const EdgeInsets.all(14),
      onTap: () => _showDetails(context, a),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TintedIcon(icon: a.isAdd ? Icons.south_rounded : Icons.north_rounded, color: color, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.isAdd ? WalletStrings.addMoney : WalletStrings.deductMoney,
                    style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                if (showCustomer)
                  Text('${a.customerName} · ${a.customerPhone}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary)),
                Text(a.reason,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textSecondary)),
                Text(formatDateTime(a.createdAt), style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${a.isAdd ? '+' : '-'}\$${a.amount}',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: a.isAdd ? AppColors.statusCompleted : AppColors.statusFailed)),
              const SizedBox(height: 18),
              Text('Tx: ${a.reference}', style: const TextStyle(color: AppColors.textFaint, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  static Future<void> _showDetails(BuildContext context, WalletAdjustment a) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(a.isAdd ? WalletStrings.addMoney : WalletStrings.deductMoney,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              InfoRow(WalletStrings.reference, a.reference),
              InfoRow(WalletStrings.customer, '${a.customerName} · ${a.customerPhone}'),
              InfoRow(a.isAdd ? WalletStrings.amountAdded : WalletStrings.amountDeducted, '\$${a.amount}'),
              InfoRow(WalletStrings.balanceBefore, '\$${a.balanceBefore}'),
              InfoRow(WalletStrings.balanceAfter, '\$${a.balanceAfter}'),
              InfoRow(WalletStrings.reason, a.reason),
              InfoRow(WalletStrings.agent, a.agentName),
              InfoRow(WalletStrings.date, formatDateTime(a.createdAt)),
              InfoRow(WalletStrings.status, a.status == 'completed' ? WalletStrings.completed : a.status),
            ],
          ),
        ),
      ),
    );
  }
}
