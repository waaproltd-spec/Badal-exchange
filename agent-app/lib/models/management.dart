/// Models for the management screens (Account → Admin features), mirroring
/// the backend's /admin/* and /agent/manage/* responses.

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());

class FeeSetting {
  /// 'flat' (value in cents on the wire) or 'percent' (0-100).
  final String type;
  final double value;
  const FeeSetting(this.type, this.value);

  bool get isFlat => type == 'flat';

  /// Human-readable, e.g. "$0.20" or "1%".
  String get label => isFlat ? '\$${(value / 100).toStringAsFixed(2)}' : '${_trim(value)}%';

  static FeeSetting? fromJson(dynamic j) {
    if (j is! Map<String, dynamic>) return null;
    return FeeSetting(j['type'] as String? ?? 'flat', (j['value'] as num?)?.toDouble() ?? 0);
  }
}

String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// One payment method with its ON/OFF switch and current rate, fee and
/// withdrawal limits.
class MethodSettings {
  final String method;
  final String label;
  final String kind; // 'mobile_money' | 'platform'
  final bool enabled;
  final double? depositRate;
  final double? withdrawRate;
  final FeeSetting? depositFee;
  final FeeSetting? withdrawFee;
  final String? minWithdraw;
  final String? maxWithdraw;

  /// Payment Location customers see on Complete Deposit (1XBET, 888STARZ).
  final String? paymentCity;
  final String? paymentStreet;

  /// Merchant code customers dial for a deposit ('{amount}' is filled in),
  /// shown to them only while [merchantUssdEnabled].
  final String? merchantUssd;
  final bool merchantUssdEnabled;

  const MethodSettings({
    required this.method,
    required this.label,
    required this.kind,
    required this.enabled,
    this.depositRate,
    this.withdrawRate,
    this.depositFee,
    this.withdrawFee,
    this.minWithdraw,
    this.maxWithdraw,
    this.paymentCity,
    this.paymentStreet,
    this.merchantUssd,
    this.merchantUssdEnabled = false,
  });

  bool get isPlatform => kind == 'platform';

  /// Cash-desk companies, where the customer makes a payment code.
  bool get hasPaymentLocation => const {'onexbet', '888starz', 'winwin', 'betwinner', 'dbbet', 'betjam', 'betongame', 'melbet'}.contains(method);

  factory MethodSettings.fromJson(Map<String, dynamic> j) => MethodSettings(
        method: j['method'] as String,
        label: j['label'] as String? ?? j['method'] as String,
        kind: j['kind'] as String? ?? 'mobile_money',
        enabled: j['enabled'] as bool? ?? true,
        depositRate: (j['depositRate'] as num?)?.toDouble(),
        withdrawRate: (j['withdrawRate'] as num?)?.toDouble(),
        depositFee: FeeSetting.fromJson(j['depositFee']),
        withdrawFee: FeeSetting.fromJson(j['withdrawFee']),
        minWithdraw: j['minWithdraw'] as String?,
        maxWithdraw: j['maxWithdraw'] as String?,
        paymentCity: (j['paymentLocation'] as Map<String, dynamic>?)?['city'] as String?,
        paymentStreet: (j['paymentLocation'] as Map<String, dynamic>?)?['street'] as String?,
        merchantUssd: j['merchantUssd'] as String?,
        merchantUssdEnabled: j['merchantUssdEnabled'] as bool? ?? false,
      );
}

class AgentListItem {
  final String id;
  final String name;
  final String? phone;
  final String status; // 'active' | 'disabled'
  final List<String> responsibilities;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final DateTime? lastLoginAt;

  /// Active with Manage settings (or an admin): can manage everything.
  final bool fullAdmin;

  const AgentListItem({
    required this.id,
    required this.name,
    this.phone,
    required this.status,
    required this.responsibilities,
    this.createdAt,
    this.lastSeenAt,
    this.lastLoginAt,
    this.fullAdmin = false,
  });

  bool get isActive => status == 'active';
  bool get canManage => responsibilities.contains('manage_settings');

