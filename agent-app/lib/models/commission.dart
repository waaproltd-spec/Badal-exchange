/// Commission for a period (agent_commission): 2% of completed betting
/// deposits, 5% of completed betting withdrawals less a 1% bonus (4% net).
/// Amounts as the server formats them ("20.00", "0.006").
class CommissionTotals {
  final int depositCount;
  final String depositTotal;
  final String depositCommission;
  final int withdrawalCount;
  final String withdrawalTotal;
  final String withdrawalGross;
  final String withdrawalCommission;
  final String grossCommission;
  final String bonus;
  final String commission;
  final int transactions;

  const CommissionTotals({
    required this.depositCount,
    required this.depositTotal,
    required this.depositCommission,
    required this.withdrawalCount,
    required this.withdrawalTotal,
    required this.withdrawalGross,
    required this.withdrawalCommission,
    required this.grossCommission,
    required this.bonus,
    required this.commission,
    required this.transactions,
  });

  factory CommissionTotals.fromJson(Map<String, dynamic> j) {
    final d = (j['deposit'] as Map?)?.cast<String, dynamic>() ?? const {};
    final w = (j['withdrawal'] as Map?)?.cast<String, dynamic>() ?? const {};
    String s(Map<String, dynamic> m, String k) => (m[k] ?? '0.00').toString();
    return CommissionTotals(
      depositCount: (d['count'] as num?)?.toInt() ?? 0,
      depositTotal: s(d, 'total'),
      depositCommission: s(d, 'commission'),
      withdrawalCount: (w['count'] as num?)?.toInt() ?? 0,
      withdrawalTotal: s(w, 'total'),
      withdrawalGross: s(w, 'grossCommission'),
      withdrawalCommission: s(w, 'commission'),
      grossCommission: s(j, 'grossCommission'),
      bonus: s(j, 'bonus'),
      commission: s(j, 'commission'),
      transactions: (j['transactions'] as num?)?.toInt() ?? 0,
    );
  }
}

class CommissionRow {
  final String orderCode;
  final String method;
  final String label;
  final String direction;
  final String status;
  final String? amount;

  /// Gross commission, bonus and net; null when the order earns nothing
  /// (not completed).
  final String? commission;
  final String? bonus;
  final String? netCommission;
  final DateTime? at;

  const CommissionRow({
    required this.orderCode,
    required this.method,
    required this.label,
    required this.direction,
    required this.status,
    this.amount,
    this.commission,
    this.bonus,
    this.netCommission,
    this.at,
  });

  bool get earns => netCommission != null;

  factory CommissionRow.fromJson(Map<String, dynamic> j) => CommissionRow(
        orderCode: j['orderCode'] as String? ?? '',
        method: j['method'] as String? ?? '',
        label: j['label'] as String? ?? j['method'] as String? ?? '',
        direction: j['direction'] as String? ?? '',
        status: j['status'] as String? ?? '',
        amount: j['amount'] as String?,
        commission: j['commission'] as String?,
        bonus: j['bonus'] as String?,
        netCommission: j['netCommission'] as String?,
        at: j['at'] != null ? DateTime.tryParse(j['at'].toString()) : null,
      );
}

class CommissionReport {
  final String range;
  final String? from;
  final String to;
  final String? method;

  /// 'agent' (one agent: always the caller's own unless a manager chose one),
  /// 'automatic' or 'all'.
  final String scope;
  final String? agentId;
  final bool canSeeAll;
  final int depositBp;
  final int withdrawBp;
  final int bonusBp;
  final CommissionTotals totals;
  final List<({String method, String label})> companies;

  /// Managers only: the agents to choose from.
  final List<({String id, String name, String? phone})>? agents;
  final List<CommissionRow> transactions;

  const CommissionReport({
    required this.range,
    this.from,
    required this.to,
    this.method,
    required this.scope,
    this.agentId,
    required this.canSeeAll,
    required this.depositBp,
    required this.withdrawBp,
    required this.bonusBp,
    required this.totals,
    required this.companies,
    this.agents,
    required this.transactions,
  });

  factory CommissionReport.fromJson(Map<String, dynamic> j) {
    final rates = (j['rates'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CommissionReport(
      range: j['range'] as String? ?? 'today',
      from: j['from'] as String?,
      to: j['to'] as String? ?? '',
      method: j['method'] as String?,
      scope: j['scope'] as String? ?? 'agent',
      agentId: j['agentId'] as String?,
      canSeeAll: j['canSeeAll'] as bool? ?? false,
      depositBp: (rates['depositBp'] as num?)?.toInt() ?? 200,
      withdrawBp: (rates['withdrawBp'] as num?)?.toInt() ?? 500,
      bonusBp: (rates['bonusBp'] as num?)?.toInt() ?? 100,
      totals: CommissionTotals.fromJson((j['summary'] as Map?)?.cast<String, dynamic>() ?? const {}),
      companies: ((j['companies'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .map((m) => (method: m['method'] as String, label: m['label'] as String? ?? m['method'] as String))
          .toList(),
      agents: j['agents'] == null
          ? null
          : (j['agents'] as List)
              .map((e) => (e as Map).cast<String, dynamic>())
              .map((m) => (id: m['id'] as String, name: m['name'] as String? ?? '', phone: m['phone'] as String?))
              .toList(),
      transactions: ((j['transactions'] as List?) ?? const [])
          .map((e) => CommissionRow.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}

/// "2%", "1.5%" from basis points.
String percent(int bp) {
  final v = bp / 100;
  return v == v.roundToDouble() ? '${v.toInt()}%' : '${v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '')}%';
}

/// "$1,000.00", and small commissions exactly: "$0.006".
String commissionMoney(String amount) {
  final n = num.tryParse(amount);
  if (n == null) return '\$$amount';
  final abs = n.abs();
  var decimals = 2;
  if (abs > 0 && abs < 1) {
    final frac = amount.contains('.') ? amount.split('.').last.replaceFirst(RegExp(r'0+$'), '') : '';
    decimals = frac.length.clamp(2, 6);
  }
  final fixed = abs.toStringAsFixed(decimals);
  final dot = fixed.indexOf('.');
  final whole = fixed.substring(0, dot).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${n < 0 ? '-' : ''}\$$whole${fixed.substring(dot)}';
}
