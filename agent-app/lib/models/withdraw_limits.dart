/// The four default withdrawal limits, in dollars (manage_withdraw_limit_settings).
class WithdrawLimitDefaults {
  const WithdrawLimitDefaults({
    required this.unverifiedDaily,
    required this.unverifiedMonthly,
    required this.verifiedDaily,
    required this.verifiedMonthly,
  });

  final String unverifiedDaily;
  final String unverifiedMonthly;
  final String verifiedDaily;
  final String verifiedMonthly;

  factory WithdrawLimitDefaults.fromJson(Map<String, dynamic> j) => WithdrawLimitDefaults(
        unverifiedDaily: j['unverifiedDaily']?.toString() ?? '50.00',
        unverifiedMonthly: j['unverifiedMonthly']?.toString() ?? '500.00',
        verifiedDaily: j['verifiedDaily']?.toString() ?? '500.00',
        verifiedMonthly: j['verifiedMonthly']?.toString() ?? '5000.00',
      );
}

/// A customer in the Withdrawal Limits list: KYC status, what was withdrawn
/// today / this month and what is left.
class LimitCustomer {
  const LimitCustomer({
    required this.id,
    required this.name,
    required this.phone,
    required this.kycStatus,
    required this.verified,
    required this.dailyLimit,
    required this.dailyUsed,
    required this.dailyRemaining,
    required this.monthlyLimit,
    required this.monthlyUsed,
    required this.monthlyRemaining,
    required this.custom,
    this.warning,
  });

  final String id;
  final String name;
  final String phone;
  final String kycStatus;
  final bool verified;
  final String dailyLimit;
  final String dailyUsed;
  final String dailyRemaining;
  final String monthlyLimit;
  final String monthlyUsed;
  final String monthlyRemaining;
  final bool custom;
  final String? warning;

  factory LimitCustomer.fromJson(Map<String, dynamic> j) => LimitCustomer(
        id: j['id'].toString(),
        name: j['name']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        kycStatus: j['kycStatus']?.toString() ?? 'not_submitted',
        verified: j['verified'] as bool? ?? false,
        dailyLimit: j['dailyLimit']?.toString() ?? '0.00',
        dailyUsed: j['dailyUsed']?.toString() ?? '0.00',
        dailyRemaining: j['dailyRemaining']?.toString() ?? '0.00',
        monthlyLimit: j['monthlyLimit']?.toString() ?? '0.00',
        monthlyUsed: j['monthlyUsed']?.toString() ?? '0.00',
        monthlyRemaining: j['monthlyRemaining']?.toString() ?? '0.00',
        custom: j['custom'] as bool? ?? false,
        warning: j['warning'] as String?,
      );
}

class WithdrawHistoryItem {
  const WithdrawHistoryItem({required this.orderCode, required this.method, required this.amount, required this.status, required this.counted, this.createdAt});

  final String orderCode;
  final String method;
  final String amount;
  final String status;

  /// Counts towards the limits (not failed, cancelled or expired).
  final bool counted;
  final DateTime? createdAt;

  factory WithdrawHistoryItem.fromJson(Map<String, dynamic> j) => WithdrawHistoryItem(
        orderCode: j['orderCode']?.toString() ?? '',
        method: j['method']?.toString() ?? '',
        amount: j['amount']?.toString() ?? '0.00',
        status: j['status']?.toString() ?? '',
        counted: j['counted'] as bool? ?? true,
        createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? ''),
      );
}

/// One customer's limits (manage_customer_withdraw_limits).
class CustomerWithdrawLimits {
  const CustomerWithdrawLimits({
    required this.id,
    required this.name,
    required this.phone,
    required this.accountId,
    required this.kycStatus,
    required this.verified,
    required this.dailyLimit,
    required this.dailyUsed,
    required this.dailyRemaining,
    required this.monthlyLimit,
    required this.monthlyUsed,
    required this.monthlyRemaining,
    required this.customDaily,
    required this.customMonthly,
    required this.history,
    required this.defaults,
    this.note,
    this.kycApplicationId,
  });

  final String id;
  final String name;
  final String phone;
  final String accountId;
  final String kycStatus;
  final bool verified;
  final String dailyLimit;
  final String dailyUsed;
  final String dailyRemaining;
  final String monthlyLimit;
  final String monthlyUsed;
  final String monthlyRemaining;
  final bool customDaily;
  final bool customMonthly;
  final String? note;
  final String? kycApplicationId;
  final List<WithdrawHistoryItem> history;
  final WithdrawLimitDefaults defaults;

  bool get hasCustom => customDaily || customMonthly;

  factory CustomerWithdrawLimits.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic> m(String k) => ((j[k] as Map?) ?? const {}).cast<String, dynamic>();
    final customer = m('customer');
    final kyc = m('kyc');
    final daily = m('daily');
    final monthly = m('monthly');
    final custom = m('custom');
    return CustomerWithdrawLimits(
      id: customer['id'].toString(),
      name: customer['name']?.toString() ?? '',
      phone: customer['phone']?.toString() ?? '',
      accountId: customer['accountId']?.toString() ?? '',
      kycStatus: kyc['status']?.toString() ?? 'not_submitted',
      verified: kyc['verified'] as bool? ?? false,
      dailyLimit: daily['limit']?.toString() ?? '0.00',
      dailyUsed: daily['used']?.toString() ?? '0.00',
      dailyRemaining: daily['remaining']?.toString() ?? '0.00',
      monthlyLimit: monthly['limit']?.toString() ?? '0.00',
      monthlyUsed: monthly['used']?.toString() ?? '0.00',
      monthlyRemaining: monthly['remaining']?.toString() ?? '0.00',
      customDaily: custom['daily'] as bool? ?? false,
      customMonthly: custom['monthly'] as bool? ?? false,
      note: custom['note'] as String?,
      kycApplicationId: j['kycApplicationId']?.toString(),
      history: ((j['history'] as List?) ?? const [])
          .map((e) => WithdrawHistoryItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      defaults: WithdrawLimitDefaults.fromJson(m('defaults')),
    );
  }
}
