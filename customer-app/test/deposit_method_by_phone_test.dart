import 'package:badal_exchange_customer/models/payment_method.dart';
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
  test('the registered number picks its own mobile money; platforms stay', () {
    expect(_ids('252610346060'), ['evc_plus', 'onexbet', 'melbet']);
    expect(_ids('0905999914'), ['golis', 'onexbet', 'melbet']);
    expect(_ids('+252 638882065'), ['telesom', 'onexbet', 'melbet']);
    expect(_ids('620338686'), ['edahab', 'onexbet', 'melbet']);
  });

  test('a number of no known network, or none, keeps every method', () {
    expect(_ids('252771234567').length, _all.length);
    expect(_ids(null).length, _all.length);
    expect(_ids('').length, _all.length);
  });
}
