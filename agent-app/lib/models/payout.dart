/// Withdrawal payouts sent automatically from the agent phone, Baari's wallets
/// on that phone, and stored payment SMS (see
/// supabase/migrations/20261008000100_reseller_style_payments.sql).

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

/// A withdrawal as the payout engine sees it.
class PayoutOrder {
  final String id;
  final String orderCode;
  final String method;
  final String status;
  final String phoneNumber;
  final String amount;

  /// What the customer receives (the amount dialed).
  final String payoutAmount;

  /// A payout attempt reached the PIN step without a confirmed result.
  final bool payoutReview;
  final String? failureReason;
  final String? transactionRef;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? customerName;
  final String? customerPhone;
  final String? payoutDeviceId;
  final int? payoutSimSlot;
  final String? payoutWalletPhone;
  final bool hasDialAttempt;
  final bool payoutRequested;
  final List<PayoutAttempt> dialAttempts;
  final List<Map<String, dynamic>> history;

  const PayoutOrder({
    required this.id,
    required this.orderCode,
    required this.method,
    required this.status,
    required this.phoneNumber,
    required this.amount,
    required this.payoutAmount,
    required this.payoutReview,
    this.failureReason,
    this.transactionRef,
    required this.createdAt,
    this.completedAt,
    this.customerName,
    this.customerPhone,
    this.payoutDeviceId,
    this.payoutSimSlot,
    this.payoutWalletPhone,
    this.hasDialAttempt = false,
    this.payoutRequested = false,
    this.dialAttempts = const [],
    this.history = const [],
  });

  String get methodLabel => method == 'edahab' ? 'eDahab' : (method == 'evc_plus' ? 'EVC Plus' : method);

  factory PayoutOrder.fromJson(Map<String, dynamic> j) => PayoutOrder(
        id: j['id'] as String,
        orderCode: j['orderCode'] as String? ?? '',
        method: j['method'] as String? ?? '',
        status: j['status'] as String? ?? '',
        phoneNumber: j['phoneNumber'] as String? ?? '',
        amount: j['amount']?.toString() ?? '0',
        payoutAmount: j['payoutAmount']?.toString() ?? '0',
        payoutReview: j['payoutReview'] as bool? ?? false,
        failureReason: j['failureReason'] as String?,
        transactionRef: j['transactionRef'] as String?,
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
        completedAt: _date(j['completedAt']),
        customerName: j['customerName'] as String?,
        customerPhone: j['customerPhone'] as String?,
        payoutDeviceId: j['payoutDeviceId'] as String?,
        payoutSimSlot: j['payoutSimSlot'] as int?,
        payoutWalletPhone: j['payoutWalletPhone'] as String?,
        hasDialAttempt: j['hasDialAttempt'] as bool? ?? false,
        payoutRequested: j['payoutRequested'] as bool? ?? false,
        dialAttempts: ((j['dialAttempts'] as List<dynamic>?) ?? const [])
            .map((e) => PayoutAttempt.fromJson(e as Map<String, dynamic>))
            .toList(),
        history: ((j['history'] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>(),
      );
}

class PayoutAttempt {
  final String id;
  final int attemptNumber;
  final String status;
  final String? step1Response;
  final String? step2Response;
  final String? walletPhone;
  final DateTime? createdAt;

  const PayoutAttempt({
    required this.id,
    required this.attemptNumber,
    required this.status,
    this.step1Response,
    this.step2Response,
    this.walletPhone,
    this.createdAt,
  });

  factory PayoutAttempt.fromJson(Map<String, dynamic> j) => PayoutAttempt(
        id: j['id'] as String,
        attemptNumber: j['attemptNumber'] as int? ?? 0,
        status: j['status'] as String? ?? '',
        step1Response: j['step1Response'] as String?,
        step2Response: j['step2Response'] as String?,
        walletPhone: j['walletPhone'] as String?,
        createdAt: _date(j['createdAt']),
      );
}

/// Result of agent_payout_start_dial. [pin] is present only for a new
/// attempt; an unfinished earlier attempt comes back without it.
class PayoutDialStart {
  final String attemptId;
  final String ussd;
  final int simSlot;
  final bool isNew;
  final String? pin;

  const PayoutDialStart({required this.attemptId, required this.ussd, required this.simSlot, required this.isNew, this.pin});

  factory PayoutDialStart.fromJson(Map<String, dynamic> j) => PayoutDialStart(
        attemptId: j['id'] as String,
        ussd: j['step1UssdString'] as String,
        simSlot: j['simSlot'] as int? ?? 1,
        isNew: j['isNew'] as bool? ?? false,
        pin: j['pin'] as String?,
      );
}

/// One of Baari's EVC Plus / eDahab wallets on an agent phone.
class PayoutWallet {
  final String id;
  final String method;
  final String phoneNumber;
  final String? deviceId;
  final int? simSlot;
  final bool hasPin;

  /// This is the wallet the method's withdrawals are paid from.
  final bool paysWithdrawals;

  const PayoutWallet({
    required this.id,
    required this.method,
    required this.phoneNumber,
    this.deviceId,
    this.simSlot,
    required this.hasPin,
    this.paysWithdrawals = false,
  });

  String get methodLabel => method == 'edahab' ? 'eDahab' : 'EVC Plus';

  factory PayoutWallet.fromJson(Map<String, dynamic> j) => PayoutWallet(
        id: j['id'] as String,
        method: j['method'] as String,
        phoneNumber: j['phoneNumber'] as String? ?? '',
        deviceId: j['deviceId'] as String?,
        simSlot: j['simSlot'] as int?,
        hasPin: j['hasPin'] as bool? ?? false,
        paysWithdrawals: j['paysWithdrawals'] as bool? ?? false,
      );
}

/// One stored payment SMS (manager review).
class PaymentSmsLog {
  final String id;
  final String sender;
  final String body;
  final String? provider;
  final String? amount;
  final String? phone;
  final String? transactionRef;
  final DateTime? receivedAt;

  /// unmatched | matched | ambiguous | duplicate_blocked | ignored
  final String matchStatus;
  final String? orderId;
  final String? orderCode;
  final String? reason;

  const PaymentSmsLog({
    required this.id,
    required this.sender,
    required this.body,
    this.provider,
    this.amount,
    this.phone,
    this.transactionRef,
    this.receivedAt,
    required this.matchStatus,
    this.orderId,
    this.orderCode,
    this.reason,
  });

  factory PaymentSmsLog.fromJson(Map<String, dynamic> j) => PaymentSmsLog(
        id: j['id'] as String,
        sender: j['sender'] as String? ?? '',
        body: j['body'] as String? ?? '',
        provider: j['provider'] as String?,
        amount: j['amount'] as String?,
        phone: j['phone'] as String?,
        transactionRef: j['transactionRef'] as String?,
        receivedAt: _date(j['receivedAt']),
        matchStatus: j['matchStatus'] as String? ?? 'unmatched',
        orderId: j['orderId'] as String?,
        orderCode: j['orderCode'] as String?,
        reason: j['reason'] as String?,
      );
}
