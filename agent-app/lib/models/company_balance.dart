/// A company's cash register balance as the server reported it
/// (agent_company_balances). [balance] is only ever a value read from the
/// company's API -- null when there is none.
class CompanyBalance {
  final String method;
  final String label;
  final bool connected;

  /// 'available' | 'low' | 'stale' | 'offline' | 'not_connected'.
  final String status;
  final String? source;

  /// Now: the last live read plus the completed sales and payouts after it.
  /// Balance = bought through the register in total; Limit = what it can
  /// still sell (null when the register did not report one).
  final String? balance;
  final String? limit;

  /// The last live read itself, and what changed after it.
  final String? liveBalance;
  final String? liveLimit;
  final String salesSinceCheck;
  final String payoutsSinceCheck;
  final int changesSinceCheck;
  final DateTime? lastSuccessAt;
  final DateTime? lastCheckedAt;
  final String? lastError;
  final String lowThreshold;
  final int waitingWithdrawals;
  final String waitingAmount;
  final String? topUpNeeded;
  final int openWithdrawals;
  final String openWithdrawalAmount;
  final CompanyPeriod period;

  const CompanyBalance({
    required this.method,
    required this.label,
    required this.connected,
    required this.status,
    this.source,
    this.balance,
    this.limit,
    this.liveBalance,
    this.liveLimit,
    this.salesSinceCheck = '0.00',
    this.payoutsSinceCheck = '0.00',
    this.changesSinceCheck = 0,
    this.lastSuccessAt,
    this.lastCheckedAt,
    this.lastError,
    required this.lowThreshold,
    required this.waitingWithdrawals,
    required this.waitingAmount,
    this.topUpNeeded,
    required this.openWithdrawals,
    required this.openWithdrawalAmount,
    required this.period,
  });

  static DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse(v.toString());

  factory CompanyBalance.fromJson(Map<String, dynamic> j) => CompanyBalance(
        method: j['method'] as String,
        label: j['label'] as String? ?? j['method'] as String,
        connected: j['connected'] as bool? ?? false,
        status: j['status'] as String? ?? 'not_connected',
        source: j['source'] as String?,
        balance: j['balance'] as String?,
        limit: j['limit'] as String?,
        liveBalance: j['liveBalance'] as String?,
        liveLimit: j['liveLimit'] as String?,
        salesSinceCheck: j['salesSinceCheck'] as String? ?? '0.00',
        payoutsSinceCheck: j['payoutsSinceCheck'] as String? ?? '0.00',
        changesSinceCheck: (j['changesSinceCheck'] as num?)?.toInt() ?? 0,
        lastSuccessAt: _date(j['lastSuccessAt']),
        lastCheckedAt: _date(j['lastCheckedAt']),
        lastError: j['lastError'] as String?,
        lowThreshold: j['lowThreshold'] as String? ?? '0.00',
        waitingWithdrawals: (j['waitingWithdrawals'] as num?)?.toInt() ?? 0,
        waitingAmount: j['waitingAmount'] as String? ?? '0.00',
        topUpNeeded: j['topUpNeeded'] as String?,
        openWithdrawals: (j['openWithdrawals'] as num?)?.toInt() ?? 0,
        openWithdrawalAmount: j['openWithdrawalAmount'] as String? ?? '0.00',
        period: CompanyPeriod.fromJson(Map<String, dynamic>.from(j['period'] as Map? ?? const {})),
      );
}

/// What went through a company in the chosen period.
class CompanyPeriod {
  final String received;
  final int receivedCount;
  final String sent;
  final int sentCount;
  final int open;
  final int failed;

  const CompanyPeriod({
    required this.received,
    required this.receivedCount,
    required this.sent,
    required this.sentCount,
    required this.open,
    required this.failed,
  });

