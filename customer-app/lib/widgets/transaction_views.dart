import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/order.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../utils/formatters.dart';
import 'method_icon.dart';
import '../l10n/server_text.dart';

/// Where the money went to or came from: +252 number or platform account.
String orderAccount(Order order) {
  final account = order.accountId;
  if (account != null && account.isNotEmpty) return account;
  final phone = order.phoneNumber;
  if (phone == null || phone.isEmpty) return '—';
  return phone.startsWith('+') ? phone : '+$phone';
}

String _signedAmount(Order order) => order.amountPending
    ? AppStrings.amountPending
    : '${order.isDeposit ? '+' : '-'}${Formatters.money(order.amount)}';

Color _statusColor(String status) => switch (status) {
      'completed' => AppColors.statusCompleted,
      'failed' || 'cancelled' || 'expired' => AppColors.statusFailed,
      'processing' => AppColors.statusProcessing,
      _ => AppColors.statusPending,
    };

/// "Deposit Confirmed" / "Withdrawal Confirmed" once completed; otherwise
/// what the order is waiting for.
String orderStatusText(Order order) {
  if (order.status == 'completed') {
    return order.isDeposit ? AppStrings.depositConfirmed : AppStrings.withdrawalConfirmed;
  }
  if (order.status == 'pending' && order.isDeposit && !order.methodInfo.isPlatform) return AppStrings.waitingForPayment;
  if (order.status == 'pending' || order.status == 'processing') return AppStrings.inProgress;
  return switch (order.status) {
    'failed' => AppStrings.statusFailed,
    'cancelled' => AppStrings.statusCancelled,
    'expired' => AppStrings.statusExpired,
    _ => serverText(order.statusMessage.isNotEmpty ? order.statusMessage : order.status),
  };
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, required this.color});

  StatusPill.forOrder(Order order, {Key? key})
      : this(key: key, text: orderStatusText(order), color: _statusColor(order.status));

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(text, style: AppTextStyles.body.copyWith(color: color, fontWeight: FontWeight.w700, fontSize: 14)),
    );
  }
}

/// The method's icon in a white ring with a small badge (check, +, - ...).
class BadgedMethodIcon extends StatelessWidget {
  const BadgedMethodIcon({super.key, required this.method, required this.badge, required this.badgeColor, this.size = 60});

  final String method;
  final IconData badge;
  final Color badgeColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 16,
      height: size + 16,
      child: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: AppColors.purpleDark.withOpacity(0.08), blurRadius: 12)],
            ),
            child: MethodIcon(method: method, size: size),
          ),
          Positioned(
            right: 0,
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle, border: Border.all(color: AppColors.surface, width: 2)),
              child: Icon(badge, size: 16, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// A label / value line of a details card.
class DetailRow extends StatelessWidget {
  const DetailRow({super.key, required this.label, required this.value, this.valueColor, this.strong = false, this.mono = false});

  final String label;
  final String value;
  final Color? valueColor;
  final bool strong;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      color: strong ? AppColors.primaryTint.withOpacity(0.5) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: strong
                  ? AppTextStyles.body.copyWith(fontWeight: FontWeight.w700, fontSize: 14)
                  : AppTextStyles.muted.copyWith(fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: SelectableText(
              value,
              textAlign: TextAlign.right,
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: valueColor,
                letterSpacing: mono ? 0.6 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rounded white card holding [DetailRow]s with thin dividers.
class DetailsCard extends StatelessWidget {
  const DetailsCard({super.key, required this.rows, this.header});

  final List<Widget> rows;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final children = [if (header != null) header!, ...rows];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.cardBorder, width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: AppColors.cardBorderSoft),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Submitting a deposit or withdrawal: the method's icon inside a spinning
/// ring, the amount, and a progress bar. With [step] (a withdrawal being
/// sent), the three steps show instead of the "hang tight" line: checking
/// the balance, sending the money, confirming it went through; [step] is
/// the one in progress (0-2), 3 when all are done.
class ProcessingView extends StatelessWidget {
  const ProcessingView({super.key, required this.method, required this.amount, required this.deposit, this.step});

  final String? method;
  final String? amount;
  final bool deposit;
  final int? step;

  @override
  Widget build(BuildContext context) {
    final title = deposit ? AppStrings.confirmingOrder : AppStrings.confirmingWithdrawal;
    // Scrolls on a short phone (the three steps are tall); fills the screen otherwise.
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: IntrinsicHeight(child: _column(title)),
        ),
      ),
    );
  }

  Widget _column(String title) {
    return Column(
      children: [
        const Spacer(flex: 3),
        SizedBox(
          width: 180,
          height: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.primaryTint, width: 2)),
              ),
              Container(
                margin: const EdgeInsets.all(18),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.purpleSecondary.withOpacity(0.5), width: 2)),
              ),
              SizedBox(
                width: 124,
                height: 124,
                child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 3),
              ),
              if (method != null)
                MethodIcon(method: method!, size: 84)
              else
                Icon(Icons.swap_vert_rounded, size: 56, color: AppColors.primary),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (amount != null)
          Text(Formatters.money(amount!), style: AppTextStyles.amountLarge.copyWith(fontSize: 40)),
        const SizedBox(height: 10),
        Text(title, style: AppTextStyles.title.copyWith(fontSize: 18), textAlign: TextAlign.center),
        const SizedBox(height: 6),
        if (step == null)
          Text(deposit ? AppStrings.hangTightDeposit : AppStrings.hangTightWithdraw,
              style: AppTextStyles.muted, textAlign: TextAlign.center)
        else
          _Steps(step: step!),
        const Spacer(flex: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 8,
            color: AppColors.primaryDark,
            backgroundColor: AppColors.primaryTint,
          ),
        ),
        const SizedBox(height: 10),
        Text(title, style: AppTextStyles.muted.copyWith(fontSize: 13)),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// The withdrawal's three steps, each done, in progress or waiting.
