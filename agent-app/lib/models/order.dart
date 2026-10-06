import 'payment_methods.dart';

/// Mirrors the `serializeOrder` shape returned by the backend's
/// `/agent/*` order endpoints (see backend/src/routes/agent.ts).
///
/// Money fields are transmitted by the backend as decimal strings (it keeps
/// integer cents internally and formats with `fromCents`), so they are kept
/// as `String` here and parsed to `double` only where display math is
/// needed. This avoids re-introducing floating point drift on values that
/// are otherwise just displayed verbatim.
class Order {
  final String id;
  final String orderCode;
  final String direction; // 'deposit' | 'withdraw'
  final String method; // see lib/models/payment_methods.dart
  final String status; // 'pending' | 'processing' | 'completed' | 'failed'
  final String customerId;
  final String? phoneNumber;
  /// The customer's account ID on a betting platform (any platform method).
  final String? accountId;
  final String? depositCode;
  final String amount;
  final String fee;
  final String netAmount;
  final String walletDelta;
  final String? transactionRef;
  final DateTime createdAt;
  final DateTime? completedAt;

  const Order({
    required this.id,
    required this.orderCode,
    required this.direction,
    required this.method,
    required this.status,
    required this.customerId,
    this.phoneNumber,
    this.accountId,
    this.depositCode,
    required this.amount,
    required this.fee,
    required this.netAmount,
    required this.walletDelta,
    this.transactionRef,
    required this.createdAt,
    this.completedAt,
  });

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      id: json['id'] as String,
      orderCode: json['orderCode'] as String? ?? '',
      direction: json['direction'] as String? ?? '',
      method: json['method'] as String? ?? '',
      status: json['status'] as String? ?? '',
      customerId: json['customerId'] as String? ?? '',
      phoneNumber: json['phoneNumber'] as String?,
      accountId: (json['accountId'] ?? json['winwinId']) as String?,
      depositCode: json['depositCode'] as String?,
      amount: (json['amount'] ?? '0.00').toString(),
      fee: (json['fee'] ?? '0.00').toString(),
      netAmount: (json['netAmount'] ?? '0.00').toString(),
      walletDelta: (json['walletDelta'] ?? '0.00').toString(),
      transactionRef: json['transactionRef'] as String?,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      completedAt: json['completedAt'] != null ? DateTime.tryParse(json['completedAt'].toString()) : null,
    );
  }

  /// The identifier the agent recognizes for this order: the customer's
  /// phone number for mobile money, or their account ID on a platform.
  String get counterpartyLabel {
    if (methodInfo(method).isPlatform) return accountId ?? '—';
    return phoneNumber ?? accountId ?? '—';
  }

  String get methodLabel => methodInfo(method).label;

  bool get isDeposit => direction == 'deposit';
  bool get isWithdraw => direction == 'withdraw';
  bool get isEvcPlus => method == 'evc_plus';
  bool get isWinwin => method == 'winwin';
  bool get isPlatform => methodInfo(method).isPlatform;
}
