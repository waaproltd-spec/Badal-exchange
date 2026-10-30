import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/withdraw_limits.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// KYC status, today's and this month's withdrawal limits with what was
/// withdrawn and what is left, a warning near or at a limit, and (for an
/// unverified customer) the way to complete KYC. Numbers come from the server.
class WithdrawLimitsCard extends StatelessWidget {
  const WithdrawLimitsCard({super.key, required this.limits, this.onCompleteKyc});

  final WithdrawLimits limits;

  /// Opens the KYC form; null hides the button.
  final VoidCallback? onCompleteKyc;

  String get _statusLabel => limits.verified
      ? AppStrings.kycVerified
      : limits.kycPending
          ? AppStrings.kycInReview
          : limits.kycStatus == 'rejected' || limits.kycStatus == 'resubmission_required'
              ? AppStrings.kycRejected
              : AppStrings.kycNotVerified;

  Color get _statusColor =>
      limits.verified ? const Color(0xFF1FA855) : limits.kycPending ? const Color(0xFFE0A100) : AppColors.error;

  String? get _warning {
    switch (limits.warning) {
      case 'daily_reached':
        return AppStrings.limitDailyReached;
      case 'monthly_reached':
        return AppStrings.limitMonthlyReached;
      case 'near_daily':
        return AppStrings.limitNearDaily(limits.daily.remaining);
      case 'near_monthly':
        return AppStrings.limitNearMonthly(limits.monthly.remaining);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final warning = _warning;
    return Container(
      key: const Key('withdraw-limits-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.cardBorder, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(AppStrings.withdrawLimitsTitle.toUpperCase(), style: AppTextStyles.label)),
              Container(
                key: const Key('kyc-status'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: _statusColor.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(limits.verified ? Icons.verified_rounded : Icons.shield_outlined, size: 15, color: _statusColor),
                  const SizedBox(width: 5),
                  Text(_statusLabel, style: AppTextStyles.muted.copyWith(color: _statusColor, fontWeight: FontWeight.w700, fontSize: 12)),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Period(key: const Key('limit-daily'), title: AppStrings.limitToday, period: limits.daily),
          const SizedBox(height: 12),
          _Period(key: const Key('limit-monthly'), title: AppStrings.limitThisMonth, period: limits.monthly),
          if (warning != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('limit-warning'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (limits.reached ? AppColors.error : const Color(0xFFE0A100)).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(limits.reached ? Icons.block_rounded : Icons.warning_amber_rounded,
                    size: 18, color: limits.reached ? AppColors.error : const Color(0xFFB07F00)),
                const SizedBox(width: 8),
                Expanded(child: Text(warning, style: AppTextStyles.muted.copyWith(fontSize: 12.5))),
              ]),
            ),
          ],
          if (limits.kycPending) ...[
            const SizedBox(height: 10),
            Text(AppStrings.kycWaitingReview, key: const Key('kyc-waiting'), style: AppTextStyles.muted.copyWith(fontSize: 12.5)),
          ] else if (limits.askKyc) ...[
            const SizedBox(height: 10),
            Text(
              AppStrings.limitKycPrompt(limits.verifiedDaily ?? '500.00',
                  limits.verifiedMonthly ?? '5000.00'),
              key: const Key('kyc-prompt'),
              style: AppTextStyles.muted.copyWith(fontSize: 12.5),
            ),
            if (onCompleteKyc != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const Key('complete-kyc'),
                  onPressed: onCompleteKyc,
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: Text(AppStrings.completeKyc,
                      style: AppTextStyles.body.copyWith(color: AppColors.primaryDark, fontWeight: FontWeight.w700)),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Period extends StatelessWidget {
  const _Period({super.key, required this.title, required this.period});

  final String title;
  final LimitPeriod period;

  @override
  Widget build(BuildContext context) {
    final full = period.remainingValue <= 0;
    final near = period.fraction >= 0.8;
    final color = full ? AppColors.error : near ? const Color(0xFFE0A100) : AppColors.primaryDark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700))),
          Flexible(
            child: Text(AppStrings.limitLeft(period.remaining),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, color: color)),
          ),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: period.fraction,
            minHeight: 8,
            backgroundColor: AppColors.cardBorder.withOpacity(0.5),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          AppStrings.limitUsedOf(period.used, period.limit),
          style: AppTextStyles.muted.copyWith(fontSize: 12),
        ),
      ],
    );
  }
}
