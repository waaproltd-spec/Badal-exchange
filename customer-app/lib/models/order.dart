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
    this.amountPending = false,
    this.balanceBefore,
    this.balanceAfter,
    this.delay,
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
  /// A code-only cash-desk deposit whose amount the platform has not told
  /// us yet; amount/netAmount are placeholders until then.
  final bool amountPending;

  /// The wallet's available balance before and after this order moved it
  /// (a deposit's credit, a withdrawal's reservation); null when it didn't.
  final String? balanceBefore;
  final String? balanceAfter;

  /// Why a withdrawal still waits after 30 seconds (provider_unavailable,
  /// provider_balance, confirming, manual, waiting); null when it is not late.
  final String? delay;

  /// The server has given its last word: completed, or a definitive failure
  /// (failed, cancelled, expired). Anything else -- pending, processing, or a
  /// status this app does not know -- is still being verified: the customer is
  /// never shown "Pending", and is never told "Failed" without the server's say.
  bool get isFinal => const {'completed', 'failed', 'cancelled', 'expired'}.contains(status);
  bool get isFailedFinal => const {'failed', 'cancelled', 'expired'}.contains(status);

  /// How long a mobile-money deposit may wait for its payment before the
  /// customer is told it failed. Only what is shown: the server still
  /// credits a payment that arrives later, and the order then reads
  /// Completed.
  static const unpaidAfter = Duration(seconds: 30);

  /// The clock for [shown]; replaced in tests.
  static DateTime Function() clock = DateTime.now;

  /// This order as the customer sees it. A mobile-money deposit still
  /// unpaid [unpaidAfter] (30 seconds) after it was made reads Failed ("no payment
  /// received") instead of waiting; everything else is as the server says.
  /// [isFinal] stays the server's word, so the app keeps asking and a late
  /// payment turns it into Completed.
  Order get shown {
    if (isFinal || !isDeposit || methodInfo.isPlatform) return this;
    if (clock().difference(createdAt) < unpaidAfter) return this;
    return Order(
      id: id,
      orderCode: orderCode,
      direction: direction,
      method: method,
      status: 'failed',
      statusMessage: statusMessage,
      phoneNumber: phoneNumber,
      accountId: accountId,
      depositCode: depositCode,
      amount: amount,
      fee: fee,
      netAmount: netAmount,
      transactionRef: transactionRef,
      failureReason: 'No payment received in time',
      createdAt: createdAt,
      completedAt: completedAt,
      amountPending: amountPending,
      balanceBefore: balanceBefore,
      balanceAfter: balanceAfter,
      delay: delay,
    );
  }

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
      amountPending: json['amountPending'] as bool? ?? false,
      balanceBefore: json['balanceBefore'] as String?,
      balanceAfter: json['balanceAfter'] as String?,
      delay: json['delay'] as String?,
    );
  }
}
