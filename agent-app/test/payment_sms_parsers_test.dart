import 'package:flutter_test/flutter_test.dart';

import 'package:badal_agent_app/sms/payment_sms_parsers.dart';

/// Real carrier SMS formats (the same samples Dalab Internet's parsers were
/// confirmed against, plus the EVC Plus SMS from Baari's own test payment).
void main() {
  group('incoming payments', () {
    test('Hormuud EVC Plus: the real Baari test SMS (no reference, leading 0)', () {
      const body = '[-EVCPLUS-] waxaad \$1 ka heshay 0610346060, Tar: 06/10/26 20:19:52 haraagagu waa \$2.505.';
      for (final sender in ['192', 'EVCPLUS', '+192']) {
        final p = PaymentSmsParsers.parsePayment(sender, body)!;
        expect(p.provider, 'Hormuud');
        expect(p.amount, '1');
        expect(p.phone, '0610346060');
        expect(p.transactionRef, isNull);
      }
    });

    test('Hormuud EVC Plus: decimals and thousands separators', () {
      final p = PaymentSmsParsers.parsePayment('192', '[-EVCPLUS-] waxaad \$1,234.50 ka heshay 610346060, Tar: 24/07/26')!;
      expect(p.amount, '1234.50');
      expect(p.phone, '610346060');
    });

    test('Somtel eDahab with its Aqanoosiga reference', () {
      const body = '0.22 Dollar Ayaad Ka Heshay Yaasiin Maxamed Aadan.Code-ka:NA. Lambarka :620346060  '
          'Aqanoosiga : PP260718.0005.F75709 Haraagaaga Cusubi Waa: 2.61 Dollar..Tariikh:18-07-2026[-eDahab-Service-]';
      final p = PaymentSmsParsers.parsePayment('eDahab', body)!;
      expect(p.provider, 'Somtel');
      expect(p.amount, '0.22');
      expect(p.phone, '620346060');
      expect(p.transactionRef, 'PP260718.0005.F75709');
    });

    test('Somnet EVC Plus from 192', () {
      const body = '[-EVCPlus-] \$0.1 ayaad ka Heshay AARAN DATA SERVICE (252685115555),27/07/26 04:49:01 '
          'via Somnet Telecom, Haraagaagu waa \$4.95.';
      final p = PaymentSmsParsers.parsePayment('192', body)!;
      expect(p.provider, 'Somnet');
      expect(p.amount, '0.1');
      expect(p.phone, '252685115555');
    });

    test('a payment wording from an unknown sender is not trusted', () {
      const body = '[-EVCPLUS-] waxaad \$50 ka heshay 0610346060, Tar: 06/10/26 20:19:52';
      expect(PaymentSmsParsers.parsePayment('0615555555', body), isNull);
      // ...but it is money-looking, so it is uploaded unparsed for review.
      final c = PaymentSmsParsers.classify('0615555555', body);
      expect(c.payment, isNull);
      expect(c.paymentLooking, isTrue);
    });

    test('balance and personal SMS are dropped', () {
      expect(PaymentSmsParsers.classify('192', 'Your bundle expires tomorrow').isRelevant, isFalse);
      expect(PaymentSmsParsers.classify('0615555555', 'Hi, see you at 5').isRelevant, isFalse);
      expect(PaymentSmsParsers.classify('EVCPLUS', 'Your OTP is 4821').isRelevant, isFalse);
    });
  });

  group('payout sent (the payout phone\'s own confirmation)', () {
    test('Hormuud EVC Plus from 192', () {
      const body = '[-EVCPLUS-] \$1.98 ayaad uwareejisay YASIIN MAXAMED AADAN (610346060), Tar: 09/08/26 20:32:27, '
          'Haraagaagu waa \$36.965.';
      final c = PaymentSmsParsers.classify('192', body);
      expect(c.payment, isNull);
      expect(c.payoutSent!.provider, 'Hormuud');
      expect(c.payoutSent!.amount, '1.98');
      expect(c.payoutSent!.receiverPhone, '610346060');
    });

    test('Hormuud E-Voucher from 740', () {
      const body = '[-E-Voucher-] \$1.05 ayaad uwareejisay YAASIIN MAXAMED AADAN(617080008), Haraagaagu waa \$2.27.';
      final s = PaymentSmsParsers.parsePayoutSent('740', body)!;
      expect(s.amount, '1.05');
      expect(s.receiverPhone, '617080008');
    });

    test('Somtel eDahab with its Tixrac reference', () {
      const body = '1.98 Dollar ayad u warejisay Yaasiin Maxamed Aadan. No: 620346060.Tixrac: PP260808.2240.E07703 '
          'Haraaga: 7.08 Dollar Kharashyada Adeegga:0';
      final s = PaymentSmsParsers.parsePayoutSent('eDahab', body)!;
      expect(s.provider, 'Somtel');
      expect(s.amount, '1.98');
      expect(s.receiverPhone, '620346060');
      expect(s.reference, 'PP260808.2240.E07703');
    });

    test('Somtel 252888 wording', () {
      final s = PaymentSmsParsers.parsePayoutSent('252888', 'Waxaad ku wareejisay 1.2000 Dollars macmiilka 629309509.')!;
      expect(s.amount, '1.2000');
      expect(s.receiverPhone, '629309509');
    });

    test('a payout SMS is never read as an incoming payment', () {
      const body = '[-EVCPLUS-] \$5 ayaad uwareejisay ALI (610000001), Tar: 09/08/26 20:32:27';
      expect(PaymentSmsParsers.parsePayment('192', body), isNull);
    });
  });
}
