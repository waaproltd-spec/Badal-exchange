/// Exchange (EVC Plus <-> eDahab) orders, as returned by the exchange RPCs in
/// supabase/migrations/20261007000200_exchange_matching.sql.
class ExchangeOrder {
  final String id;
  final String fromMethod;
  final String toMethod;
  final String fromLabel;
  final String toLabel;
  final String amountSent;
  final double rate;
  final String fee;
  final String amountReceived;
  final String senderPhone;
  final String receiverPhone;
  final String? collectionPhoneNumber;
  final String? collectionUssd;

  /// pending | in_progress | completed | failed | cancelled
  final String status;
  final String statusMessage;
  final String? paymentReference;
  final DateTime? paymentVerifiedAt;
  final String? payoutReference;
  final String? failureReason;
  final DateTime createdAt;
  final DateTime? completedAt;

  // Agent payout queue only.
  final bool hasDialAttempt;
  final bool payoutRequested;
  final String? payoutDeviceId;
  final int? payoutSimSlot;
  final String? payoutPhoneNumber;
  final String? customerName;
  final String? customerPhone;

  // Manager detail only.
  final List<ExchangeDialAttempt> dialAttempts;
  final Map<String, dynamic>? paymentSms;
  final List<Map<String, dynamic>> history;

  const ExchangeOrder({
    required this.id,
    required this.fromMethod,
    required this.toMethod,
    required this.fromLabel,
    required this.toLabel,
    required this.amountSent,
    required this.rate,
    required this.fee,
    required this.amountReceived,
    required this.senderPhone,
    required this.receiverPhone,
    this.collectionPhoneNumber,
    this.collectionUssd,
    required this.status,
    required this.statusMessage,
    this.paymentReference,
    this.paymentVerifiedAt,
    this.payoutReference,
    this.failureReason,
    required this.createdAt,
    this.completedAt,
    this.hasDialAttempt = false,
    this.payoutRequested = false,
    this.payoutDeviceId,
    this.payoutSimSlot,
    this.payoutPhoneNumber,
    this.customerName,
    this.customerPhone,
    this.dialAttempts = const [],
    this.paymentSms,
    this.history = const [],
  });

  static DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

