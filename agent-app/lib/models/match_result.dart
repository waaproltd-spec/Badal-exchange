/// Result of POST /agent/sms-transactions or POST /agent/winwin-transactions.
///
/// The backend is the sole authority on whether a submitted payment matches
/// a pending order — this app never decides "verified" on its own, it only
/// reflects this response back to the agent.
enum MatchStatus { matched, unmatched, duplicate, error }

MatchStatus matchStatusFromString(String? value) {
  switch (value) {
    case 'matched':
      return MatchStatus.matched;
    case 'unmatched':
      return MatchStatus.unmatched;
    case 'duplicate':
      return MatchStatus.duplicate;
    default:
      return MatchStatus.error;
  }
}

class MatchResult {
  final MatchStatus status;
  final String? orderId;
  final String? errorMessage;

  const MatchResult({required this.status, this.orderId, this.errorMessage});

  factory MatchResult.fromJson(Map<String, dynamic> json) {
    return MatchResult(
      status: matchStatusFromString(json['status'] as String?),
      orderId: json['orderId'] as String?,
    );
  }

  factory MatchResult.error(String message) {
    return MatchResult(status: MatchStatus.error, errorMessage: message);
  }
}
