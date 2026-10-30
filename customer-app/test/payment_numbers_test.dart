import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/payment_numbers.dart';
import 'package:badal_exchange_customer/models/quote.dart';
import 'package:badal_exchange_customer/screens/withdraw/withdraw_confirm_screen.dart';
import 'package:badal_exchange_customer/screens/withdraw/withdraw_details_screen.dart';
import 'package:badal_exchange_customer/utils/payment_errors.dart';
import 'package:badal_exchange_customer/widgets/own_phone_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

PaymentNumbers _allowed({List<String> methods = const ['evc_plus', 'golis', 'telesom', 'edahab']}) => PaymentNumbers.fromJson({
      'allowed': true,
      'methods': methods,
      'numbers': [
        {'id': 'n1', 'method': 'evc_plus', 'phone': '252612223344', 'label': 'Work'},
        {'id': 'n2', 'method': 'golis', 'phone': '252629998877', 'label': null},
      ],
    });

class _Api extends CustomerApi {
  _Api(this.numbers) : super(ApiClient());
  final PaymentNumbers numbers;
  final receiverAsked = <String?>[];

  @override
  Future<PaymentNumbers> getPaymentNumbers() async => numbers;

  @override
  Future<String?> getReceiverName(String method, [String? phone]) async {
    receiverAsked.add(phone);
    return 'NAME OF $phone';
  }

  @override
  Future<Quote> createQuote({required String direction, required String method, required String amount}) async => Quote(
        quoteId: 'q1', method: method, direction: direction, amount: amount, rate: 1, fee: '0.00', netAmount: amount, walletDelta: '-$amount');
}

Future<_Api> _open(WidgetTester tester, PaymentNumbers numbers, {String method = 'evc_plus'}) async {
  final api = _Api(numbers);
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  AppLanguage.current.value = AppLanguage.english;
  await tester.pumpWidget(Provider<CustomerApi>.value(
    value: api,
    child: MaterialApp(home: WithdrawDetailsScreen(method: method, ownPhone: '252610338686', availableBalance: '900.00')),
  ));
  await tester.pump();
  await tester.pump();
  return api;
}

void main() {
  test('PaymentNumbers: allowed only for the networks the admin chose; saved numbers by network', () {
    final n = _allowed(methods: ['evc_plus']);
    expect(n.allows('evc_plus'), isTrue);
    expect(n.allows('golis'), isFalse);
    expect(PaymentNumbers.none.allows('evc_plus'), isFalse);
    expect(n.forMethod('evc_plus').single.local, '612223344');
    expect(n.forMethod('telesom'), isEmpty);
  });

  test('the number errors are Somali, whatever the app language', () {
    for (final code in ['PHONE_NOT_OWN', 'PAYMENT_NUMBER_BLOCKED', 'PAYMENT_NUMBER_TAKEN', 'PAYMENT_NUMBER_LIMIT']) {
      final text = PaymentErrors.message(ApiException(status: 400, code: code, message: 'English technical text'), isDeposit: true);
      expect(text, startsWith('❌ Lambar'), reason: code);
      expect(text, isNot(contains('English')));
    }
  });

  testWidgets('without permission the registered number is locked, as before', (tester) async {
    await _open(tester, PaymentNumbers.none);
    expect(find.byType(OwnPhoneBox), findsOneWidget);
    expect(find.byKey(const Key('pick-own-number')), findsNothing);
    expect(find.text('610338686'), findsOneWidget);
  });

  testWidgets('permission for another network does not unlock this one', (tester) async {
    await _open(tester, _allowed(methods: ['golis']));
    expect(find.byType(OwnPhoneBox), findsOneWidget);
  });

  testWidgets('with permission: another number is typed in the box, and the withdrawal goes to it; no quick-pick chips', (tester) async {
    await _open(tester, _allowed());
    expect(find.byType(OwnPhoneBox), findsNothing);
    final field = find.byKey(const Key('withdraw-own-number'));
    expect(tester.widget<TextField>(field).controller!.text, '610338686', reason: 'starts as the registered number');
    expect(find.byType(ActionChip), findsNothing);

    await tester.enterText(find.byType(TextFormField).last, '5');
    await tester.enterText(field, '6122');
    await tester.tap(find.byKey(const Key('withdraw-continue')));
    await tester.pump();
    expect(find.text(AppStrings.enterNineDigits), findsOneWidget, reason: 'an unfinished number is not sent');
    expect(find.byType(WithdrawConfirmScreen), findsNothing);

    await tester.enterText(field, '612223344');
    await tester.tap(find.byKey(const Key('withdraw-continue')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<WithdrawConfirmScreen>(find.byType(WithdrawConfirmScreen)).phoneNumber, '252612223344');
  });

  testWidgets('a number typed in the box is what the confirmation shows, and the receiver name is asked for that number', (tester) async {
    final api = await _open(tester, _allowed());
    await tester.enterText(find.byKey(const Key('withdraw-own-number')), '905999914');
    await tester.enterText(find.byType(TextFormField).last, '1');
    await tester.tap(find.byKey(const Key('withdraw-continue')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<WithdrawConfirmScreen>(find.byType(WithdrawConfirmScreen)).phoneNumber, '252905999914');
    expect(find.text('+252 905999914'), findsOneWidget);
    expect(api.receiverAsked, ['252905999914']);
    expect(find.text('NAME OF 252905999914'), findsOneWidget);
  });
}