  factory CompanyPeriod.fromJson(Map<String, dynamic> j) => CompanyPeriod(
        received: j['received'] as String? ?? '0.00',
        receivedCount: (j['receivedCount'] as num?)?.toInt() ?? 0,
        sent: j['sent'] as String? ?? '0.00',
        sentCount: (j['sentCount'] as num?)?.toInt() ?? 0,
        open: (j['open'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
      );
}

/// All companies, and the total of the fresh, verified balances.
class CompanyBalancesOverview {
  final List<CompanyBalance> companies;
  final String total;

  /// Sum of the known Limits; null when no company reported one.
  final String? totalLimit;
  final int limitUnknownCount;
  final int totalCompanies;
  final String openWithdrawalAmount;
  final int lowCount;
  final int unavailableCount;
  final int notConnectedCount;
  final DateTime generatedAt;

  const CompanyBalancesOverview({
    required this.companies,
    required this.total,
    this.totalLimit,
    this.limitUnknownCount = 0,
    required this.totalCompanies,
    required this.openWithdrawalAmount,
    required this.lowCount,
    required this.unavailableCount,
    required this.notConnectedCount,
    required this.generatedAt,
  });

  factory CompanyBalancesOverview.fromJson(Map<String, dynamic> j) => CompanyBalancesOverview(
        companies: [
          for (final c in j['companies'] as List? ?? const []) CompanyBalance.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        total: j['total'] as String? ?? '0.00',
        totalLimit: j['totalLimit'] as String?,
        limitUnknownCount: (j['limitUnknownCount'] as num?)?.toInt() ?? 0,
        totalCompanies: (j['totalCompanies'] as num?)?.toInt() ?? 0,
        openWithdrawalAmount: j['openWithdrawalAmount'] as String? ?? '0.00',
        lowCount: (j['lowCount'] as num?)?.toInt() ?? 0,
        unavailableCount: (j['unavailableCount'] as num?)?.toInt() ?? 0,
        notConnectedCount: (j['notConnectedCount'] as num?)?.toInt() ?? 0,
        generatedAt: DateTime.tryParse('${j['generatedAt']}') ?? DateTime.now(),
      );
}

/// One balance read from the company's API.
class BalanceCheck {
  final bool ok;
  final String? balance;
  final String? limit;
  final String? error;
  final DateTime checkedAt;

  const BalanceCheck({required this.ok, this.balance, this.limit, this.error, required this.checkedAt});

  factory BalanceCheck.fromJson(Map<String, dynamic> j) => BalanceCheck(
        ok: j['ok'] as bool? ?? false,
        balance: j['balance'] as String?,
        limit: j['limit'] as String?,
        error: j['error'] as String?,
        checkedAt: DateTime.parse(j['checkedAt'] as String),
      );
}

/// A completed sale (Balance +, Limit -) or payout (Balance -, Limit +) of
/// the register. [balanceAfter]/[limitAfter] are set for the ones after the
/// last live read; earlier ones are already in that read.
class CompanyMovement {
  final String kind;
  final String amount;
  final String? orderCode;
  final bool manual;
  final DateTime at;
  final bool sinceCheck;
  final String? balanceAfter;
  final String? limitAfter;

  const CompanyMovement({
    required this.kind,
    required this.amount,
    this.orderCode,
    required this.manual,
    required this.at,
    required this.sinceCheck,
    this.balanceAfter,
    this.limitAfter,
  });

  bool get isSale => kind == 'sale';

  factory CompanyMovement.fromJson(Map<String, dynamic> j) => CompanyMovement(
        kind: j['kind'] as String,
        amount: j['amount'] as String,
        orderCode: j['orderCode'] as String?,
        manual: j['manual'] as bool? ?? false,
        at: DateTime.parse(j['at'] as String),
        sinceCheck: j['sinceCheck'] as bool? ?? false,
        balanceAfter: j['balanceAfter'] as String?,
        limitAfter: j['limitAfter'] as String?,
      );
}

/// An order through the company, for its detail screen.
class CompanyOrder {
  final String id;
  final String orderCode;
  final String direction;
  final String status;
  final String? amount;
  final String? accountId;
  final String? customerName;
  final String? note;
  final bool waitingTopUp;
  final DateTime createdAt;

  const CompanyOrder({
    required this.id,
    required this.orderCode,
    required this.direction,
    required this.status,
    this.amount,
    this.accountId,
    this.customerName,
    this.note,
    required this.waitingTopUp,
    required this.createdAt,
  });

  factory CompanyOrder.fromJson(Map<String, dynamic> j) => CompanyOrder(
        id: j['id'] as String,
        orderCode: j['orderCode'] as String? ?? '',
        direction: j['direction'] as String? ?? '',
        status: j['status'] as String? ?? '',
        amount: j['amount'] as String?,
        accountId: j['accountId'] as String?,
        customerName: j['customerName'] as String?,
        note: j['note'] as String?,
        waitingTopUp: j['waitingTopUp'] as bool? ?? false,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

class CompanyDetail {
  final CompanyBalance company;
  final List<BalanceCheck> checks;
  final List<CompanyMovement> movements;
  final List<CompanyOrder> orders;

  const CompanyDetail({required this.company, required this.checks, this.movements = const [], required this.orders});

  factory CompanyDetail.fromJson(Map<String, dynamic> j) => CompanyDetail(
        company: CompanyBalance.fromJson(j),
        checks: [for (final c in j['checks'] as List? ?? const []) BalanceCheck.fromJson(Map<String, dynamic>.from(c as Map))],
        movements: [
          for (final m in j['movements'] as List? ?? const []) CompanyMovement.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
        orders: [for (final o in j['orders'] as List? ?? const []) CompanyOrder.fromJson(Map<String, dynamic>.from(o as Map))],
      );
}
