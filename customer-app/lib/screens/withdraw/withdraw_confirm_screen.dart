import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../models/payment_method.dart';
import '../../models/player.dart';
import '../../models/quote.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_card.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/summary_row.dart';
import 'withdraw_processing_screen.dart';

/// Shows exactly what the backend quoted -- phone/account ID, amount, fee,
/// total deducted from the wallet, and amount to receive -- and submits
/// the withdrawal on confirm.
///
/// 888STARZ / 1XBET: the player ID is first looked up at the platform
/// ("Find a Player") and the player's name shown as the platform gave it;
/// Confirm stays off until the platform has found that player.
class WithdrawConfirmScreen extends StatefulWidget {
  const WithdrawConfirmScreen({
    super.key,
    required this.quote,
    this.phoneNumber,
    this.accountId,
  });

  final Quote quote;
  final String? phoneNumber;
  final String? accountId;

  @override
  State<WithdrawConfirmScreen> createState() => _WithdrawConfirmScreenState();
}

class _WithdrawConfirmScreenState extends State<WithdrawConfirmScreen> {
  /// Generated once per submit attempt and reused across retries of the
  /// same logical request, so a network retry can never double-submit.
  late final String _idempotencyKey;

  /// One tap submits once: the button stays off until the processing screen
  /// is closed.
  bool _submitting = false;

  /// Cash desk only: the platform's answer, or why there is none yet.
  PlayerLookup? _player;
  String? _playerError;
  bool _checkingPlayer = false;

  bool get _findsPlayer => methodInfo(widget.quote.method).usesWithdrawalCode;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = const Uuid().v4();
    if (_findsPlayer) _findPlayer();
  }

  Future<void> _findPlayer() async {
    setState(() {
      _checkingPlayer = true;
      _playerError = null;
    });
    try {
      final player = await context.read<CustomerApi>().findPlayer(widget.quote.method, widget.accountId ?? '');
      if (mounted) setState(() => _player = player);
    } on ApiException catch (e) {
      if (mounted) setState(() => _playerError = e.code == 'PLAYER_LOOKUP_UNAVAILABLE' || e.message.isEmpty
          ? AppStrings.playerCheckFailed
          : e.message);
    } catch (_) {
      if (mounted) setState(() => _playerError = AppStrings.playerCheckFailed);
    } finally {
      if (mounted) setState(() => _checkingPlayer = false);
    }
  }

  /// Confirm is allowed once the platform has found the player (or for
  /// methods without a player search).
  bool get _playerOk => !_findsPlayer || (_player?.found ?? false);

  List<Widget> _playerRows(PaymentMethodInfo info) {
    final player = _player;
    final String name;
    Color? color;
    if (_checkingPlayer) {
      name = AppStrings.checkingPlayer;
      color = AppColors.textMuted;
    } else if (player == null) {
      name = '—';
      color = AppColors.textMuted;
    } else if (!player.found) {
      name = AppStrings.playerNotFoundShort;
      color = AppColors.error;
    } else if (player.name == null) {
      name = AppStrings.playerNameUnavailable(info.label);
      color = AppColors.textMuted;
    } else {
      name = player.name!;
    }
    return [
      SummaryRow(label: AppStrings.playerIdFind, value: widget.accountId ?? '', valueKey: const Key('player-id')),
      const SummaryDivider(),
      SummaryRow(label: AppStrings.playerName, value: name, valueColor: color, valueKey: const Key('player-name')),
    ];
  }

  /// Why Confirm is off: the player wasn't found, or couldn't be checked.
  Widget? _playerProblem(PaymentMethodInfo info) {
    final player = _player;
    final String? message = _checkingPlayer
        ? null
        : _playerError ??
            (player != null && !player.found ? AppStrings.playerNotFound(info.label, widget.accountId ?? '') : null);
    if (message == null) return null;
    return Container(
      key: const Key('player-problem'),
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.error.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(message, style: AppTextStyles.body.copyWith(color: AppColors.error))),
          if (_playerError != null)
            TextButton(
              key: const Key('retry-player'),
              onPressed: _findPlayer,
              child: Text(AppStrings.tryAgain),
            ),
        ],
      ),
    );
  }

  /// 252610338686 -> +252 610338686
  static String _phone(String? phone) {
    final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    return digits.length >= 9 ? '+252 ${digits.substring(digits.length - 9)}' : (phone ?? '');
  }

  Future<Order> _submit(CustomerApi api) {
    return api.withdraw(
      method: widget.quote.method,
      phoneNumber: widget.phoneNumber,
      accountId: widget.accountId,
      amount: widget.quote.amount,
      idempotencyKey: _idempotencyKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final info = methodInfo(quote.method);

    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.confirmWithdrawal, style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(child: MethodIcon(method: quote.method, size: 56)),
            const SizedBox(height: 16),
            Center(
              child: Text(info.label, style: AppTextStyles.title),
            ),
            const SizedBox(height: 24),
            AppCard(
              child: Column(
                children: [
                  if (_findsPlayer)
                    ..._playerRows(info)
                  else
                    SummaryRow(
                      label: '${AppStrings.sendTo} (${info.isPlatform ? AppStrings.accountId : AppStrings.phoneNumber})',
                      value: info.isPlatform ? (widget.accountId ?? '') : _phone(widget.phoneNumber),
                    ),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.amount, value: Formatters.money(quote.amount)),
                  if (quote.rate != 1) ...[
                    const SummaryDivider(),
                    SummaryRow(label: AppStrings.rate, value: quote.rate.toString()),
                  ],
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.fee, value: Formatters.money(quote.fee)),
                  const SummaryDivider(),
                  SummaryRow(label: AppStrings.totalDeducted, value: Formatters.money(quote.walletDelta)),
                  const SummaryDivider(),
                  SummaryRow(
                    label: AppStrings.netAmount,
                    value: Formatters.money(quote.netAmount),
                    emphasize: true,
                  ),
                ],
              ),
            ),
            if (_findsPlayer && _playerProblem(info) != null) _playerProblem(info)!,
            const SizedBox(height: 32),
            PrimaryButton(
              key: const Key('confirm-withdrawal'),
              label: AppStrings.confirm,
              onPressed: _submitting || !_playerOk
                  ? null
                  : () async {
                      final api = context.read<CustomerApi>();
                      setState(() => _submitting = true);
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WithdrawProcessingScreen(
                            action: () => _submit(api),
                            method: widget.quote.method,
                            amount: widget.quote.amount,
                          ),
                        ),
                      );
                      if (mounted) setState(() => _submitting = false);
                    },
            ),
          ],
        ),
      ),
    );
  }
}
