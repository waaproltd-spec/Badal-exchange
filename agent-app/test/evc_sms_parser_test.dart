import 'package:flutter_test/flutter_test.dart';

import 'package:badal_agent_app/sms/evc_sms_parser.dart';

/// Unit tests for the pure SMS-extraction logic. These exercise only
/// [EvcSmsParser.parse] — no Flutter widgets, no platform channel — so they
/// can run under a plain `flutter test` (or in principle `dart test`) in
/// any environment with the SDK installed.
///
/// NOTE: the exact wording/sender used below is this project's best-effort
/// guess at a typical EVC Plus payment notification (see the doc comment in
/// lib/sms/evc_sms_parser.dart). Once a real sample SMS is available, add
/// it here verbatim (still with fabricated details) and adjust the parser
/// accordingly.
void main() {
  group('EvcSmsParser.isAuthorizedSender', () {
    test('accepts known EVC Plus sender ids case-insensitively', () {
      expect(EvcSmsParser.isAuthorizedSender('EVCPLUS'), isTrue);
      expect(EvcSmsParser.isAuthorizedSender('evcplus'), isTrue);
      expect(EvcSmsParser.isAuthorizedSender('Hormuud'), isTrue);
      expect(EvcSmsParser.isAuthorizedSender('EVC-PLUS-NOTIFY'), isTrue);
    });

    test('rejects unrelated senders', () {
      expect(EvcSmsParser.isAuthorizedSender('SOMTEL'), isFalse);
      expect(EvcSmsParser.isAuthorizedSender('12345'), isFalse);
      expect(EvcSmsParser.isAuthorizedSender(''), isFalse);
    });
  });

  group('EvcSmsParser.parse', () {
    final receivedAt = DateTime.utc(2026, 8, 19, 14, 32);

    test('extracts sender phone, amount, and reference from a well-formed payment SMS', () {
      const body =
          'Confirmed. You have received \$25.00 from 252612345678. '
          'Transaction ID: ABC12345 on 19/08/2026 14:32';

      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      expect(result, isNotNull);
      expect(result!.senderPhoneNumber, '252612345678');
      expect(result.amount, '25.00');
      expect(result.transactionRef, 'ABC12345');
      expect(result.occurredAt, receivedAt);
      expect(result.provider, 'evc_plus');
    });

    test('normalizes a local-format phone number (0XXXXXXXX) to 252XXXXXXXXX', () {
      const body = 'You have received \$10.00 from 0612345678. Ref: XYZ98765';

      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      expect(result, isNotNull);
      expect(result!.senderPhoneNumber, '252612345678');
    });

    test('extracts an amount without a currency marker without confusing it with the phone/ref', () {
      const body = 'You have received 15.50 from 252699988877 Reference: QWE11122';

      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      expect(result, isNotNull);
      expect(result!.amount, '15.50');
      expect(result.senderPhoneNumber, '252699988877');
      expect(result.transactionRef, 'QWE11122');
    });

    test('handles a thousands-separated amount', () {
      const body = 'You have received SOS 25,000 from 252611122233. Trx ID: TRX555555';

      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      expect(result, isNotNull);
      expect(result!.amount, '25000.00');
    });

    test('returns null for a message from an unrecognized sender', () {
      const body = 'You have received \$25.00 from 252612345678. Transaction ID: ABC12345';

      final result = EvcSmsParser.parse('SOMTEL-PROMO', body, receivedAt: receivedAt);

      expect(result, isNull);
    });

    test('returns null for an EVC Plus SMS that is not a payment notification', () {
      const body = 'Your EVC Plus balance is \$120.00. Dial *334# for more options.';

      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      expect(result, isNull);
    });

    test('returns null when no phone number can be found', () {
      const body = 'You have received \$25.00. Transaction ID: ABC12345';

      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      expect(result, isNull);
    });

    test('returns null when no reference/transaction id can be found', () {
      const body = 'You have received \$25.00 from 252612345678.';

      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      expect(result, isNull);
    });

    test('returns null for an empty message', () {
      final result = EvcSmsParser.parse('EVCPLUS', '', receivedAt: receivedAt);
      expect(result, isNull);
    });

    test('never surfaces the raw SMS body on the parsed result', () {
      const body =
          'Confirmed. You have received \$25.00 from 252612345678. Transaction ID: ABC12345';
      final result = EvcSmsParser.parse('EVCPLUS', body, receivedAt: receivedAt);

      // ParsedEvcSmsTransaction has no field carrying the raw text — this
      // assertion documents that guarantee via toString() as a smoke check.
      expect(result.toString().contains('Confirmed'), isFalse);
    });
  });
}
