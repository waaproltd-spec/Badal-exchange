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

  Future<void> _move() async {
    final amount = _info?.transferable ?? '0.00';
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _moving = true);
    try {
      final info = await context.read<CustomerApi>().moveBonus();
      if (!mounted) return;
      setState(() => _info = info);
      context.read<WalletProvider?>()?.load(silent: true);
      messenger.showSnackBar(SnackBar(content: Text(AppStrings.bonusMoved(amount))));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      await _load();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(AppStrings.couldNotLoadBonus)));
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.bonusWallet, style: AppTextStyles.appBarTitle)),
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
                    loading: _moving,
                    onPressed: info.canTransfer && !_moving ? _move : null,
                  ),
                  if (!info.canTransfer)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(AppStrings.noBonusToTransfer, textAlign: TextAlign.center, style: AppTextStyles.muted),
                    ),
                  const SizedBox(height: 24),
                  if (info.entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(child: Text(AppStrings.noBonusYet, style: AppTextStyles.muted)),
                    )
                  else
                    for (final e in info.entries) BonusEntryTile(entry: e),
                ],
              ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.info});

  final BonusInfo info;

  @override
  Widget build(BuildContext context) {
    final off = info.rate == '0%';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(gradient: AppColors.cardGradient, borderRadius: BorderRadius.circular(22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.redeem_rounded, color: Colors.white.withOpacity(0.85)),
          const SizedBox(width: 8),
          Text(AppStrings.bonus, style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.85))),
        ]),
        const SizedBox(height: 4),
        Text(Formatters.money(info.balance),
            key: const Key('bonus-balance'),
            style: AppTextStyles.amountLarge.copyWith(color: AppColors.gold, fontSize: 34)),
        const SizedBox(height: 6),
        Text('${AppStrings.totalEarned}: ${Formatters.money(info.totalEarned)}',
            style: AppTextStyles.muted.copyWith(color: Colors.white70)),
        const SizedBox(height: 10),
        Text(off ? AppStrings.bonusOff : AppStrings.bonusRateInfo(info.rate),
            style: AppTextStyles.muted.copyWith(color: Colors.white, fontSize: 13)),
      ]),
    );
  }
}