  factory ExchangeOrder.fromJson(Map<String, dynamic> j) => ExchangeOrder(
        id: j['id'] as String,
        fromMethod: j['fromMethod'] as String? ?? '',
        toMethod: j['toMethod'] as String? ?? '',
        fromLabel: j['fromLabel'] as String? ?? j['fromMethod'] as String? ?? '',
        toLabel: j['toLabel'] as String? ?? j['toMethod'] as String? ?? '',
        amountSent: j['amountSent']?.toString() ?? '0',
        rate: (j['rate'] as num?)?.toDouble() ?? 1,
        fee: j['fee']?.toString() ?? '0',
        amountReceived: j['amountReceived']?.toString() ?? '0',
        senderPhone: j['senderPhone'] as String? ?? '',
        receiverPhone: j['receiverPhone'] as String? ?? '',
        collectionPhoneNumber: j['collectionPhoneNumber'] as String?,
        collectionUssd: j['collectionUssd'] as String?,
        status: j['status'] as String? ?? 'pending',
        statusMessage: j['statusMessage'] as String? ?? '',
        paymentReference: j['paymentReference'] as String?,
        paymentVerifiedAt: _date(j['paymentVerifiedAt']),
        payoutReference: j['payoutReference'] as String?,
        failureReason: j['failureReason'] as String?,
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
        completedAt: _date(j['completedAt']),
        hasDialAttempt: j['hasDialAttempt'] as bool? ?? false,
        payoutRequested: j['payoutRequested'] as bool? ?? false,
        payoutDeviceId: j['payoutDeviceId'] as String?,
        payoutSimSlot: j['payoutSimSlot'] as int?,
        payoutPhoneNumber: j['payoutPhoneNumber'] as String?,
        customerName: j['customerName'] as String?,
        customerPhone: j['customerPhone'] as String?,
        dialAttempts: ((j['dialAttempts'] as List<dynamic>?) ?? const [])
            .map((e) => ExchangeDialAttempt.fromJson(e as Map<String, dynamic>))
            .toList(),
        paymentSms: j['paymentSms'] as Map<String, dynamic>?,
        history: ((j['history'] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>(),
      );
}

class ExchangeDialAttempt {
  final String id;
  final int attemptNumber;
  final String status;
  final String? step1Response;
  final String? step2Response;
  final DateTime? createdAt;

  const ExchangeDialAttempt({
    required this.id,
    required this.attemptNumber,
    required this.status,
    this.step1Response,
    this.step2Response,
    this.createdAt,
  });

  factory ExchangeDialAttempt.fromJson(Map<String, dynamic> j) => ExchangeDialAttempt(
        id: j['id'] as String,
        attemptNumber: j['attemptNumber'] as int? ?? 0,
        status: j['status'] as String? ?? '',
        step1Response: j['step1Response'] as String?,
        step2Response: j['step2Response'] as String?,
        createdAt: ExchangeOrder._date(j['createdAt']),
      );
}

/// Result of agent_exchange_start_dial. [pin] is present only for a new
/// attempt; an unfinished earlier attempt comes back without it.
class ExchangeDialStart {
  final String attemptId;
  final String ussd;
  final int simSlot;
  final bool isNew;
  final String? pin;

  const ExchangeDialStart({required this.attemptId, required this.ussd, required this.simSlot, required this.isNew, this.pin});

  factory ExchangeDialStart.fromJson(Map<String, dynamic> j) => ExchangeDialStart(
        attemptId: j['id'] as String,
        ussd: j['step1UssdString'] as String,
        simSlot: j['simSlot'] as int? ?? 1,
        isNew: j['isNew'] as bool? ?? false,
        pin: j['pin'] as String?,
      );
}

class ExchangeCorridor {
  final String id;
  final String fromMethod;
  final String toMethod;
  final double rate;
  final String feeType;
  final String feeValue;
  final String? minAmount;
  final String? maxAmount;
  final String? payoutWalletId;
  final bool enabled;

  const ExchangeCorridor({
    required this.id,
    required this.fromMethod,
    required this.toMethod,
    required this.rate,
    required this.feeType,
    required this.feeValue,
    this.minAmount,
    this.maxAmount,
    this.payoutWalletId,
    required this.enabled,
  });

  factory ExchangeCorridor.fromJson(Map<String, dynamic> j) => ExchangeCorridor(
        id: j['id'] as String,
        fromMethod: j['fromMethod'] as String,
        toMethod: j['toMethod'] as String,
        rate: (j['rate'] as num?)?.toDouble() ?? 1,
        feeType: j['feeType'] as String? ?? 'fixed',
        feeValue: j['feeValue']?.toString() ?? '0',
        minAmount: j['minAmount'] as String?,
        maxAmount: j['maxAmount'] as String?,
        payoutWalletId: j['payoutWalletId'] as String?,
        enabled: j['enabled'] as bool? ?? false,
      );
}

class ExchangePayoutWallet {
  final String id;
  final String method;
  final String phoneNumber;
  final String? deviceId;
  final int? simSlot;
  final bool hasPin;

  const ExchangePayoutWallet({
    required this.id,
    required this.method,
    required this.phoneNumber,
    this.deviceId,
    this.simSlot,
    required this.hasPin,
  });

  factory ExchangePayoutWallet.fromJson(Map<String, dynamic> j) => ExchangePayoutWallet(
        id: j['id'] as String,
        method: j['method'] as String,
        phoneNumber: j['phoneNumber'] as String? ?? '',
        deviceId: j['deviceId'] as String?,
        simSlot: j['simSlot'] as int?,
        hasPin: j['hasPin'] as bool? ?? false,
      );
}

class ExchangeSettings {
  final List<ExchangeCorridor> corridors;
  final List<ExchangePayoutWallet> payoutWallets;

  const ExchangeSettings({required this.corridors, required this.payoutWallets});

  factory ExchangeSettings.fromJson(Map<String, dynamic> j) => ExchangeSettings(
        corridors: ((j['corridors'] as List<dynamic>?) ?? const [])
            .map((e) => ExchangeCorridor.fromJson(e as Map<String, dynamic>))
            .toList(),
        payoutWallets: ((j['payoutWallets'] as List<dynamic>?) ?? const [])
            .map((e) => ExchangePayoutWallet.fromJson(e as Map<String, dynamic>))
            .toList(),
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
  final String? exchangeOrderId;
  final String? orderId;
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
    this.exchangeOrderId,
    this.orderId,
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
        receivedAt: ExchangeOrder._date(j['receivedAt']),
        matchStatus: j['matchStatus'] as String? ?? 'unmatched',
        exchangeOrderId: j['exchangeOrderId'] as String?,
        orderId: j['orderId'] as String?,
        reason: j['reason'] as String?,
      );
}
