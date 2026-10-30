import 'payment_sms_parsers.dart';

/// Sahal's access-code SMS ("-SAHAL SERVICES- Access code is 123456"),
/// texted to the merchant phone when Sahal asks for a second sign-in step.
///
/// The phone only decides whether an SMS *could* be that one; the server
/// decides everything else (agent_sahal_sms_code): that Sahal is waiting
/// for a code right now, that the SMS is newer than the request, that the
/// sender is authorized, and which number is the code. Anything else is
/// dropped on the device like every other personal SMS: it is never sent
/// and never stored.
class SahalSms {
  SahalSms._();

  /// An access code is good for 10 minutes; an older SMS is never sent.
  static const validFor = Duration(minutes: 10);

  static final _from = RegExp(r'sahal|access\s*code', caseSensitive: false);
  static final _number = RegExp(r'(?<!\d)\d{4,8}(?!\d)');

  static bool looksLikeCode(String sender, String body) {
    // A payment or payout SMS is never a sign-in code.
    if (PaymentSmsParsers.parsePayment(sender, body) != null ||
        PaymentSmsParsers.parsePayoutSent(sender, body) != null) {
      return false;
    }
    final fromSahal = _from.hasMatch(body) || sender.trim().toLowerCase() == 'sahal';
    return fromSahal && _number.hasMatch(body);
  }
}
