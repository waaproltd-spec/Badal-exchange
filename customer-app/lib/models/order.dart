import 'payment_method.dart' as pm;

/// Order shape shared by GET /customer/orders and GET /customer/orders/:id,
/// and returned by the deposit/withdrawal creation endpoints.
class Order {
  const Order({
    required this.id,
    required this.orderCode,
    required this.direction,
    required this.method,
    required this.status,
    required this.statusMessage,
    this.phoneNumber,
    this.accountId,
    this.depositCode,
    required this.amount,
    required this.fee,
    required this.netAmount,
    this.transactionRef,
    this.failureReason,
    required this.createdAt,
    this.completedAt,
  });

  final String id;
  final String orderCode;
  final String direction; // 'deposit' | 'withdraw'
  final String method; // see payment_method.dart
  final String status; // pending | processing | completed | failed | cancelled | expired
  final String statusMessage;
  final String? phoneNumber;
  /// The customer's account ID on a betting platform.
  final String? accountId;
  final String? depositCode;
  final String amount;
  final String fee;
  final String netAmount;
  final String? transactionRef;
  final String? failureReason;
  final DateTime createdAt;
  final DateTime? completedAt;

  bool get isDeposit => direction == 'deposit';
  pm.PaymentMethodInfo get methodInfo => pm.methodInfo(method);
  String get methodLabel => methodInfo.label;

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      id: json['id'] as String,
      orderCode: json['orderCode'] as String,
      direction: json['direction'] as String,
      method: json['method'] as String,
      status: json['status'] as String,
      statusMessage: json['statusMessage'] as String? ?? '',
      phoneNumber: json['phoneNumber'] as String?,
      accountId: (json['accountId'] ?? json['winwinId']) as String?,
      depositCode: json['depositCode'] as String?,
      amount: json['amount'] as String,
      fee: json['fee'] as String,
      netAmount: json['netAmount'] as String,
      transactionRef: json['transactionRef'] as String?,
      failureReason: json['failureReason'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
    );
  }
}
