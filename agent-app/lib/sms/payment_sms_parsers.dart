/// Payment SMS parsers, ported one-to-one from Dalab Internet's
/// agent-app/.../sms/PaymentSmsParsers.kt (same senders, same regexes, same
/// provider labels), so Baari recognizes exactly the carrier formats Dalab
/// has already confirmed against real SMS.
///
/// Pure Dart (no Flutter or platform channel), so it is unit tested directly
/// in test/payment_sms_parsers_test.dart.
library;

/// Amount capture group shared by every parser: an optional comma
/// thousands separator ("$1,234.56") or a plain decimal ("$0.09").
const String _amount = r'([\d,]+(?:\.\d+)?)';

/// "1,234.56" -> "1234.56". Returns null when it isn't a number.
String? _parseAmount(String raw) {
  final cleaned = raw.replaceAll(',', '');
  final value = double.tryParse(cleaned);
  if (value == null) return null;
  return cleaned;
}

bool _fromSender(List<String> senders, String sender) {
  final s = sender.trim().replaceFirst(RegExp(r'^\+'), '').toLowerCase();
  return senders.any((allowed) => allowed.toLowerCase() == s);
}

RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

/// A customer's incoming payment (Dalab SmsLogEntry's parsed fields).
class ParsedPaymentSms {
  const ParsedPaymentSms({
    required this.provider,
    required this.amount,
    required this.phone,
    this.transactionRef,
  });

  /// "Hormuud", "Somtel" or "Somnet" (Dalab's labels; the backend maps
  /// Hormuud/Somnet to EVC Plus and Somtel to eDahab).
  final String provider;
  final String amount;

  /// The payer's number as the carrier wrote it (0610346060, 252685115555,
  /// 620346060...). The backend compares the last 9 digits only.
  final String phone;

  /// The carrier's own reference when the format has one (eDahab's
  /// "Aqanoosiga"). Hormuud's format has none, so it is optional.
  final String? transactionRef;
}

/// The payout phone's own "you transferred $X to NUMBER" SMS (Dalab
/// ExchangePayoutConfirmedEntry).
class PayoutSentSms {
  const PayoutSentSms({
    required this.receiverPhone,
    required this.amount,
    required this.provider,
    required this.rawText,
    this.reference,
  });

  final String receiverPhone;
  final String amount;
  final String provider;
  final String rawText;
  final String? reference;
}

abstract class _PaymentParser {
  List<String> get senders;
  ParsedPaymentSms? tryParse(String sender, String body);
}

abstract class _PayoutSentParser {
  List<String> get senders;
  PayoutSentSms? tryParse(String sender, String body);
}

/// Hormuud EVC Plus.
/// "[-EVCPLUS-] waxaad $1 ka heshay 0610346060, Tar: 24/07/26"
/// Sender "192" or "EVCPLUS".
class HormuudEvcPlusParser implements _PaymentParser {
  const HormuudEvcPlusParser();

  @override
  List<String> get senders => const ['192', 'EVCPLUS'];

  static final _pattern = _re(r'waxaad\s+\$?\s*' + _amount + r'\s*\$?\s*ka\s+heshay\s+(\d{6,12}),?\s*Tar:\s*([\d/]+)');

  @override
  ParsedPaymentSms? tryParse(String sender, String body) {
    if (!_fromSender(senders, sender)) return null;
    final m = _pattern.firstMatch(body);
    if (m == null) return null;
    final amount = _parseAmount(m.group(1)!);
    if (amount == null) return null;
    return ParsedPaymentSms(provider: 'Hormuud', amount: amount, phone: m.group(2)!);
  }
}

/// Somtel eDahab. The payer's name comes first, the number is in the
/// "Lambarka" field; "Aqanoosiga" is the carrier's reference.
/// "0.22 Dollar Ayaad Ka Heshay Yaasiin Maxamed Aadan.Code-ka:NA.
///  Lambarka :620346060  Aqanoosiga : PP260718.0005.F75709 ...[-eDahab-Service-]"
/// Sender "eDahab".
class SomtelEdahabParser implements _PaymentParser {
  const SomtelEdahabParser();

