import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/bonus.dart';
import '../../state/wallet_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/bonus_widgets.dart';
import '../../widgets/primary_button.dart';

/// The Bonus wallet: the balance, the customer's rate, what came in and went
/// out, and one button that moves the whole bonus to the main wallet (the
/// only thing a bonus can be used for).
class BonusScreen extends StatefulWidget {
  const BonusScreen({super.key});

  @override
  State<BonusScreen> createState() => _BonusScreenState();
}

class _BonusScreenState extends State<BonusScreen> {
  BonusInfo? _info;
  String? _error;
  bool _moving = false;
  _BonusFilter _filter = _BonusFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await context.read<CustomerApi>().getBonus();
      if (mounted) {
        setState(() {
          _info = info;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.couldNotLoadBonus);
    }
  }

  /// Asks first ("Confirm the transfer"), then moves; the result is said in a dialog, success or failure.
  Future<void> _confirmAndMove() async {
    final amount = _info?.transferable ?? '0.00';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        key: const Key('confirm-move-bonus-sheet'),
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 26),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3A0353), Color(0xFF2B0A42)]),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.card_giftcard_rounded, color: Color(0xFFFFC83D), size: 44),
            const SizedBox(height: 10),
            Text(AppStrings.bonusConfirmTitle, style: AppTextStyles.title.copyWith(fontSize: 20)),
            const SizedBox(height: 8),
            Text(AppStrings.bonusConfirmBody(amount), textAlign: TextAlign.center, style: AppTextStyles.body),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: OutlinedButton(key: const Key('cancel-move-bonus'), onPressed: () => Navigator.pop(ctx, false), child: Text(AppStrings.cancel))),
              const SizedBox(width: 12),
              Expanded(child: FilledButton(key: const Key('confirm-move-bonus'), onPressed: () => Navigator.pop(ctx, true), child: Text(AppStrings.confirm))),
            ]),
          ]),
        ),
      ),
    );
    if (ok == true && mounted) await _move();
  }

  Future<void> _showResult({required bool ok, required String message}) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: Key(ok ? 'move-bonus-done' : 'move-bonus-failed'),
          icon: Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded, color: ok ? AppColors.success : AppColors.error, size: 44),
          title: Text(ok ? AppStrings.bonusTransferDoneTitle : AppStrings.bonusTransferFailedTitle),
          content: Text(message, textAlign: TextAlign.center),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppStrings.confirm))],
        ),
      );

  Future<void> _move() async {
    final amount = _info?.transferable ?? '0.00';
    setState(() => _moving = true);
    String? failure;
    try {
      final info = await context.read<CustomerApi>().moveBonus();
      if (!mounted) return;
      setState(() => _info = info);
      context.read<WalletProvider?>()?.load(silent: true);
    } on ApiException catch (e) {
      failure = e.message;
    } catch (_) {
      failure = AppStrings.couldNotLoadBonus;
    }
    if (!mounted) return;
    setState(() => _moving = false); // the spinner stops before the result is shown
    if (failure == null) {
      await _showResult(ok: true, message: AppStrings.bonusMoved(amount));
    } else {
      await _showResult(ok: false, message: failure);
      if (mounted) await _load();
    }
  }

  List<BonusEntry> _shown(BonusInfo info) => switch (_filter) {
        _BonusFilter.all => info.entries,
        _BonusFilter.earned => info.entries.where((e) => e.earned || e.reversed).toList(),
        _BonusFilter.moved => info.entries.where((e) => !e.earned && !e.reversed).toList(),
      };

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: const Color(0xFF8E24D8).withOpacity(0.5), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 10),
          Flexible(child: Text(AppStrings.bonusWallet, style: AppTextStyles.appBarTitle)),
        ]),
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: info == null
            ? ListView(children: [
                const SizedBox(height: 140),
                Center(
                  child: _error == null
                      ? CircularProgressIndicator(color: AppColors.primary)
                      : Text(_error!, style: AppTextStyles.muted),
                ),
              ])
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _BalanceCard(info: info),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    key: const Key('move-bonus'),
                    label: AppStrings.moveBonus,
                    leadingIcon: Icons.move_to_inbox_rounded,
                    trailingIcon: Icons.chevron_right_rounded,
                    gradient: const LinearGradient(colors: [Color(0xFF7B2CBF), Color(0xFFB04DFF)]),
                    loading: _moving,
                    onPressed: info.canTransfer && !_moving ? _confirmAndMove : null,
                  ),
                  if (!info.canTransfer)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(AppStrings.noBonusToTransfer, textAlign: TextAlign.center, style: AppTextStyles.muted),
                    ),
                  const SizedBox(height: 24),
                  Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: const Color(0xFF8E24D8).withOpacity(0.35), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.history_rounded, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(AppStrings.bonusHistoryTitle, style: AppTextStyles.title.copyWith(fontSize: 19))),
                  ]),
                  const SizedBox(height: 12),
                  _FilterRow(value: _filter, onChanged: (f) => setState(() => _filter = f)),
                  const SizedBox(height: 12),
                  if (_shown(info).isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(child: Text(AppStrings.noBonusYet, style: AppTextStyles.muted)),
                    )
                  else
                    for (final e in _shown(info)) BonusEntryTile(entry: e),
                ],
              ),
      ),
    );
  }
}

enum _BonusFilter { all, earned, moved }

/// Dhammaan / Gunnada la helay / Gunnada la wareejiyay.
class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.value, required this.onChanged});

  final _BonusFilter value;
  final ValueChanged<_BonusFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final labels = {
      _BonusFilter.all: AppStrings.allHistory,
      _BonusFilter.earned: AppStrings.bonusFilterEarned,
      _BonusFilter.moved: AppStrings.bonusFilterMoved,
    };
    return Row(children: [
      for (final f in _BonusFilter.values) ...[
        Expanded(
          child: GestureDetector(
            key: Key('bonus-filter-${f.name}'),
            onTap: () => onChanged(f),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: value == f ? const LinearGradient(colors: [Color(0xFF7B2CBF), Color(0xFF9D4EDD)]) : null,
                color: value == f ? null : AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: value == f ? const Color(0xFFC77DFF) : AppColors.cardBorder, width: 1.3),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(labels[f]!, maxLines: 1, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 13.5, color: value == f ? Colors.white : AppColors.textMuted)),
              ),
            ),
          ),
        ),
        if (f != _BonusFilter.moved) const SizedBox(width: 8),
      ],
    ]);
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.info});

  final BonusInfo info;

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFC83D);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF4B1580), Color(0xFF8A2DD0)]),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFB57BFF), width: 1.4),
        boxShadow: [BoxShadow(color: const Color(0xFF8E24D8).withOpacity(0.35), blurRadius: 22, offset: const Offset(0, 10))],
      ),
      child: Row(children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(24)),
          child: const Icon(Icons.card_giftcard_rounded, color: gold, size: 52),
        ),
        const SizedBox(width: 14),
        Container(width: 1, height: 80, color: Colors.white.withOpacity(0.25)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(AppStrings.bonusTotalTitle, style: AppTextStyles.body.copyWith(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(Formatters.money(info.balance), key: const Key('bonus-balance'), style: AppTextStyles.amountLarge.copyWith(color: gold, fontSize: 38, fontWeight: FontWeight.w900)),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(18)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.savings_rounded, color: gold, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('${AppStrings.totalEarned}: ${Formatters.money(info.totalEarned)}',
                      key: const Key('bonus-total-earned'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.body.copyWith(color: Colors.white, fontSize: 13.5)),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
