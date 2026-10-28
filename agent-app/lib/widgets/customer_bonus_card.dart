import 'package:flutter/material.dart';

import '../api/agent_api.dart';
import '../api/api_exception.dart';
import '../models/console.dart';
import '../theme/app_theme.dart';
import 'console_widgets.dart';

const _rates = [(50, '0.5%'), (100, '1%'), (150, '1.5%'), (200, '2%')];

/// Customer Info, for managers: the customer's Bonus wallet, the rate they
/// earn on completed withdrawals (0.5–2%), on or off, and its history.
/// Agents who cannot manage settings don't see it.
class CustomerBonusCard extends StatefulWidget {
  final AgentApi api;
  final String customerId;

  const CustomerBonusCard({super.key, required this.api, required this.customerId});

  @override
  State<CustomerBonusCard> createState() => _CustomerBonusCardState();
}

class _CustomerBonusCardState extends State<CustomerBonusCard> {
  CustomerBonus? _bonus;
  bool _hidden = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await widget.api.getCustomerBonus(widget.customerId);
      if (mounted) setState(() => _bonus = b);
    } catch (_) {
      if (mounted) setState(() => _hidden = true);
    }
  }

  Future<void> _set({int? rateBp, bool? enabled}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final b = await widget.api.setCustomerBonus(widget.customerId, rateBp: rateBp, enabled: enabled);
      if (mounted) setState(() => _bonus = b);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Could not save the bonus.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bonus;
    if (_hidden || b == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ConsoleCard(
        key: const Key('customer-bonus'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const TintedIcon(icon: Icons.redeem_rounded, color: AppColors.accentOrange, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Withdrawal Bonus', style: TextStyle(color: AppColors.textSecondary)),
                Text('\$${b.balance}',
                    key: const Key('bonus-balance'),
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                Text('Earned in total \$${b.totalEarned}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
              ]),
            ),
            Switch(
              key: const Key('bonus-enabled'),
              value: b.enabled,
              onChanged: _saving ? null : (v) => _set(enabled: v),
            ),
          ]),
          const SizedBox(height: 10),
          Text(
            !b.programmeOn
                ? 'The bonus is switched off for everyone.'
                : b.enabled
                    ? 'Earns ${b.rate} of every completed withdrawal (not EVC Plus, Golis or ZAAD).'
                    : 'Off for this customer: no bonus on their withdrawals.',
            style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          IgnorePointer(
            ignoring: _saving || !b.enabled,
            child: Opacity(
              opacity: b.enabled ? 1 : 0.5,
              child: ChoiceChipsRow<int>(
                key: const Key('bonus-rate'),
                options: _rates,
                selected: b.rateBp,
                onSelected: (bp) {
                  if (bp != b.rateBp || b.customRateBp == null) _set(rateBp: bp);
                },
              ),
            ),
          ),
          if (b.entries.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final e in b.entries.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(e.earned ? Icons.redeem_rounded : Icons.account_balance_wallet_rounded,
                      size: 18, color: e.earned ? AppColors.statusCompleted : AppColors.purple),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.earned
                          ? '${e.rate ?? ''} of \$${e.withdrawal ?? ''} · ${e.orderCode ?? ''}'
                          : 'Moved to main wallet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                    ),
                  ),
                  Text('${formatDate(e.createdAt)}  ',
                      style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                  Text('${e.earned ? '+' : '-'}\$${e.amount}',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: e.earned ? AppColors.statusCompleted : AppColors.purple)),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}
