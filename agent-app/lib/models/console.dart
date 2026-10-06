/// Models for the Agent App console endpoints (backend/src/routes/agentConsole.ts).
/// Money stays a decimal string, exactly as the backend formats it.

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());
String _money(dynamic v) => (v ?? '0.00').toString();

class HistoryItem {
  /// 'order' or 'confirmation' (a payment confirmation: SMS or agent-entered).
  final String kind;
  final String id;
  final String? orderCode;
  final String direction;
  final String method;
  final String methodLabel;
  final String status;
  final String amount;
  final String? counterparty;
  final String? reference;
  final String? customerId;
  final String? customerName;
  final String? customerPhone;
  final DateTime createdAt;

  const HistoryItem({
    required this.kind,
    required this.id,
    this.orderCode,
    required this.direction,
    required this.method,
    required this.methodLabel,
    required this.status,
    required this.amount,
    this.counterparty,
    this.reference,
    this.customerId,
    this.customerName,
    this.customerPhone,
    required this.createdAt,
  });

  bool get isConfirmation => kind == 'confirmation';
  bool get isDeposit => direction == 'deposit';

  /// Headline such as "Deposit · EVC Plus" or "Payment confirmation · Golis".
  String get title {
    if (isConfirmation) return 'Payment confirmation · $methodLabel';
    return '${isDeposit ? 'Deposit' : 'Withdrawal'} · $methodLabel';
  }

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        kind: j['kind'] as String? ?? 'order',
        id: j['id'] as String,
        orderCode: j['orderCode'] as String?,
        direction: j['direction'] as String? ?? 'deposit',
        method: j['method'] as String? ?? '',
        methodLabel: j['methodLabel'] as String? ?? (j['method'] as String? ?? ''),
        status: j['status'] as String? ?? '',
        amount: _money(j['amount']),
        counterparty: j['counterparty'] as String?,
        reference: j['reference'] as String?,
        customerId: j['customerId'] as String?,
        customerName: j['customerName'] as String?,
        customerPhone: j['customerPhone'] as String?,
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
      );
}

class DashboardSummary {
  final int pendingDeposits;
  final int pendingWithdrawals;
  final int processing;
  final int completed;
  final int failed;
  final int totalTransactions;
  final List<HistoryItem> recentActivity;

  const DashboardSummary({
    required this.pendingDeposits,
    required this.pendingWithdrawals,
    required this.processing,
    required this.completed,
    required this.failed,
    required this.totalTransactions,
    required this.recentActivity,
  });

