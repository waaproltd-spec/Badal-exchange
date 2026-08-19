/// Pure, unit-testable parsing logic for authorized EVC Plus (Hormuud)
/// payment-notification SMS messages.
///
/// IMPORTANT — this file intentionally has *no* Flutter/platform-channel
/// dependency: it is a pure Dart function of `(sender, body, receivedAt) ->
/// ParsedEvcSmsTransaction?` so it can be exercised by plain `dart test`
/// (see test/evc_sms_parser_test.dart) even in environments (like this one)
/// without the Flutter SDK installed.
///
/// ASSUMPTION THAT NEEDS CONFIRMATION BEFORE PRODUCTION USE:
/// The exact EVC Plus/Hormuud SMS sender ID and message wording were not
/// provided as part of this task. [EvcSmsConfig.allowedSenderIds] and the
/// wording-driven regexes below are a best-effort guess at a typical
/// "you have received money" mobile money notification format. Before
/// shipping, capture a handful of REAL EVC Plus deposit-notification SMS
/// messages on a test device/number and adjust [EvcSmsConfig] and the
/// regexes in this file to match them exactly. Until then, treat this
/// parser as a scaffold, not a verified integration.
library;

/// Configuration for which SMS senders/patterns this app treats as
/// authorized EVC Plus payment notifications. Kept as simple constants
/// (rather than hard-coded inline) specifically so this can be tuned once a
/// real sample SMS is available, without touching the parsing logic itself.
class EvcSmsConfig {
  EvcSmsConfig._();

  /// Known/likely sender IDs (the SMS "address") for Hormuud EVC Plus
  /// payment notifications. Matching is case-insensitive and allows the
  /// sender field to simply *contain* one of these tokens, since carriers
  /// sometimes prefix/suffix the registered sender ID.
  ///
  /// TODO(confirm-with-telco): replace/extend with the real sender ID(s)
  /// observed on a test device before production rollout.
  static const List<String> allowedSenderIds = <String>[
    'EVCPLUS',
    'EVC PLUS',
    'Hormuud',
    'EVC',
  ];

  /// The message must contain at least one of these (case-insensitive) to
  /// be considered a *payment received* notification, as opposed to some
  /// other EVC Plus SMS (balance alerts, marketing, OTPs, etc.) which must
  /// be ignored.
  static const List<String> receivedKeywords = <String>[
    'you have received',
    'received a payment',
    'payment received',
    'ma correjisay',
    'waxaad heshay',
  ];

  /// The provider label sent to POST /agent/sms-transactions.
  static const String providerLabel = 'evc_plus';
}

/// The minimal set of facts extracted from an authorized payment SMS.
/// Deliberately does NOT retain the raw SMS body — only these fields are
/// ever submitted to the backend.
class ParsedEvcSmsTransaction {
  final String senderPhoneNumber;
  final String amount; // decimal string, e.g. "25.00"
  final String transactionRef;
  final DateTime occurredAt;
  final String provider;

  const ParsedEvcSmsTransaction({
    required this.senderPhoneNumber,
    required this.amount,
    required this.transactionRef,
    required this.occurredAt,
    this.provider = EvcSmsConfig.providerLabel,
  });

  @override
  String toString() =>
      'ParsedEvcSmsTransaction(sender: $senderPhoneNumber, amount: $amount, ref: $transactionRef, occurredAt: $occurredAt)';
}

class EvcSmsParser {
  EvcSmsParser._();

  // Somali mobile numbers: either international `252XXXXXXXXX` (9 digits
  // after the country code) or local `0XXXXXXXX`. Allow optional `+`.
  static final RegExp _phoneRegex = RegExp(r'(?:\+?252\d{8,9}|0\d{8,9})');

  // Amount: an optional currency marker, digits with optional thousands
  // separators, optional decimal part. Matches "$25.00", "25.00 USD",
  // "SOS 25,000", "25" etc. The first plausible amount in the message wins.
  static final RegExp _amountRegex = RegExp(
    r'(?:USD|SOS|SL|\$)?\s*([0-9]{1,3}(?:[,.][0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)\s*(?:USD|SOS|SL|\$)?',
    caseSensitive: false,
  );

  // Transaction / reference id: commonly labeled "Trx ID", "Txn ID",
  // "Reference", "Ref", "Transaction ID" followed by an alphanumeric code.
  static final RegExp _refRegex = RegExp(
    r'(?:Trx(?:action)?\s*ID|Transaction\s*ID|Txn\s*ID|Reference|Ref(?:erence)?\s*(?:No\.?|Number)?|Ref)\s*[:#\-]?\s*([A-Za-z0-9]{5,25})',
    caseSensitive: false,
  );

