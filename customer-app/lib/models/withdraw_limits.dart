/// One period (day or month) of the withdrawal limits.
class LimitPeriod {
  const LimitPeriod({required this.limit, required this.used, required this.remaining, this.custom = false});

  final String limit;
  final String used;
  final String remaining;

  /// The limit was set for this customer by an administrator.
  final bool custom;

  double get limitValue => double.tryParse(limit) ?? 0;
  double get usedValue => double.tryParse(used) ?? 0;
  double get remainingValue => double.tryParse(remaining) ?? 0;

  /// 0..1 of the limit already used.
  double get fraction => limitValue <= 0 ? 1 : (usedValue / limitValue).clamp(0.0, 1.0);

  factory LimitPeriod.fromJson(Map<String, dynamic> j) => LimitPeriod(
        limit: j['limit']?.toString() ?? '0.00',
        used: j['used']?.toString() ?? '0.00',
        remaining: j['remaining']?.toString() ?? '0.00',
        custom: j['custom'] as bool? ?? false,
      );
}

/// The customer's KYC status and withdrawal limits (customer_withdraw_limits).
/// The server computes every number and enforces the limits on each
/// withdrawal; the app only shows them.
class WithdrawLimits {
  const WithdrawLimits({
    required this.enabled,
    required this.kycStatus,
    required this.verified,
    required this.daily,
    required this.monthly,
    required this.availableNow,
    required this.canWithdraw,
    required this.askKyc,
    this.warning,
    this.verifiedDaily,
    this.verifiedMonthly,
  });

  final bool enabled;

  /// not_submitted | pending_auto | pending_review | approved | rejected | resubmission_required
  final String kycStatus;
  final bool verified;
  final LimitPeriod daily;
  final LimitPeriod monthly;

  /// The most that can be withdrawn right now (the smaller of both remainders).
  final String availableNow;
  final bool canWithdraw;

  /// Unverified and able to ask for KYC (nothing is waiting for review).
  final bool askKyc;

  /// null | near_daily | near_monthly | daily_reached | monthly_reached
  final String? warning;

  /// What approved KYC allows.
  final String? verifiedDaily;
  final String? verifiedMonthly;

  double get availableValue => double.tryParse(availableNow) ?? 0;
  bool get kycPending => kycStatus == 'pending_auto' || kycStatus == 'pending_review';
  bool get reached => warning == 'daily_reached' || warning == 'monthly_reached';

  factory WithdrawLimits.fromJson(Map<String, dynamic> j) {
    final kyc = (j['kyc'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ifVerified = (j['ifVerified'] as Map?)?.cast<String, dynamic>() ?? const {};
    return WithdrawLimits(
      enabled: j['enabled'] as bool? ?? true,
      kycStatus: kyc['status']?.toString() ?? 'not_submitted',
      verified: kyc['verified'] as bool? ?? false,
      daily: LimitPeriod.fromJson((j['daily'] as Map).cast<String, dynamic>()),
      monthly: LimitPeriod.fromJson((j['monthly'] as Map).cast<String, dynamic>()),
      availableNow: j['availableNow']?.toString() ?? '0.00',
      canWithdraw: j['canWithdraw'] as bool? ?? true,
      askKyc: j['askKyc'] as bool? ?? false,
      warning: j['warning'] as String?,
      verifiedDaily: ifVerified['daily']?.toString(),
      verifiedMonthly: ifVerified['monthly']?.toString(),
    );
  }
}