  factory AgentListItem.fromJson(Map<String, dynamic> j) => AgentListItem(
        id: j['id'] as String,
        name: j['name'] as String? ?? '—',
        phone: j['phone'] as String?,
        status: j['status'] as String? ?? 'active',
        responsibilities: (j['responsibilities'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
        createdAt: _date(j['created_at']),
        lastSeenAt: _date(j['last_seen_at']),
        lastLoginAt: _date(j['last_login_at']),
        fullAdmin: j['full_admin'] as bool? ?? false,
      );
}

/// A login or a security change of an agent account (admin_login_history).
class LoginEvent {
  final String action;
  final DateTime createdAt;
  final String? actorName;
  final String? userName;

  const LoginEvent({required this.action, required this.createdAt, this.actorName, this.userName});

  String get label => switch (action) {
        'user.login' => 'Logged in',
        'user.change_password' => 'Changed own password',
        'agent.reset_password' => 'Password reset',
        'agent.create' => 'Account created',
        'agent.update' => 'Details edited',
        'agent.enable' => 'Enabled',
        'agent.disable' => 'Disabled',
        'agent.delete' => 'Deleted',
        'agent.update_responsibilities' => 'Responsibilities changed',
        _ => action,
      };

  factory LoginEvent.fromJson(Map<String, dynamic> j) => LoginEvent(
        action: j['action'] as String? ?? '',
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
        actorName: j['actorName'] as String?,
        userName: j['userName'] as String?,
      );
}

/// One agent's work over a period (admin_agent_performance).
class AgentPerformance {
  final String id;
  final String name;
  final String status;
  final int deposits;
  final String depositAmount;
  final int withdrawals;
  final String withdrawalAmount;
  final int failed;
  final int adjustments;

  const AgentPerformance({
    required this.id,
    required this.name,
    required this.status,
    required this.deposits,
    required this.depositAmount,
    required this.withdrawals,
    required this.withdrawalAmount,
    required this.failed,
    required this.adjustments,
  });

  factory AgentPerformance.fromJson(Map<String, dynamic> j) => AgentPerformance(
        id: j['id'] as String,
        name: j['name'] as String? ?? '—',
        status: j['status'] as String? ?? 'active',
        deposits: (j['deposits'] as num?)?.toInt() ?? 0,
        depositAmount: j['depositAmount'] as String? ?? '0.00',
        withdrawals: (j['withdrawals'] as num?)?.toInt() ?? 0,
        withdrawalAmount: j['withdrawalAmount'] as String? ?? '0.00',
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        adjustments: (j['adjustments'] as num?)?.toInt() ?? 0,
      );
}

class AgentDevice {
  final String deviceId;
  final String? label;
  final String status;
  final DateTime? registeredAt;
  final DateTime? lastSeenAt;

  const AgentDevice({required this.deviceId, this.label, required this.status, this.registeredAt, this.lastSeenAt});

  factory AgentDevice.fromJson(Map<String, dynamic> j) => AgentDevice(
        deviceId: j['device_id'] as String? ?? '',
        label: j['device_label'] as String?,
        status: j['status'] as String? ?? '',
        registeredAt: _date(j['registered_at']),
        lastSeenAt: _date(j['last_seen_at']),
      );
}

class PaymentIntegration {
  final String provider; // 'evc_plus' | 'mobcash_winwin'
  final String status; // 'active' | 'inactive'
  final bool hasCredentials;
  final String? username;
  final DateTime? lastTestAt;
  final String? lastTestResult;
  final String? lastTestMessage;
  final DateTime? lastSuccessfulConnectionAt;
  final DateTime? lastTransactionAt;
  final String automationMode; // 'manual' | 'automatic'
  final bool dryRun;
  final int consecutiveFailures;
  final DateTime? circuitBreakerTrippedAt;
  final String? circuitBreakerReason;

  const PaymentIntegration({
    required this.provider,
    required this.status,
    required this.hasCredentials,
    this.username,
    this.lastTestAt,
    this.lastTestResult,
    this.lastTestMessage,
    this.lastSuccessfulConnectionAt,
    this.lastTransactionAt,
    required this.automationMode,
    required this.dryRun,
    required this.consecutiveFailures,
    this.circuitBreakerTrippedAt,
    this.circuitBreakerReason,
  });

  bool get isActive => status == 'active';
  bool get isMobCash => provider == 'mobcash_winwin';
  String get label => isMobCash ? 'MobCash / WinWin' : 'EVC Plus';

  factory PaymentIntegration.fromJson(Map<String, dynamic> j) => PaymentIntegration(
        provider: j['provider'] as String,
        status: j['status'] as String? ?? 'inactive',
        hasCredentials: j['hasCredentials'] as bool? ?? false,
        username: j['username'] as String?,
        lastTestAt: _date(j['lastTestAt']),
        lastTestResult: j['lastTestResult'] as String?,
        lastTestMessage: j['lastTestMessage'] as String?,
        lastSuccessfulConnectionAt: _date(j['lastSuccessfulConnectionAt']),
        lastTransactionAt: _date(j['lastTransactionAt']),
        automationMode: j['automationMode'] as String? ?? 'manual',
        dryRun: j['dryRun'] as bool? ?? true,
        consecutiveFailures: j['consecutiveFailures'] as int? ?? 0,
        circuitBreakerTrippedAt: _date(j['circuitBreakerTrippedAt']),
        circuitBreakerReason: j['circuitBreakerReason'] as String?,
      );
}

class AutomationRun {
  final String id;
  final String runType;
  final String? orderId;
  final String status; // success | failed | dry_run
  final String? message;
  final bool hasScreenshot;
  final DateTime? finishedAt;

  const AutomationRun({
    required this.id,
    required this.runType,
    this.orderId,
    required this.status,
    this.message,
    required this.hasScreenshot,
    this.finishedAt,
  });

  factory AutomationRun.fromJson(Map<String, dynamic> j) => AutomationRun(
        id: j['id'] as String,
        runType: j['run_type'] as String? ?? '',
        orderId: j['order_id'] as String?,
        status: j['status'] as String? ?? '',
        message: j['message'] as String?,
        hasScreenshot: j['has_screenshot'] as bool? ?? false,
        finishedAt: _date(j['finished_at']),
      );
}

class MobCashLoginCheck {
  final bool success;
  final String message;
  final List<String> eposList;
  const MobCashLoginCheck(this.success, this.message, this.eposList);

  factory MobCashLoginCheck.fromJson(Map<String, dynamic> j) => MobCashLoginCheck(
        j['success'] as bool? ?? false,
        j['message'] as String? ?? '',
        (j['eposList'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      );
}

class AuditLog {
  final String id;
  final String? actorId;
  final String? actorRole;
  final String action;
  final String entityType;
  final String? entityId;
  final dynamic before;
  final dynamic after;
  final DateTime createdAt;

  const AuditLog({
    required this.id,
    this.actorId,
    this.actorRole,
    required this.action,
    required this.entityType,
    this.entityId,
    this.before,
    this.after,
    required this.createdAt,
  });

  factory AuditLog.fromJson(Map<String, dynamic> j) => AuditLog(
        id: j['id'] as String,
        actorId: j['actor_id'] as String?,
        actorRole: j['actor_role'] as String?,
        action: j['action'] as String? ?? '',
        entityType: j['entity_type'] as String? ?? '',
        entityId: j['entity_id'] as String?,
        before: j['before_json'],
        after: j['after_json'],
        createdAt: _date(j['created_at']) ?? DateTime.now(),
      );
}

/// One wallet ledger entry from GET /admin/transactions (any customer).
class WalletTransaction {
  final String id;
  final String customerId;
  final String? orderId;
  final String type; // credit | debit | reserve | release
  final String amount;
  final String balanceAfter;
  final String reason;
  final DateTime createdAt;

  const WalletTransaction({
    required this.id,
    required this.customerId,
    this.orderId,
    required this.type,
    required this.amount,
    required this.balanceAfter,
    required this.reason,
    required this.createdAt,
  });

  factory WalletTransaction.fromJson(Map<String, dynamic> j) => WalletTransaction(
        id: j['id'] as String,
        customerId: j['customerId'] as String? ?? '',
        orderId: j['orderId'] as String?,
        type: j['type'] as String? ?? '',
        amount: (j['amount'] ?? '0.00').toString(),
        balanceAfter: (j['balanceAfter'] ?? '0.00').toString(),
        reason: j['reason'] as String? ?? '',
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
      );
}

/// Whether this manager's Telegram account is linked to the Telegram
/// cashier bot.
class TelegramLink {
  final bool linked;
  final String? telegramUsername;
  final DateTime? linkedAt;
  const TelegramLink({this.linked = false, this.telegramUsername, this.linkedAt});

  factory TelegramLink.fromJson(Map<String, dynamic> j) => TelegramLink(
        linked: j['linked'] as bool? ?? false,
        telegramUsername: j['telegramUsername'] as String?,
        linkedAt: _date(j['linkedAt']),
      );
}

/// One-time code sent to the bot as `/link CODE`.
class TelegramLinkCode {
  final String code;
  final DateTime? expiresAt;
  const TelegramLinkCode(this.code, this.expiresAt);

  factory TelegramLinkCode.fromJson(Map<String, dynamic> j) =>
      TelegramLinkCode(j['code'] as String? ?? '', _date(j['expiresAt']));
}

/// The Sahal merchant transaction feed (read-only for now).
class MerchantFeedStatus {
  /// ready | ok | stopped | not_configured | needs_code | code_entered
  final String state;
  final String? message;
  final DateTime? lastOkAt;
  final DateTime? codeAskedAt;
  final int rowsSeen;

  /// Whether matching payments credit customers' deposits.
  final bool creditOn;
  final int creditedToday;
  /// Merchant payments of the last 24 hours with no deposit to credit.
  final int unmatchedToday;

  /// Whether withdrawals sent from Sahal complete themselves.
  final bool payoutsOn;
  final int payoutsCompletedToday;

  const MerchantFeedStatus({
    required this.state,
    this.message,
    this.lastOkAt,
    this.codeAskedAt,
    this.rowsSeen = 0,
    this.creditOn = false,
    this.creditedToday = 0,
    this.unmatchedToday = 0,
    this.payoutsOn = false,
    this.payoutsCompletedToday = 0,
  });

  bool get needsCode => state == 'needs_code';
  bool get working => state == 'ok';

  factory MerchantFeedStatus.fromJson(Map<String, dynamic> j) => MerchantFeedStatus(
        state: j['state'] as String? ?? 'ready',
        message: j['message'] as String?,
        lastOkAt: DateTime.tryParse(j['lastOkAt'] as String? ?? '')?.toLocal(),
        codeAskedAt: DateTime.tryParse(j['codeAskedAt'] as String? ?? '')?.toLocal(),
        rowsSeen: (j['rowsSeen'] as num?)?.toInt() ?? 0,
        creditOn: j['creditOn'] as bool? ?? false,
        creditedToday: (j['creditedToday'] as num?)?.toInt() ?? 0,
        unmatchedToday: (j['unmatchedToday'] as num?)?.toInt() ?? 0,
        payoutsOn: j['payoutsOn'] as bool? ?? false,
        payoutsCompletedToday: (j['payoutsCompletedToday'] as num?)?.toInt() ?? 0,
      );
}

/// The Sahal merchant account, its connection and its session
/// (manage_sahal_account_status). It never carries a password, PIN, session
/// id or code: the server does not send them.
class SahalAccountStatus {
  /// connected | authentication_required | disconnected
  final String connection;
  final String? feedMessage;
  final DateTime? lastReadAt;

  /// 'environment' (the server's settings, until an account is activated
  /// here) or 'database' (an account activated in this app).
  final String source;
  final String? activeUsername;
  final DateTime? activatedAt;

  final SahalPendingAccount? pending;

  final bool sessionActive;
  final DateTime? sessionStartedAt;
  final int? sessionAgeSeconds;
  final DateTime? lastRenewalAt;
  final DateTime? lastLoginAt;

  final int openDeposits;
  final int openWithdrawals;
  final int transfersInFlight;
  final int transfersHeld;
  final bool renewIdle;

  const SahalAccountStatus({
    required this.connection,
    this.feedMessage,
    this.lastReadAt,
    this.source = 'environment',
    this.activeUsername,
    this.activatedAt,
    this.pending,
    this.sessionActive = false,
    this.sessionStartedAt,
    this.sessionAgeSeconds,
    this.lastRenewalAt,
    this.lastLoginAt,
    this.openDeposits = 0,
    this.openWithdrawals = 0,
    this.transfersInFlight = 0,
    this.transfersHeld = 0,
    this.renewIdle = true,
  });

  bool get connected => connection == 'connected';

  factory SahalAccountStatus.fromJson(Map<String, dynamic> j) {
    DateTime? time(Object? v) => DateTime.tryParse(v as String? ?? '')?.toLocal();
    final active = j['active'] as Map<String, dynamic>?;
    final session = (j['session'] as Map<String, dynamic>?) ?? const {};
    final open = (j['open'] as Map<String, dynamic>?) ?? const {};
    final pending = j['pending'] as Map<String, dynamic>?;
    return SahalAccountStatus(
      connection: j['connection'] as String? ?? 'disconnected',
      feedMessage: j['feedMessage'] as String?,
      lastReadAt: time(j['lastReadAt']),
      source: j['source'] as String? ?? 'environment',
      activeUsername: active?['username'] as String?,
      activatedAt: time(active?['activatedAt']),
      pending: pending == null ? null : SahalPendingAccount.fromJson(pending),
      sessionActive: session['active'] as bool? ?? false,
      sessionStartedAt: time(session['startedAt']),
      sessionAgeSeconds: (session['ageSeconds'] as num?)?.toInt(),
      lastRenewalAt: time(session['lastRenewalAt']),
      lastLoginAt: time(session['lastLoginAt']),
      openDeposits: (open['deposits'] as num?)?.toInt() ?? 0,
      openWithdrawals: (open['withdrawals'] as num?)?.toInt() ?? 0,
      transfersInFlight: (open['transfersInFlight'] as num?)?.toInt() ?? 0,
      transfersHeld: (open['transfersHeld'] as num?)?.toInt() ?? 0,
      renewIdle: j['renewIdle'] as bool? ?? true,
    );
  }
}

/// A new login saved but not yet active.
class SahalPendingAccount {
  final String username;
  final bool hasPin;

  /// draft | testing | logging_in | needs_code | code_entered | verified | failed
  final String status;
  final String? message;
  final DateTime? verifiedAt;

  const SahalPendingAccount({
    required this.username,
    this.hasPin = false,
    required this.status,
    this.message,
    this.verifiedAt,
  });

  bool get verified => status == 'verified';
  bool get needsCode => status == 'needs_code';
  bool get busy => const {'testing', 'logging_in', 'code_entered'}.contains(status);

  factory SahalPendingAccount.fromJson(Map<String, dynamic> j) => SahalPendingAccount(
        username: j['username'] as String? ?? '',
        hasPin: j['hasPin'] as bool? ?? false,
        status: j['status'] as String? ?? 'draft',
        message: j['message'] as String?,
        verifiedAt: DateTime.tryParse(j['verifiedAt'] as String? ?? '')?.toLocal(),
      );
}

/// A field a betting platform's adapter needs (manage_betting_platforms).
class BettingField {
  final String key;
  final String label;
  final bool required;
  final bool secret;

  const BettingField({required this.key, required this.label, required this.required, required this.secret});

  factory BettingField.fromJson(Map<String, dynamic> j) => BettingField(
        key: j['key'] as String,
        label: j['label'] as String? ?? j['key'] as String,
        required: j['required'] as bool? ?? false,
        secret: j['secret'] as bool? ?? false,
      );
}

/// An API the server can drive (only these can be automated).
class BettingAdapter {
  final String adapter;
  final String label;
  final String? defaultApiUrl;
  final List<BettingField> fields;

  const BettingAdapter({required this.adapter, required this.label, this.defaultApiUrl, required this.fields});

  factory BettingAdapter.fromJson(Map<String, dynamic> j) => BettingAdapter(
        adapter: j['adapter'] as String,
        label: j['label'] as String? ?? j['adapter'] as String,
        defaultApiUrl: j['defaultApiUrl'] as String?,
        fields: [for (final f in (j['fields'] as List? ?? const [])) BettingField.fromJson(f as Map<String, dynamic>)],
      );
}

/// A betting platform and its connection. Secrets never come back: only
/// whether one is saved, and the login masked.
class BettingPlatform {
  final String method;
  final String name;
  final String adapter;
  final bool builtIn;
  final bool active;

  /// 'connected', 'error', 'not_tested', 'not_configured', or 'server'
  /// (a built-in platform still on its Edge Function secrets).
  final String status;
  final String? apiUrl;
  final String? accountId;
  final String? login;
  final bool hasPassword;
  final bool hasApiSecret;
  final bool hasApiKey;
  final DateTime? lastTestAt;
  final DateTime? lastOkAt;
  final String? lastMessage;
  final String? updatedBy;

  const BettingPlatform({
    required this.method,
    required this.name,
    required this.adapter,
    required this.builtIn,
    required this.active,
    required this.status,
    this.apiUrl,
    this.accountId,
    this.login,
    this.hasPassword = false,
    this.hasApiSecret = false,
    this.hasApiKey = false,
    this.lastTestAt,
    this.lastOkAt,
    this.lastMessage,
    this.updatedBy,
  });

  bool get connected => status == 'connected';

  String get statusLabel => switch (status) {
        'connected' => 'Connected',
        'error' => 'Error',
        'not_tested' => 'Not tested',
        'server' => 'Server secrets',
        _ => 'Not set up',
      };

  factory BettingPlatform.fromJson(Map<String, dynamic> j) => BettingPlatform(
        method: j['method'] as String,
        name: j['name'] as String? ?? j['method'] as String,
        adapter: j['adapter'] as String? ?? 'cashdeskbot',
        builtIn: j['builtIn'] as bool? ?? false,
        active: j['active'] as bool? ?? false,
        status: j['status'] as String? ?? 'not_configured',
        apiUrl: j['apiUrl'] as String?,
        accountId: j['accountId'] as String?,
        login: j['login'] as String?,
        hasPassword: j['hasPassword'] as bool? ?? false,
        hasApiSecret: j['hasApiSecret'] as bool? ?? false,
        hasApiKey: j['hasApiKey'] as bool? ?? false,
        lastTestAt: _date(j['lastTestAt']),
        lastOkAt: _date(j['lastOkAt']),
        lastMessage: j['lastMessage'] as String?,
        updatedBy: j['updatedBy'] as String?,
      );
}
