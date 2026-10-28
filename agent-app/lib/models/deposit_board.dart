import 'order.dart';

/// One deposit on the "Lacagaha Sugaya Xaqiijinta" board
/// (agent_deposit_board): the order plus who sent it and how long it waited.
class BoardDeposit {
  final Order order;
  final String? customerName;
  final String? customerPhone;
  final int waitingSeconds;
  final String? failureReason;

  const BoardDeposit({
    required this.order,
    this.customerName,
    this.customerPhone,
    required this.waitingSeconds,
    this.failureReason,
  });

  bool get isPending => order.status == 'pending';

  factory BoardDeposit.fromJson(Map<String, dynamic> json) => BoardDeposit(
        order: Order.fromJson(json),
        customerName: json['customerName'] as String?,
        customerPhone: json['customerPhone'] as String?,
        waitingSeconds: (json['waitingSeconds'] as num?)?.toInt() ?? 0,
        failureReason: json['failureReason'] as String?,
      );
}

class DepositBoard {
  final int pendingCount;
  final int pendingCustomers;
  final String pendingTotal;
  final int expiredCount;
  final int newCount;
  final List<BoardDeposit> deposits;

  const DepositBoard({
    required this.pendingCount,
    required this.pendingCustomers,
    required this.pendingTotal,
    required this.expiredCount,
    required this.newCount,
    required this.deposits,
  });

  factory DepositBoard.fromJson(Map<String, dynamic> json) {
    final s = (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    return DepositBoard(
      pendingCount: n('pendingCount'),
      pendingCustomers: n('pendingCustomers'),
      pendingTotal: (s['pendingTotal'] ?? '0.00').toString(),
      expiredCount: n('expiredCount'),
      newCount: n('newCount'),
      deposits: ((json['deposits'] as List?) ?? const [])
          .map((e) => BoardDeposit.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}

/// "2 daqiiqo", "4 saac", "2 maalin": how long a deposit has waited.
String waitedText(int seconds) {
  if (seconds < 60) return '$seconds ilbiriqsi';
  if (seconds < 3600) return '${seconds ~/ 60} daqiiqo';
  if (seconds < 86400) return '${seconds ~/ 3600} saac';
  return '${seconds ~/ 86400} maalin';
}

/// One row of Unconfirmed Deposits (manage_unconfirmed_deposits): a deposit
/// form the customer has not confirmed, or a confirmed request waiting for
/// verification (or one that expired / was rejected, never credited).
class UnconfirmedDeposit {
  final String id;
  final String? orderId;
  final String? orderCode;
  final String customerId;
  final String? customerName;
  final String customerPhone;
  final String method;
  final String? amount;
  final String? accountId;

  /// not_confirmed | pending_verification | expired | cancelled
  final String status;
  final String statusText;

  /// Started more than 48 hours ago and still not confirmed / not verified.
  final bool overdue;
  final DateTime startedAt;
  final DateTime? submittedAt;
  final int waitingSeconds;

  const UnconfirmedDeposit({
    required this.id,
    this.orderId,
    this.orderCode,
    required this.customerId,
    this.customerName,
    required this.customerPhone,
    required this.method,
    this.amount,
    this.accountId,
    required this.status,
    required this.statusText,
    required this.overdue,
    required this.startedAt,
    this.submittedAt,
    required this.waitingSeconds,
  });

  factory UnconfirmedDeposit.fromJson(Map<String, dynamic> j) => UnconfirmedDeposit(
        id: j['id'] as String,
        orderId: j['orderId'] as String?,
        orderCode: j['orderCode'] as String?,
        customerId: j['customerId'] as String? ?? '',
        customerName: j['customerName'] as String?,
        customerPhone: j['customerPhone'] as String? ?? '',
        method: j['method'] as String? ?? '',
        amount: j['amount'] as String?,
        accountId: j['accountId'] as String?,
        status: j['status'] as String? ?? '',
        statusText: j['statusText'] as String? ?? '',
        overdue: j['overdue'] as bool? ?? false,
        startedAt: DateTime.tryParse(j['startedAt']?.toString() ?? '') ?? DateTime.now(),
        submittedAt: j['submittedAt'] != null ? DateTime.tryParse(j['submittedAt'].toString()) : null,
        waitingSeconds: (j['waitingSeconds'] as num?)?.toInt() ?? 0,
      );
}

class UnconfirmedDeposits {
  final int notConfirmed;
  final int pendingVerification;
  final int overdue;
  final int expired;
  final List<UnconfirmedDeposit> deposits;

  const UnconfirmedDeposits({
    required this.notConfirmed,
    required this.pendingVerification,
    required this.overdue,
    required this.expired,
    required this.deposits,
  });

  factory UnconfirmedDeposits.fromJson(Map<String, dynamic> json) {
    final s = (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    return UnconfirmedDeposits(
      notConfirmed: n('notConfirmed'),
      pendingVerification: n('pendingVerification'),
      overdue: n('overdue'),
      expired: n('expired'),
      deposits: ((json['deposits'] as List?) ?? const [])
          .map((e) => UnconfirmedDeposit.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}
