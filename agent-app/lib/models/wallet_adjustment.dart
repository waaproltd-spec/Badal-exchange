/// One Add Money / Deduct Money on a customer's wallet
/// (agent_wallet_adjust / agent_wallet_adjustments). Staff-only: never sent
/// to the Customer App.
class WalletAdjustment {
  final String id;
  final String reference;
  final String customerId;
  final String customerName;
  final String customerPhone;
  final String direction; // 'add' | 'deduct'
  final String amount;
  final String balanceBefore;
  final String balanceAfter;
  final String reason;
  final String agentId;
  final String agentName;
  final String status;
  final DateTime createdAt;

  /// True when the server returned an earlier result for a retried request.
  final bool replayed;

  const WalletAdjustment({
    required this.id,
    required this.reference,
    required this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.direction,
    required this.amount,
    required this.balanceBefore,
    required this.balanceAfter,
    required this.reason,
    required this.agentId,
    required this.agentName,
    required this.status,
    required this.createdAt,
    this.replayed = false,
  });

  bool get isAdd => direction == 'add';

  factory WalletAdjustment.fromJson(Map<String, dynamic> j) => WalletAdjustment(
        id: j['id'] as String,
        reference: j['reference'] as String,
        customerId: j['customerId'] as String,
        customerName: (j['customerName'] as String?) ?? '',
        customerPhone: (j['customerPhone'] as String?) ?? '',
        direction: j['direction'] as String,
        amount: j['amount'] as String,
        balanceBefore: j['balanceBefore'] as String,
        balanceAfter: j['balanceAfter'] as String,
        reason: (j['reason'] as String?) ?? '',
        agentId: (j['agentId'] as String?) ?? '',
        agentName: (j['agentName'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'completed',
        createdAt: DateTime.parse(j['createdAt'] as String),
        replayed: j['replayed'] as bool? ?? false,
      );
}
