/// Models for the Agent App console endpoints (backend/src/routes/agentConsole.ts).
/// Money stays a decimal string, exactly as the backend formats it.
import 'dart:convert';
import 'dart:typed_data';

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

  /// The picture a manager chose from the gallery (JPEG, PNG or WebP), kept
  /// with the ad; null when the ad has none (it may still have an old link).
  final Uint8List? image;
  final String? linkUrl;
  final bool enabled;
  final int sortOrder;

  const HomeAd({
    required this.id,
    required this.title,
    this.body,
    this.imageUrl,
    this.image,
    this.linkUrl,
    required this.enabled,
    required this.sortOrder,
  });

  factory HomeAd.fromJson(Map<String, dynamic> j) => HomeAd(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        body: j['body'] as String?,
        imageUrl: j['imageUrl'] as String?,
        image: _adImage(j['image']),
        linkUrl: j['linkUrl'] as String?,
        enabled: j['enabled'] as bool? ?? true,
        sortOrder: j['sortOrder'] as int? ?? 0,
      );
}

Uint8List? _adImage(Object? v) {
  if (v is! String || v.isEmpty) return null;
  try {
    return base64Decode(v);
  } catch (_) {
    return null;
  }
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

/// The redesigned Dashboard's extra figures (agent_dashboard_stats): money
/// per status, customers, the 7 days ending [day], and the top services
/// (betting-platform orders) and mobile-money deposit methods of those days.
class DashboardStats {
  final DateTime day;
  final Map<String, String> amounts;
  final int totalCustomers;
  final int newCustomersThisMonth;
  final List<DashboardDay> days;
  final List<DashboardTop> topServices;
  final List<DashboardTop> topDepositMethods;

  const DashboardStats({
    required this.day,
    required this.amounts,
    required this.totalCustomers,
    required this.newCustomersThisMonth,
    required this.days,
    required this.topServices,
    required this.topDepositMethods,
  });

  String amount(String key) => amounts[key] ?? '0.00';

  factory DashboardStats.fromJson(Map<String, dynamic> j) => DashboardStats(
        day: DateTime.parse(j['day'] as String),
        amounts: {
          for (final e in ((j['amounts'] as Map?) ?? const {}).entries) e.key as String: '${e.value}',
        },
        totalCustomers: (j['totalCustomers'] as num?)?.toInt() ?? 0,
        newCustomersThisMonth: (j['newCustomersThisMonth'] as num?)?.toInt() ?? 0,
        days: ((j['days'] as List?) ?? const []).map((e) => DashboardDay.fromJson(e as Map<String, dynamic>)).toList(),
        topServices:
            ((j['topServices'] as List?) ?? const []).map((e) => DashboardTop.fromJson(e as Map<String, dynamic>)).toList(),
        topDepositMethods: ((j['topDepositMethods'] as List?) ?? const [])
            .map((e) => DashboardTop.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class DashboardDay {
  final DateTime day;
  final int deposits;
  final int withdrawals;
  final int orders;

  const DashboardDay({required this.day, required this.deposits, required this.withdrawals, required this.orders});

  factory DashboardDay.fromJson(Map<String, dynamic> j) => DashboardDay(
        day: DateTime.parse(j['day'] as String),
        deposits: (j['deposits'] as num?)?.toInt() ?? 0,
        withdrawals: (j['withdrawals'] as num?)?.toInt() ?? 0,
        orders: (j['orders'] as num?)?.toInt() ?? 0,
      );
}

/// One row of a top list: a method, how many, and how much.
class DashboardTop {
  final String method;
  final String label;
  final int count;
  final String amount;

  const DashboardTop({required this.method, required this.label, required this.count, required this.amount});

  factory DashboardTop.fromJson(Map<String, dynamic> j) => DashboardTop(
        method: j['method'] as String? ?? '',
        label: j['label'] as String? ?? '',
        count: ((j['orders'] ?? j['count']) as num?)?.toInt() ?? 0,
        amount: '${j['amount'] ?? '0.00'}',
      );
}

/// Users screen counts (agent_customer_overview): all-time totals, and the
/// customers who joined between [from] and [to].
class CustomerOverview {
  final int total;
  final int active;
  final int blocked;
  final int joined;

  const CustomerOverview({required this.total, required this.active, required this.blocked, required this.joined});

  factory CustomerOverview.fromJson(Map<String, dynamic> j) => CustomerOverview(
        total: (j['total'] as num?)?.toInt() ?? 0,
        active: (j['active'] as num?)?.toInt() ?? 0,
        blocked: (j['blocked'] as num?)?.toInt() ?? 0,
        joined: (j['new'] as num?)?.toInt() ?? 0,
      );
}

/// One customer's withdrawal bonus, as a manager sees it (manage_customer_bonus).
class CustomerBonus {
  final String balance;

  /// The rate they earn now: "1%"; "0%" when off.
  final String rate;
  final String totalEarned;
  final bool enabled;

  /// Their own rate in basis points (50, 100, 150, 200), or null for the default.
  final int? customRateBp;
  final int defaultRateBp;

  /// The bonus for everyone; when off nobody earns, whatever is set here.
  final bool programmeOn;
  final List<CustomerBonusEntry> entries;

  const CustomerBonus({
    required this.balance,
    required this.rate,
    required this.totalEarned,
    required this.enabled,
    required this.customRateBp,
    required this.defaultRateBp,
    required this.programmeOn,
    required this.entries,
  });

  int get rateBp => customRateBp ?? defaultRateBp;

  factory CustomerBonus.fromJson(Map<String, dynamic> j) => CustomerBonus(
        balance: j['balance'] as String? ?? '0.00',
        rate: j['rate'] as String? ?? '0%',
        totalEarned: j['totalEarned'] as String? ?? '0.00',
        enabled: j['enabled'] as bool? ?? true,
        customRateBp: (j['customRateBp'] as num?)?.toInt(),
        defaultRateBp: (j['defaultRateBp'] as num?)?.toInt() ?? 100,
        programmeOn: j['programmeOn'] as bool? ?? false,
        entries: [
          for (final e in (j['entries'] as List? ?? const [])) CustomerBonusEntry.fromJson(e as Map<String, dynamic>),
        ],
      );
}

class CustomerBonusEntry {
  /// 'earned' or 'moved'.
  final String kind;

  /// Exact, possibly a fraction of a cent ("0.006").
  final String amount;
  final DateTime createdAt;
  final String? rate;
  final String? orderCode;

  /// The order it was earned on: amount, 'deposit' or 'withdraw', method.
  final String? withdrawal;
  final String? direction;
  final String? methodLabel;

  /// Moved entries: the cents credited to the main wallet.
  final String? movedToMain;

  /// The Bonus screen's history, across customers.
  final String? customerName;
  final String? customerPhone;

  /// Why it is less than the rate gives ("Daily bonus limit reached").
  final String? note;

  const CustomerBonusEntry({
    required this.kind,
    required this.amount,
    required this.createdAt,
    this.rate,
    this.orderCode,
    this.withdrawal,
    this.direction,
    this.methodLabel,
    this.movedToMain,
    this.customerName,
    this.customerPhone,
    this.note,
  });

  bool get earned => kind == 'earned';

  factory CustomerBonusEntry.fromJson(Map<String, dynamic> j) => CustomerBonusEntry(
        kind: j['kind'] as String,
        amount: j['amount'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        rate: j['rate'] as String?,
        orderCode: j['orderCode'] as String?,
        withdrawal: (j['orderAmount'] ?? j['withdrawal']) as String?,
        direction: j['direction'] as String?,
        methodLabel: j['methodLabel'] as String?,
        movedToMain: j['movedToMain'] as String?,
        customerName: j['customerName'] as String?,
        customerPhone: j['customerPhone'] as String?,
        note: j['note'] as String?,
      );
}

/// One transaction type a manager can make earn a bonus: a direction of a method.
class BonusType {
  final String direction;
  final String method;
  final String label;

  /// 'mobile_money' or 'platform'.
  final String kind;
  final bool eligible;

  const BonusType({
    required this.direction,
    required this.method,
    required this.label,
    required this.kind,
    required this.eligible,
  });

  String get key => '$direction:$method';

  factory BonusType.fromJson(Map<String, dynamic> j) => BonusType(
        direction: j['direction'] as String,
        method: j['method'] as String,
        label: j['label'] as String? ?? j['method'] as String,
        kind: j['kind'] as String? ?? 'mobile_money',
        eligible: j['eligible'] as bool? ?? false,
      );
}

class BonusCustomer {
  final String id;
  final String name;
  final String phone;
  final String balance;
  final String totalEarned;
  final String rate;

  const BonusCustomer({
    required this.id,
    required this.name,
    required this.phone,
    required this.balance,
    required this.totalEarned,
    required this.rate,
  });

  factory BonusCustomer.fromJson(Map<String, dynamic> j) => BonusCustomer(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        balance: j['balance'] as String? ?? '0.00',
        totalEarned: j['totalEarned'] as String? ?? '0.00',
        rate: j['rate'] as String? ?? '0%',
      );
}

/// The Bonus screen (manage_bonus_settings).
class BonusSettings {
  final bool enabled;
  final int defaultRateBp;
  final List<BonusType> types;
  final String totalBalance;
  final String totalEarned;

  /// Moved by customers to their main wallets ("used").
  final String totalMoved;

  /// Per customer; null: no limit.
  final String? dailyLimit;
  final String? monthlyLimit;
  final List<BonusCustomer> customers;
  final List<CustomerBonusEntry> history;

  const BonusSettings({
    required this.enabled,
    required this.defaultRateBp,
    required this.types,
    required this.totalBalance,
    required this.totalEarned,
    required this.customers,
    required this.history,
    this.totalMoved = '0.00',
    this.dailyLimit,
    this.monthlyLimit,
  });

  List<String> get eligibleKeys => [for (final t in types) if (t.eligible) t.key];

  factory BonusSettings.fromJson(Map<String, dynamic> j) => BonusSettings(
        enabled: j['enabled'] as bool? ?? false,
        defaultRateBp: (j['defaultRateBp'] as num?)?.toInt() ?? 100,
        types: [for (final t in (j['types'] as List? ?? const [])) BonusType.fromJson(t as Map<String, dynamic>)],
        totalBalance: j['totalBalance'] as String? ?? '0.00',
        totalEarned: j['totalEarned'] as String? ?? '0.00',
        totalMoved: j['totalMoved'] as String? ?? '0.00',
        dailyLimit: j['dailyLimit'] as String?,
        monthlyLimit: j['monthlyLimit'] as String?,
        customers: [
          for (final c in (j['customers'] as List? ?? const [])) BonusCustomer.fromJson(c as Map<String, dynamic>),
        ],
        history: [
          for (final e in (j['history'] as List? ?? const [])) CustomerBonusEntry.fromJson(e as Map<String, dynamic>),
        ],
      );
}