class _Steps extends StatelessWidget {
  const _Steps({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    final labels = [AppStrings.stepCheckFunds, AppStrings.stepSendMoney, AppStrings.stepConfirmSent];
    return Container(
      key: const Key('withdraw-steps'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == labels.length - 1 ? 0 : 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: i < step
                        ? CircleAvatar(
                            backgroundColor: AppColors.primary,
                            child: const Icon(Icons.check_rounded, size: 18, color: Colors.white))
                        : i == step
                            ? CircularProgressIndicator(color: AppColors.primary, strokeWidth: 3)
                            : CircleAvatar(
                                backgroundColor: AppColors.primaryTint,
                                child: Text('${i + 1}', style: AppTextStyles.muted.copyWith(fontSize: 13))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(labels[i],
                            style: AppTextStyles.body.copyWith(
                                fontWeight: i == step ? FontWeight.w700 : FontWeight.w500,
                                color: i > step ? AppColors.textMuted : AppColors.textPrimary)),
                        Text(i < step ? AppStrings.stepDone : (i == step ? AppStrings.stepActive : AppStrings.stepWaiting),
                            key: Key('withdraw-step-$i'),
                            style: AppTextStyles.muted.copyWith(fontSize: 11, letterSpacing: 0.6)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// After submitting: the method with a badge, the amount, the status, and
/// the order's details. [extra] goes between the details and the button
/// (e.g. a betting platform's deposit code).
class TransactionResultView extends StatelessWidget {
  const TransactionResultView({super.key, required this.order, this.extra});

  final Order order;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final failed = const {'failed', 'cancelled', 'expired'}.contains(order.status);
    final done = order.status == 'completed';
    final color = failed ? AppColors.statusFailed : (order.isDeposit ? AppColors.statusCompleted : AppColors.statusFailed);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Center(
          child: BadgedMethodIcon(
            method: order.method,
            size: 72,
            badge: failed ? Icons.close_rounded : (done ? Icons.check_rounded : Icons.schedule_rounded),
            badgeColor: failed ? AppColors.statusFailed : (done ? AppColors.statusCompleted : AppColors.statusPending),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              order.amountPending ? AppStrings.amountPending : Formatters.money(order.amount),
              key: const Key('result-amount'),
              style: AppTextStyles.amountLarge.copyWith(fontSize: 44),
            ),
          ),
        ),
        Center(
          child: Text(order.isDeposit ? AppStrings.usdDeposited : AppStrings.usdWithdrawn,
              style: AppTextStyles.muted.copyWith(fontSize: 15)),
        ),
        const SizedBox(height: 14),
        Center(child: StatusPill.forOrder(order, key: const Key('result-status'))),
        const SizedBox(height: 22),
        DetailsCard(
          header: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                MethodIcon(method: order.method, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(order.methodLabel.toUpperCase(),
                          style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
                      Text(orderAccount(order), style: AppTextStyles.muted.copyWith(fontSize: 13)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(_signedAmount(order),
                        style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, color: color, fontSize: 16)),
                    Text((order.isDeposit ? AppStrings.deposit : AppStrings.withdraw).toUpperCase(),
                        style: AppTextStyles.muted.copyWith(fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          rows: _rows(order, includeType: false),
        ),
        if (extra != null) ...[const SizedBox(height: 16), extra!],
        const SizedBox(height: 22),
        OutlinedButton(
          key: const Key('back-to-home'),
          onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(54),
            side: BorderSide(color: AppColors.primaryDark, width: 1.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: Text(AppStrings.backToHome,
              style: AppTextStyles.body.copyWith(color: AppColors.primaryDark, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

// The carrier's / Sahal's transfer number is for agents only (Agent App):
// customers see their Transaction ID.
List<Widget> _rows(Order order, {required bool includeType}) => [
      DetailRow(label: AppStrings.transactionId, value: order.orderCode, mono: true),
      if (includeType)
        DetailRow(label: AppStrings.type, value: order.isDeposit ? AppStrings.deposit : AppStrings.withdraw),
      if (includeType) DetailRow(label: AppStrings.method, value: order.methodLabel.toUpperCase()),
      if (includeType) DetailRow(label: '${order.methodLabel.toUpperCase()} ${AppStrings.account}', value: orderAccount(order), mono: true),
      if (includeType)
        DetailRow(
          label: AppStrings.amountShort,
          value: _signedAmount(order),
          valueColor: order.isDeposit ? AppColors.statusCompleted : AppColors.textPrimary,
        ),
      if (order.balanceBefore != null)
        DetailRow(label: AppStrings.balanceBefore, value: Formatters.money(order.balanceBefore!), strong: true),
      if (order.balanceAfter != null)
        DetailRow(
          key: const Key('balance-after'),
          label: AppStrings.balanceAfter,
          value: Formatters.money(order.balanceAfter!),
          valueColor: AppColors.statusCompleted,
          strong: true,
        ),
      if (order.failureReason != null && order.failureReason!.isNotEmpty)
        DetailRow(label: AppStrings.status, value: serverText(order.failureReason!), valueColor: AppColors.statusFailed),
      DetailRow(label: AppStrings.dateTime, value: Formatters.dateTime(order.createdAt)),
    ];

/// Transaction Details as a bottom sheet over the list.
Future<void> showTransactionDetails(BuildContext context, Order order) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => TransactionDetailsSheet(order: order),
  );
}

class TransactionDetailsSheet extends StatelessWidget {
  const TransactionDetailsSheet({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      decoration: BoxDecoration(
        color: AppColors.screenBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(color: AppColors.cardBorder, borderRadius: BorderRadius.circular(3)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
            child: Row(
              children: [
                Expanded(child: Text(AppStrings.transactionDetails, style: AppTextStyles.title.copyWith(fontSize: 18))),
                IconButton(
                  tooltip: AppStrings.close,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.cardBorderSoft),
          Flexible(
            child: ListView(
              key: const Key('transaction-details'),
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(16, 18, 16, 16 + media.padding.bottom),
              children: [
                Center(
                  child: BadgedMethodIcon(
                    method: order.method,
                    size: 52,
                    badge: order.isDeposit ? Icons.add_rounded : Icons.remove_rounded,
                    badgeColor: order.isDeposit ? AppColors.statusCompleted : AppColors.statusFailed,
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(_signedAmount(order),
                      style: AppTextStyles.amountLarge.copyWith(
                          fontSize: 34, color: order.isDeposit ? AppColors.statusCompleted : AppColors.textPrimary)),
                ),
                const SizedBox(height: 8),
                Center(child: StatusPill.forOrder(order)),
                const SizedBox(height: 16),
                DetailsCard(rows: _rows(order, includeType: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
