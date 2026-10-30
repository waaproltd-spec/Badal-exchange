import 'package:badal_exchange_customer/models/payment_method.dart';
import 'package:badal_exchange_customer/models/payment_numbers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PaymentMethodOption _m(String id, {bool platform = false}) =>
    PaymentMethodOption(info: PaymentMethodInfo(id, id, platform, const Color(0xFF000000), id), depositNumbers: const []);

final _all = [
  _m('evc_plus'), _m('golis'), _m('telesom'), _m('edahab'),
  _m('onexbet', platform: true), _m('melbet', platform: true),
];
List<String> _ids(String? phone) => [for (final m in depositMethodsFor(_all, phone)) m.info.id];

void main() {
  test('the approved prefixes and their networks', () {
    expect(phonePrefixNetworks, {'61': 'evc_plus', '77': 'evc_plus', '90': 'golis', '63': 'telesom', '62': 'edahab'});
    for (final p in phonePrefixNetworks.keys) {
      expect(hasApprovedPhonePrefix('${p}1234567'), isTrue, reason: p);
      expect(ownMobileMethod('252${p}1234567'), phonePrefixNetworks[p], reason: p);
      expect(ownMobileMethod('0${p}1234567'), phonePrefixNetworks[p], reason: 'a leading 0');
    }
    for (final p in ['60', '64', '65', '66', '67', '68', '69', '70', '71', '76', '78', '79', '91', '99']) {
      expect(hasApprovedPhonePrefix('${p}1234567'), isFalse, reason: p);
      expect(ownMobileMethod('252${p}1234567'), isNull, reason: p);
    }
    expect(hasApprovedPhonePrefix(''), isFalse);
    expect(hasApprovedPhonePrefix('6'), isFalse);
  });

  test('the registered number picks its own mobile money; platforms stay', () {
    expect(_ids('252610346060'), ['evc_plus', 'onexbet', 'melbet']);
    expect(_ids('252771234567'), ['evc_plus', 'onexbet', 'melbet'], reason: '77 is EVC Plus too');
    expect(_ids('0905999914'), ['golis', 'onexbet', 'melbet']);
    expect(_ids('+252 638882065'), ['telesom', 'onexbet', 'melbet']);
    expect(_ids('620338686'), ['edahab', 'onexbet', 'melbet']);
  });

  test('a number of no known network, or none, keeps every method', () {
    expect(_ids('252711234567').length, _all.length, reason: 'an account registered before the list of prefixes');
    expect(_ids(null).length, _all.length);
    expect(_ids('').length, _all.length);
  });

  test('a customer an admin authorized for other numbers is offered those networks too, and only those', () {
    List<String> ids(PaymentNumbers n) => [for (final m in depositMethodsFor(_all, '252610346060', numbers: n)) m.info.id];
    const all = PaymentNumbers(allowed: true, methods: ['evc_plus', 'golis', 'telesom', 'edahab'], numbers: []);
    expect(ids(all), ['evc_plus', 'golis', 'telesom', 'edahab', 'onexbet', 'melbet']);
    const some = PaymentNumbers(allowed: true, methods: ['golis'], numbers: []);
    expect(ids(some), ['evc_plus', 'golis', 'onexbet', 'melbet']);
    expect(ids(PaymentNumbers.none), ['evc_plus', 'onexbet', 'melbet'], reason: 'no permission: as before');
    const revoked = PaymentNumbers(allowed: false, methods: ['golis'], numbers: []);
    expect(ids(revoked), ['evc_plus', 'onexbet', 'melbet']);
  });
}
