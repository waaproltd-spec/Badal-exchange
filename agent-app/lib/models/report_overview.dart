import 'console.dart' show ReportDay;

/// A count and an amount ("5176.80", as the server formats money).
class ReportTotal {
  final int count;
  final String total;
  const ReportTotal(this.count, this.total);

  factory ReportTotal.fromJson(dynamic j) {
    final m = (j as Map?)?.cast<String, dynamic>() ?? const {};
    return ReportTotal((m['count'] as num?)?.toInt() ?? 0, (m['total'] ?? '0.00').toString());
  }
}

/// One ranked row: a platform / method (key = method) or a customer
/// (key = customer id, with name and phone).
class RankedRow {
  final String key;
  final String label;
  final String? phone;
  final int count;
  final String total;
  const RankedRow({required this.key, required this.label, this.phone, required this.count, required this.total});
}

class TopTransaction {
  final String orderCode;
  final String method;
  final String label;
  final String direction;
  final String amount;
  final String? customerName;
  final String? customerPhone;
  final DateTime? completedAt;
  const TopTransaction({
    required this.orderCode,
    required this.method,
    required this.label,
    required this.direction,
    required this.amount,
    this.customerName,
    this.customerPhone,
    this.completedAt,
  });
}

/// Reports for a period (agent_report_overview): every section from the
/// same completed orders, so the rankings add up to the revenue.
class ReportOverview {
  final String range;
  final String? from;
  final String to;
  final String revenue;
  final int transactions;
  final String fees;
  final ReportTotal deposits;
  final ReportTotal withdrawals;
  final List<RankedRow> platforms;
  final List<RankedRow> methods;
  final List<RankedRow> users;
  final int usersCount;
  final List<TopTransaction> topTransactions;

  /// Every order of the period by status (pending, failed, ...): shown
  /// apart, never in the revenue.
  final Map<String, ReportTotal> statuses;

  /// Orders per day; null for All Time and long ranges.
  final List<ReportDay>? series;

  const ReportOverview({
    required this.range,
    this.from,
    required this.to,
    required this.revenue,
    required this.transactions,
    required this.fees,
    required this.deposits,
    required this.withdrawals,
    required this.platforms,
    required this.methods,
    required this.users,
    required this.usersCount,
    required this.topTransactions,
    required this.statuses,
    this.series,
  });

  ReportTotal status(String s) => statuses[s] ?? const ReportTotal(0, '0.00');

  factory ReportOverview.fromJson(Map<String, dynamic> j) {
    final o = (j['overview'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<Map<String, dynamic>> list(String k) =>
        ((j[k] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    RankedRow method(Map<String, dynamic> m) => RankedRow(
          key: m['method'] as String? ?? '',
          label: m['label'] as String? ?? m['method'] as String? ?? '',
          count: (m['count'] as num?)?.toInt() ?? 0,
          total: (m['total'] ?? '0.00').toString(),
        );
    return ReportOverview(
      range: j['range'] as String? ?? 'today',
      from: j['from'] as String?,
      to: j['to'] as String? ?? '',
      revenue: (o['revenue'] ?? '0.00').toString(),
      transactions: (o['transactions'] as num?)?.toInt() ?? 0,
      fees: (o['fees'] ?? '0.00').toString(),
      deposits: ReportTotal.fromJson(o['deposits']),
      withdrawals: ReportTotal.fromJson(o['withdrawals']),
      platforms: list('platforms').map(method).toList(),
      methods: list('methods').map(method).toList(),
      users: list('users')
          .map((m) => RankedRow(
                key: m['customerId'] as String? ?? '',
                label: (m['name'] as String?)?.trim().isNotEmpty == true ? m['name'] as String : (m['phone'] as String? ?? ''),
                phone: m['phone'] as String?,
                count: (m['count'] as num?)?.toInt() ?? 0,
                total: (m['total'] ?? '0.00').toString(),
              ))
          .toList(),
      usersCount: (j['usersCount'] as num?)?.toInt() ?? 0,
      topTransactions: list('transactions')
          .map((m) => TopTransaction(
                orderCode: m['orderCode'] as String? ?? '',
                method: m['method'] as String? ?? '',
                label: m['label'] as String? ?? m['method'] as String? ?? '',
                direction: m['direction'] as String? ?? '',
                amount: (m['amount'] ?? '0.00').toString(),
                customerName: m['customerName'] as String?,
                customerPhone: m['customerPhone'] as String?,
                completedAt: m['completedAt'] != null ? DateTime.tryParse(m['completedAt'].toString()) : null,
              ))
          .toList(),
      statuses: ((j['statuses'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), ReportTotal.fromJson(v))),
      series: j['series'] == null
          ? null
          : (j['series'] as List).map((e) {
              final m = (e as Map).cast<String, dynamic>();
              return ReportDay(
                m['date'] as String? ?? '',
                (m['deposits'] as num?)?.toInt() ?? 0,
                (m['withdrawals'] as num?)?.toInt() ?? 0,
                (m['orders'] as num?)?.toInt() ?? 0,
              );
            }).toList(),
    );
  }
}

/// "$5,176.80": the server's amount with thousands separators.
String usd(String amount) {
  final n = num.tryParse(amount);
  if (n == null) return '\$$amount';
  final negative = n < 0;
  final fixed = n.abs().toStringAsFixed(2);
  final whole = fixed.substring(0, fixed.length - 3);
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${negative ? '-' : ''}\$$grouped${fixed.substring(fixed.length - 3)}';
}
