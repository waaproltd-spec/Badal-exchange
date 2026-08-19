import 'match_result.dart';

/// A local record of a submission this device has made to
/// POST /agent/sms-transactions (or a manual WinWin submission), together
/// with the result the backend returned.
///
/// There is no dedicated "list my sms transactions" GET endpoint on the
/// backend, so the SMS Transactions screen keeps its own simple local log
/// of what this device has submitted this session/installation. It stores
/// only the same minimal extracted fields that were sent to the server —
/// never the raw SMS text.
class SmsTransactionLog {
  final String id;
  final String provider;
  final String? sender;
  final String amount;
  final String transactionRef;
  final DateTime occurredAt;
  final DateTime submittedAt;
  final MatchStatus status;
  final String? orderId;
  final String? errorMessage;
  final bool isManualWinwin;

  const SmsTransactionLog({
    required this.id,
    required this.provider,
    this.sender,
    required this.amount,
    required this.transactionRef,
    required this.occurredAt,
    required this.submittedAt,
    required this.status,
    this.orderId,
    this.errorMessage,
    this.isManualWinwin = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider,
        'sender': sender,
        'amount': amount,
        'transactionRef': transactionRef,
        'occurredAt': occurredAt.toIso8601String(),
        'submittedAt': submittedAt.toIso8601String(),
        'status': status.name,
        'orderId': orderId,
        'errorMessage': errorMessage,
        'isManualWinwin': isManualWinwin,
      };

  factory SmsTransactionLog.fromJson(Map<String, dynamic> json) {
    return SmsTransactionLog(
      id: json['id'] as String,
      provider: json['provider'] as String? ?? '',
      sender: json['sender'] as String?,
      amount: json['amount'] as String? ?? '',
      transactionRef: json['transactionRef'] as String? ?? '',
      occurredAt: DateTime.tryParse(json['occurredAt']?.toString() ?? '') ?? DateTime.now(),
      submittedAt: DateTime.tryParse(json['submittedAt']?.toString() ?? '') ?? DateTime.now(),
      status: matchStatusFromString(json['status'] as String?),
      orderId: json['orderId'] as String?,
      errorMessage: json['errorMessage'] as String?,
      isManualWinwin: json['isManualWinwin'] as bool? ?? false,
    );
  }
}