  @override
  List<String> get senders => const ['eDahab'];

  static final _pattern = _re(_amount + r'\s*Dollar\s+Ayaad\s+Ka\s+Heshay[\s\S]*?Lambarka\s*:\s*(\d{6,15})');
  static final _reference = _re(r'Aqanoosiga\s*:\s*(\S+)');

  @override
  ParsedPaymentSms? tryParse(String sender, String body) {
    if (!_fromSender(senders, sender)) return null;
    if (!body.toLowerCase().contains('edahab')) return null;
    final m = _pattern.firstMatch(body);
    if (m == null) return null;
    final amount = _parseAmount(m.group(1)!);
    if (amount == null) return null;
    return ParsedPaymentSms(
      provider: 'Somtel',
      amount: amount,
      phone: m.group(2)!,
      transactionRef: _reference.firstMatch(body)?.group(1),
    );
  }
}

/// Somnet's EVC Plus format (also from sender "192").
/// "[-EVCPlus-] $0.1 ayaad ka Heshay AARAN DATA SERVICE (252685115555),
///  27/07/26 04:49:01 via Somnet Telecom, Haraagaagu waa $4.95."
class SomnetEvcPlusParser implements _PaymentParser {
  const SomnetEvcPlusParser();

  @override
  List<String> get senders => const ['192'];

  static final _pattern =
      _re(r'\$' + _amount + r'\s*ayaad\s+ka\s+Heshay\s+.+?\((\d{6,15})\)[\s\S]*?via\s+Somnet\s+Telecom');

  @override
  ParsedPaymentSms? tryParse(String sender, String body) {
    if (!_fromSender(senders, sender)) return null;
    if (!body.toLowerCase().contains('somnet')) return null;
    final m = _pattern.firstMatch(body);
    if (m == null) return null;
    final amount = _parseAmount(m.group(1)!);
    if (amount == null) return null;
    return ParsedPaymentSms(provider: 'Somnet', amount: amount, phone: m.group(2)!);
  }
}

/// Somtel eDahab payout sent.
/// "1.98 Dollar ayad u warejisay Yaasiin Maxamed Aadan. No: 620346060.Tixrac: PP260808.2240.E07703 ..."
class SomtelEdahabPayoutSentParser implements _PayoutSentParser {
  const SomtelEdahabPayoutSentParser();

  @override
  List<String> get senders => const ['eDahab'];

  static final _pattern = _re(_amount + r'\s*Dollar\s+ayad?\s+u\s+warejisay[\s\S]*?No:\s*(\d{6,15})');
  static final _reference = _re(r'Tixrac\s*:\s*([A-Za-z0-9.]+[A-Za-z0-9])');

  @override
  PayoutSentSms? tryParse(String sender, String body) {
    if (!_fromSender(senders, sender)) return null;
    final m = _pattern.firstMatch(body);
    if (m == null) return null;
    final amount = _parseAmount(m.group(1)!);
    if (amount == null) return null;
    return PayoutSentSms(
      receiverPhone: m.group(2)!,
      amount: amount,
      provider: 'Somtel',
      rawText: body,
      reference: _reference.firstMatch(body)?.group(1),
    );
  }
}

/// Somtel's other payout wording, from shortcode 252888.
/// "Waxaad ku wareejisay 1.2000 Dollars macmiilka 629309509."
class SomtelWareejisayPayoutSentParser implements _PayoutSentParser {
  const SomtelWareejisayPayoutSentParser();

  @override
  List<String> get senders => const ['252888'];

  static final _pattern = _re(r'Waxaad\s+ku\s+wareejisay\s+' + _amount + r'\s*Dollars\s+macmiilka\s+(\d{6,15})');

