import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/utils/payment_errors.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends CustomerApi {
  _Api() : super(ApiClient());
  final reports = <String>[];

  @override
  Future<void> reportPaymentError({
    required String direction,
    required String method,
    required String amount,
    required String code,
    String? detail,
  }) async =>
      reports.add('$direction|$method|$amount|$code');
}

void main() {
  tearDown(() => AppLanguage.current.value = AppLanguage.somali);

  const withdrawText = '❌ Lacag-bixinta hadda cilad ayaa ka jirta. Fadlan mar kale isku day.';
  const depositText = '❌ Dhigasho hadda cilad ayaa ka jirta. Fadlan mar kale isku day.';

  for (final lang in [AppLanguage.english, AppLanguage.somali]) {
    test('any other error is the fixed Somali message, with the app in $lang', () {
      AppLanguage.current.value = lang;
      for (final e in <Object>[
        const ApiException(status: 0, code: 'NETWORK', message: 'The request timed out.'),
        const ApiException(status: 502, code: 'BAD_GATEWAY', message: 'Bad gateway'),
        const ApiException(status: 503, code: 'WITHDRAWAL_PROVIDER_BALANCE', message: 'anything'),
        StateError('boom'),
      ]) {
        expect(PaymentErrors.message(e, isDeposit: false), withdrawText);
        expect(PaymentErrors.message(e, isDeposit: true), depositText);
      }
    });
  }

  test('a mistake the customer can fix is told in Somali with the limit, even in English', () {
    AppLanguage.current.value = AppLanguage.english;
    expect(
      PaymentErrors.message(const ApiException(status: 400, code: 'ABOVE_MAX_WITHDRAWAL', message: 'Maximum withdrawal is 500.00'), isDeposit: false),
      '❌ Lacag-bixinta ugu badan waa \$500.00.',
    );
    expect(
      PaymentErrors.message(const ApiException(status: 400, code: 'INSUFFICIENT_BALANCE', message: 'Insufficient wallet balance'), isDeposit: false),
      '❌ Haraaga boorsadaadu kuma filna.',
    );
  });

  test('limit and KYC messages come from the server in Somali and are kept', () {
    AppLanguage.current.value = AppLanguage.english;
    const m = 'Xadka maalinlaha ah ee lacag-bixinta ($50) waa gaadhay.';
    expect(PaymentErrors.message(const ApiException(status: 403, code: 'WITHDRAWAL_DAILY_LIMIT', message: m), isDeposit: false), m);
  });

  test('errors are reported to the server (admin Telegram) except typing mistakes', () {
    final api = _Api();
    PaymentErrors.handle(api, const ApiException(status: 0, code: 'NETWORK', message: 'x'), isDeposit: true, method: 'evc_plus', amount: '5');
    PaymentErrors.handle(api, const ApiException(status: 400, code: 'BELOW_MIN_WITHDRAWAL', message: 'Minimum withdrawal is 2'),
        isDeposit: false, method: 'evc_plus', amount: '1');
    PaymentErrors.handle(api, StateError('boom'), isDeposit: false, method: 'golis', amount: '9');
    expect(api.reports, ['deposit|evc_plus|5|NETWORK', 'withdraw|golis|9|ERROR']);
  });
}