  factory DashboardSummary.fromJson(Map<String, dynamic> j) => DashboardSummary(
        pendingDeposits: j['pendingDeposits'] as int? ?? 0,
        pendingWithdrawals: j['pendingWithdrawals'] as int? ?? 0,
        processing: j['processing'] as int? ?? 0,
        completed: j['completed'] as int? ?? 0,
        failed: j['failed'] as int? ?? 0,
        totalTransactions: j['totalTransactions'] as int? ?? 0,
        recentActivity: (j['recentActivity'] as List<dynamic>? ?? [])
            .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class CustomerSummary {
  final String id;
  final String name;
  final String phone;
  final String status; // 'active' | 'blocked'
  final String walletBalance;
  final DateTime? registeredAt;
  final int orders;
  final int deposits;
  final int withdrawals;
  final int transactions;

  const CustomerSummary({
    required this.id,
    required this.name,
    required this.phone,
    required this.status,
    required this.walletBalance,
    this.registeredAt,
    this.orders = 0,
    this.deposits = 0,
    this.withdrawals = 0,
    this.transactions = 0,
  });

  bool get isActive => status == 'active';

  factory CustomerSummary.fromJson(Map<String, dynamic> j) => CustomerSummary(
        id: j['id'] as String,
        name: j['name'] as String? ?? '—',
        phone: j['phone'] as String? ?? '—',
        status: j['status'] as String? ?? 'active',
        walletBalance: _money(j['walletBalance']),
        registeredAt: _date(j['registeredAt']),
        orders: j['orders'] as int? ?? 0,
        deposits: j['deposits'] as int? ?? 0,
        withdrawals: j['withdrawals'] as int? ?? 0,
        transactions: j['transactions'] as int? ?? 0,
      );
}

class LedgerEntry {
  final String id;
  final String type; // credit | debit | reserve | release
  final String amount;
  final String balanceAfter;
  final String description;
  final DateTime createdAt;

  const LedgerEntry({
    required this.id,
    required this.type,
    required this.amount,
    required this.balanceAfter,
    required this.description,
    required this.createdAt,
  });

  factory LedgerEntry.fromJson(Map<String, dynamic> j) => LedgerEntry(
        id: j['id'] as String,
        type: j['type'] as String? ?? '',
        amount: _money(j['amount']),
        balanceAfter: _money(j['balanceAfter']),
        description: j['description'] as String? ?? '',
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
      );
}

class CustomerDetail {
  final CustomerSummary summary;
  final String pendingBalance;
  final int totalOrders;
  final String totalDeposits;
  final String totalWithdrawals;
  final int totalTransactions;
  final List<HistoryItem> recentOrders;
  final List<LedgerEntry> recentTransactions;

  const CustomerDetail({
    required this.summary,
    required this.pendingBalance,
    required this.totalOrders,
    required this.totalDeposits,
    required this.totalWithdrawals,
    required this.totalTransactions,
    required this.recentOrders,
    required this.recentTransactions,
  });

  factory CustomerDetail.fromJson(Map<String, dynamic> j) => CustomerDetail(
        summary: CustomerSummary.fromJson(j),
        pendingBalance: _money(j['pendingBalance']),
        totalOrders: j['totalOrders'] as int? ?? 0,
        totalDeposits: _money(j['totalDeposits']),
        totalWithdrawals: _money(j['totalWithdrawals']),
        totalTransactions: j['totalTransactions'] as int? ?? 0,
        recentOrders: (j['recentOrders'] as List<dynamic>? ?? [])
            .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        recentTransactions: (j['recentTransactions'] as List<dynamic>? ?? [])
            .map((e) => LedgerEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ReportFigure {
  final int count;
  final String total;
  const ReportFigure(this.count, this.total);

  factory ReportFigure.fromJson(dynamic j) {
    final m = (j as Map<String, dynamic>?) ?? const {};
    return ReportFigure(m['count'] as int? ?? 0, _money(m['total']));
  }
}

class ReportDay {
  final String date; // YYYY-MM-DD
  final int deposits;
  final int withdrawals;
  final int orders;
  const ReportDay(this.date, this.deposits, this.withdrawals, this.orders);
}

class ReportSummary {
  final String period;
  final String from;
  final String to;
  final ReportFigure deposits;
  final ReportFigure withdrawals;
  final ReportFigure orders;
  final ReportFigure completed;
  final ReportFigure failed;
  final List<ReportDay> series;

  const ReportSummary({
    required this.period,
    required this.from,
    required this.to,
    required this.deposits,
    required this.withdrawals,
    required this.orders,
    required this.completed,
    required this.failed,
    required this.series,
  });

  factory ReportSummary.fromJson(Map<String, dynamic> j) => ReportSummary(
        period: j['period'] as String? ?? 'daily',
        from: j['from'] as String? ?? '',
        to: j['to'] as String? ?? '',
        deposits: ReportFigure.fromJson(j['deposits']),
        withdrawals: ReportFigure.fromJson(j['withdrawals']),
        orders: ReportFigure.fromJson(j['orders']),
        completed: ReportFigure.fromJson(j['completed']),
        failed: ReportFigure.fromJson(j['failed']),
        series: (j['series'] as List<dynamic>? ?? []).map((e) {
          final m = e as Map<String, dynamic>;
          return ReportDay(
            m['date'] as String? ?? '',
            m['deposits'] as int? ?? 0,
            m['withdrawals'] as int? ?? 0,
            m['orders'] as int? ?? 0,
          );
        }).toList(),
      );
}

class Contacts {
  final String whatsapp;
  final String facebook;
  final String telegram;
  const Contacts({this.whatsapp = '', this.facebook = '', this.telegram = ''});

  factory Contacts.fromJson(dynamic j) {
    final m = (j as Map<String, dynamic>?) ?? const {};
    return Contacts(
      whatsapp: m['whatsapp'] as String? ?? '',
      facebook: m['facebook'] as String? ?? '',
      telegram: m['telegram'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'whatsapp': whatsapp, 'facebook': facebook, 'telegram': telegram};
}

class AgentAccount {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String status;
  final List<String> responsibilities;
  final bool canManageSettings;
  final Contacts contacts;

  const AgentAccount({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    required this.status,
    required this.responsibilities,
    required this.canManageSettings,
    required this.contacts,
  });

  factory AgentAccount.fromJson(Map<String, dynamic> j) => AgentAccount(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Agent',
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        status: j['status'] as String? ?? 'active',
        responsibilities: (j['responsibilities'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
        canManageSettings: j['canManageSettings'] as bool? ?? false,
        contacts: Contacts.fromJson(j['contacts']),
      );
}

class HomeAd {
  final String id;
  final String title;
  final String? body;
  final String? imageUrl;
  final String? linkUrl;
  final bool enabled;
  final int sortOrder;

  const HomeAd({
    required this.id,
    required this.title,
    this.body,
    this.imageUrl,
    this.linkUrl,
    required this.enabled,
    required this.sortOrder,
  });

  factory HomeAd.fromJson(Map<String, dynamic> j) => HomeAd(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        body: j['body'] as String?,
        imageUrl: j['imageUrl'] as String?,
        linkUrl: j['linkUrl'] as String?,
        enabled: j['enabled'] as bool? ?? true,
        sortOrder: j['sortOrder'] as int? ?? 0,
      );
}

class DepositNumber {
  final String id;
  final String method;
  final String number;
  final String? label;
  final bool enabled;

  const DepositNumber({
    required this.id,
    required this.method,
    required this.number,
    this.label,
    required this.enabled,
  });

  factory DepositNumber.fromJson(Map<String, dynamic> j) => DepositNumber(
        id: j['id'] as String,
        method: j['method'] as String,
        number: j['number'] as String? ?? '',
        label: j['label'] as String?,
        enabled: j['enabled'] as bool? ?? true,
      );
}

class AppNotification {
  final String id;
  final String title;
  final String body;
  final DateTime createdAt;

  const AppNotification({required this.id, required this.title, required this.body, required this.createdAt});

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
      );
}