  /// Returns true if [senderAddress] looks like a known EVC Plus sender ID.
  static bool isAuthorizedSender(String senderAddress) {
    final normalized = senderAddress.trim().toUpperCase();
    return EvcSmsConfig.allowedSenderIds.any((id) => normalized.contains(id.toUpperCase()));
  }

  static bool _looksLikePaymentReceived(String body) {
    final normalized = body.toLowerCase();
    return EvcSmsConfig.receivedKeywords.any((kw) => normalized.contains(kw.toLowerCase()));
  }

  /// Attempts to parse [body] (the SMS text) sent from [senderAddress],
  /// received at [receivedAt] (device-local receive time, used as the
  /// transaction timestamp when the message itself has none).
  ///
  /// Returns null when:
  ///  - the sender is not a recognized EVC Plus sender id, OR
  ///  - the message doesn't look like a "payment received" notification, OR
  ///  - any of the three required fields (phone, amount, reference) could
  ///    not be extracted.
  ///
  /// This function never returns the raw SMS body — callers must not
  /// forward [body] anywhere beyond this call.
  static ParsedEvcSmsTransaction? parse(
    String senderAddress,
    String body, {
    required DateTime receivedAt,
  }) {
    if (!isAuthorizedSender(senderAddress)) return null;
    if (!_looksLikePaymentReceived(body)) return null;

    final phoneMatch = _phoneRegex.firstMatch(body);
    if (phoneMatch == null) return null;
    final rawPhone = phoneMatch.group(0)!;
    final senderPhoneNumber = _normalizePhone(rawPhone);

    final refMatch = _refRegex.firstMatch(body);
    if (refMatch == null || refMatch.group(1) == null) return null;
    final transactionRef = refMatch.group(1)!.trim();

    // Exclude the character ranges already claimed by the phone number and
    // reference code so a currency-less fallback amount match can't
    // accidentally grab a substring of either of those.
    final excludedRanges = <_Range>[
      _Range(phoneMatch.start, phoneMatch.end),
      _Range(refMatch.start, refMatch.end),
    ];

    final amount = _extractAmount(body, excludedRanges);
    if (amount == null) return null;

    return ParsedEvcSmsTransaction(
      senderPhoneNumber: senderPhoneNumber,
      amount: amount,
      transactionRef: transactionRef,
      occurredAt: receivedAt,
    );
  }

  /// Normalizes a Somali phone number to the `252XXXXXXXXX` form the
  /// backend expects (orders are stored with this format — see
  /// backend seed/customer registration).
  static String _normalizePhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('0')) {
      digits = '252${digits.substring(1)}';
    }
    if (!digits.startsWith('252') && digits.length <= 9) {
      digits = '252$digits';
    }
    return digits;
  }

  /// Finds the amount mentioned near a currency marker, falling back to the
  /// first standalone number in the message that doesn't overlap with
  /// [excludedRanges] (used to keep the phone number / reference code from
  /// being misread as an amount). Normalizes to a plain decimal string (no
  /// thousands separators) with up to 2 decimal places.
  static String? _extractAmount(String body, List<_Range> excludedRanges) {
    // Prefer amounts explicitly tagged with a currency marker — these are
    // unambiguous even if they happen to sit inside an excluded range.
    final currencyRegex = RegExp(
      r'(?:USD|SOS|SL|\$)\s*([0-9]+(?:[,][0-9]{3})*(?:\.[0-9]{1,2})?)',
      caseSensitive: false,
    );
    final currencyTagged = currencyRegex.firstMatch(body);
    if (currencyTagged != null) {
      return _toDecimalString(currencyTagged.group(1));
    }

    for (final match in _amountRegex.allMatches(body)) {
      final overlaps = excludedRanges.any((r) => r.overlaps(match.start, match.end));
      if (overlaps) continue;
      final value = _toDecimalString(match.group(1));
      if (value != null) return value;
    }
    return null;
  }

  static String? _toDecimalString(String? rawAmount) {
    if (rawAmount == null || rawAmount.isEmpty) return null;
    final cleaned = rawAmount.replaceAll(',', '');
    final value = double.tryParse(cleaned);
    if (value == null || value <= 0) return null;
    return value.toStringAsFixed(2);
  }
}

/// A half-open `[start, end)` character index range, used to keep amount
/// extraction from overlapping with the phone number / reference matches.
class _Range {
  final int start;
  final int end;
  const _Range(this.start, this.end);

  bool overlaps(int otherStart, int otherEnd) {
    return start < otherEnd && otherStart < end;
  }
}
