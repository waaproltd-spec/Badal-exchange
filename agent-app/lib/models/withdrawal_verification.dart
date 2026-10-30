/// One account's withdrawal approval (manage_withdrawal_verifications).
class WithdrawalVerification {
  final String customerId;
  final String accountId;
  final String? name;
  final String phone;
  final String status; // pending | approved | rejected | restricted
  final DateTime? requestedAt;
  final DateTime? decidedAt;
  final String? decidedBy;
  final String? reason;
  final String balance;
  final int depositCount;
  final String depositTotal;
  final int withdrawalCount;
  final String withdrawalTotal;
  final List<Map<String, dynamic>> recent;

  const WithdrawalVerification({
    required this.customerId,
    required this.accountId,
    this.name,
    required this.phone,
    required this.status,
    this.requestedAt,
    this.decidedAt,
    this.decidedBy,
    this.reason,
    required this.balance,
    required this.depositCount,
    required this.depositTotal,
    required this.withdrawalCount,
    required this.withdrawalTotal,
    required this.recent,
  });

  static DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());

  factory WithdrawalVerification.fromJson(Map<String, dynamic> j) {
    final d = (j['deposits'] as Map?)?.cast<String, dynamic>() ?? const {};
    final w = (j['withdrawals'] as Map?)?.cast<String, dynamic>() ?? const {};
    return WithdrawalVerification(
      customerId: j['customerId'] as String,
      accountId: j['accountId'] as String? ?? '',
      name: j['name'] as String?,
      phone: j['phone'] as String? ?? '',
      status: j['status'] as String? ?? 'pending',
      requestedAt: _date(j['requestedAt']),
      decidedAt: _date(j['decidedAt']),
      decidedBy: j['decidedBy'] as String?,
      reason: j['reason'] as String?,
      balance: (j['balance'] ?? '0.00').toString(),
      depositCount: (d['count'] as num?)?.toInt() ?? 0,
      depositTotal: (d['total'] ?? '0.00').toString(),
      withdrawalCount: (w['count'] as num?)?.toInt() ?? 0,
      withdrawalTotal: (w['total'] ?? '0.00').toString(),
      recent: ((j['recent'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList(),
    );
  }
}