  @override
  PayoutSentSms? tryParse(String sender, String body) {
    if (!_fromSender(senders, sender)) return null;
    final m = _pattern.firstMatch(body);
    if (m == null) return null;
    final amount = _parseAmount(m.group(1)!);
    if (amount == null) return null;
    return PayoutSentSms(receiverPhone: m.group(2)!, amount: amount, provider: 'Somtel', rawText: body);
  }
}

/// Hormuud EVC Plus payout sent ("192"/"EVCPLUS") and its E-Voucher twin
/// ("740"), same wording.
/// "[-EVCPLUS-] $1.98 ayaad uwareejisay YASIIN MAXAMED AADAN (610346060), Tar: 09/08/26 20:32:27, ..."
class HormuudPayoutSentParser implements _PayoutSentParser {
  const HormuudPayoutSentParser(this.senders);

  @override
  final List<String> senders;

  static final _pattern = _re(r'\$' + _amount + r'\s*ayaad\s+uwareejisay\s+.+?\((\d{6,15})\)');

  @override
  PayoutSentSms? tryParse(String sender, String body) {
    if (!_fromSender(senders, sender)) return null;
    if (!body.toLowerCase().contains('uwareejisay')) return null;
    final m = _pattern.firstMatch(body);
    if (m == null) return null;
    final amount = _parseAmount(m.group(1)!);
    if (amount == null) return null;
    return PayoutSentSms(receiverPhone: m.group(2)!, amount: amount, provider: 'Hormuud', rawText: body);
  }
}

/// What one SMS turned out to be.
class SmsClassification {
  const SmsClassification._({this.payment, this.payoutSent, required this.paymentLooking});

  final ParsedPaymentSms? payment;
  final PayoutSentSms? payoutSent;

  /// Matched no parser but reads like a money SMS: uploaded unparsed so it
  /// is visible to managers (Dalab's looksLikePaymentSms branch).
  final bool paymentLooking;

  bool get isRelevant => payment != null || payoutSent != null || paymentLooking;
}

class PaymentSmsParsers {
  PaymentSmsParsers._();

  static const List<_PaymentParser> payments = [
    HormuudEvcPlusParser(),
    SomtelEdahabParser(),
    SomnetEvcPlusParser(),
  ];

  static const List<_PayoutSentParser> payoutsSent = [
    SomtelEdahabPayoutSentParser(),
    SomtelWareejisayPayoutSentParser(),
    HormuudPayoutSentParser(['192', 'EVCPLUS']),
    HormuudPayoutSentParser(['740']),
  ];

  static const List<String> _paymentLookingKeywords = [
    'heshay', 'ka heshay', 'dollar', 'aqanoosiga', 'edahab', 'e-dahab',
    'evcplus', 'evc plus', 'somnet', 'haraagagu', 'haraagaaga', 'haraagaagu', 'amtel',
  ];

  static ParsedPaymentSms? parsePayment(String sender, String body) {
    for (final p in payments) {
      final r = p.tryParse(sender, body);
      if (r != null) return r;
    }
    return null;
  }

  static PayoutSentSms? parsePayoutSent(String sender, String body) {
    for (final p in payoutsSent) {
      final r = p.tryParse(sender, body);
      if (r != null) return r;
    }
    return null;
  }

  static bool looksLikePaymentSms(String body) {
    final lower = body.toLowerCase();
    return lower.contains(r'$') || _paymentLookingKeywords.any(lower.contains);
  }

  /// Same order as Dalab's SmsReceiver: incoming payment first, then the
  /// payout-sent formats, then the unparsed-but-payment-looking fallback.
  static SmsClassification classify(String sender, String body) {
    final payment = parsePayment(sender, body);
    if (payment != null) return SmsClassification._(payment: payment, paymentLooking: true);
    final sent = parsePayoutSent(sender, body);
    if (sent != null) return SmsClassification._(payoutSent: sent, paymentLooking: true);
    return SmsClassification._(paymentLooking: looksLikePaymentSms(body));
  }
}
