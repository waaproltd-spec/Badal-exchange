/// One exchange direction (EVC Plus -> eDahab or eDahab -> EVC Plus).
class ExchangeOption {
  final String id;
  final String fromMethod;
  final String toMethod;
  final String fromLabel;
  final String toLabel;
  final double rate;
  final String feeType;
  final String feeValue;
  final String? minAmount;
  final String? maxAmount;

  const ExchangeOption({
    required this.id,
    required this.fromMethod,
    required this.toMethod,
    required this.fromLabel,
    required this.toLabel,
    required this.rate,
    required this.feeType,
    required this.feeValue,
    this.minAmount,
    this.maxAmount,
  });

  String get feeText => feeType == 'percentage' ? '$feeValue%' : '\$$feeValue';

  factory ExchangeOption.fromJson(Map<String, dynamic> j) => ExchangeOption(
        id: j['id'] as String,
        fromMethod: j['fromMethod'] as String,
        toMethod: j['toMethod'] as String,
        fromLabel: j['fromLabel'] as String? ?? j['fromMethod'] as String,
        toLabel: j['toLabel'] as String? ?? j['toMethod'] as String,
        rate: (j['rate'] as num?)?.toDouble() ?? 1,
        feeType: j['feeType'] as String? ?? 'fixed',
        feeValue: j['feeValue']?.toString() ?? '0',
        minAmount: j['minAmount'] as String?,
        maxAmount: j['maxAmount'] as String?,
      );
}

class ExchangeQuote {
  final String amountSent;
  final double rate;
  final String fee;
  final String amountReceived;

  const ExchangeQuote({required this.amountSent, required this.rate, required this.fee, required this.amountReceived});

  factory ExchangeQuote.fromJson(Map<String, dynamic> j) => ExchangeQuote(
        amountSent: j['amountSent']?.toString() ?? '0',
        rate: (j['rate'] as num?)?.toDouble() ?? 1,
        fee: j['fee']?.toString() ?? '0',
        amountReceived: j['amountReceived']?.toString() ?? '0',
      );
}

class ExchangeOrder {
  final String id;
  final String fromMethod;
  final String toMethod;
  final String fromLabel;
  final String toLabel;
  final String amountSent;
  final String fee;
  final String amountReceived;
  final String senderPhone;
  final String receiverPhone;
  final String? collectionPhoneNumber;
  final String? collectionUssd;

  /// pending | in_progress | completed | failed | cancelled
  final String status;
  final String statusMessage;
  final String? failureReason;
  final DateTime createdAt;
  final DateTime? completedAt;

  const ExchangeOrder({
    required this.id,
    required this.fromMethod,
    required this.toMethod,
    required this.fromLabel,
    required this.toLabel,
    required this.amountSent,
    required this.fee,
    required this.amountReceived,
    required this.senderPhone,
    required this.receiverPhone,
    this.collectionPhoneNumber,
    this.collectionUssd,
    required this.status,
    required this.statusMessage,
    this.failureReason,
    required this.createdAt,
    this.completedAt,
  });

  bool get isFinal => status == 'completed' || status == 'cancelled';

  factory ExchangeOrder.fromJson(Map<String, dynamic> j) => ExchangeOrder(
        id: j['id'] as String,
        fromMethod: j['fromMethod'] as String? ?? '',
        toMethod: j['toMethod'] as String? ?? '',
        fromLabel: j['fromLabel'] as String? ?? '',
        toLabel: j['toLabel'] as String? ?? '',
        amountSent: j['amountSent']?.toString() ?? '0',
        fee: j['fee']?.toString() ?? '0',
        amountReceived: j['amountReceived']?.toString() ?? '0',
        senderPhone: j['senderPhone'] as String? ?? '',
        receiverPhone: j['receiverPhone'] as String? ?? '',
        collectionPhoneNumber: j['collectionPhoneNumber'] as String?,
        collectionUssd: j['collectionUssd'] as String?,
        status: j['status'] as String? ?? 'pending',
        statusMessage: j['statusMessage'] as String? ?? '',
        failureReason: j['failureReason'] as String?,
        createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
        completedAt: DateTime.tryParse(j['completedAt']?.toString() ?? '')?.toLocal(),
      );
}
