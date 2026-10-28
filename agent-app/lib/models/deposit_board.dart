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
