import 'package:badal_exchange_customer/models/payment_method.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a platform added in the Agent App is a cash desk because the catalog says so', () {
    final before = paymentMethods;
    addTearDown(() => paymentMethods = before);
    applyPaymentMethodCatalog([
      {'method': 'melbet', 'label': 'MELBET', 'kind': 'platform', 'color': '#CA8A04', 'initials': 'MB', 'cashdesk': true},
      {'method': 'premierbet', 'label': 'PremierBet', 'kind': 'platform', 'color': '#6B7280', 'initials': 'PR', 'cashdesk': true},
      {'method': 'edahab', 'label': 'eDahab', 'kind': 'mobile_money', 'color': '#D97706', 'initials': 'eD', 'cashdesk': false},
    ]);
    expect(methodInfo('premierbet').usesWithdrawalCode, isTrue);
    expect(methodInfo('premierbet').isPlatform, isTrue);
    expect(methodInfo('melbet').usesWithdrawalCode, isTrue);
    expect(methodInfo('edahab').usesWithdrawalCode, isFalse);
  });

  test('an older server without the flag: the built-in list, as before', () {
    final before = paymentMethods;
    addTearDown(() => paymentMethods = before);
    applyPaymentMethodCatalog([
      {'method': 'onexbet', 'label': '1XBET', 'kind': 'platform', 'color': '#1D4ED8', 'initials': '1X'},
    ]);
    expect(methodInfo('onexbet').usesWithdrawalCode, isTrue);
  });

  test('the deposit screen\'s method list says whether a platform is a cash desk, and the catalog fills in when an older server does not', () {
    final before = paymentMethods;
    addTearDown(() => paymentMethods = before);
    applyPaymentMethodCatalog([
      {'method': 'luckypari', 'label': 'LuckyPari', 'kind': 'platform', 'color': '#6B7280', 'initials': 'LU', 'cashdesk': true},
      {'method': 'manualplat', 'label': 'Manual', 'kind': 'platform', 'color': '#6B7280', 'initials': 'MA', 'cashdesk': false},
    ]);
    Map<String, dynamic> option(String method, {Object? cashdesk = 'absent'}) => {
          'method': method, 'label': method, 'kind': 'platform', 'color': '#6B7280', 'initials': 'XX',
          if (cashdesk != 'absent') 'cashdesk': cashdesk,
        };
    // The server's list says it: that wins.
    expect(PaymentMethodOption.fromJson(option('luckypari', cashdesk: true)).info.usesWithdrawalCode, isTrue);
    expect(PaymentMethodOption.fromJson(option('luckypari', cashdesk: false)).info.usesWithdrawalCode, isFalse);
    // An older server's list does not: the catalog's flag is used (not the built-in eight).
    expect(PaymentMethodOption.fromJson(option('luckypari')).info.usesWithdrawalCode, isTrue);
    expect(PaymentMethodOption.fromJson(option('manualplat')).info.usesWithdrawalCode, isFalse);
    // A built-in platform with neither: as before.
    expect(PaymentMethodOption.fromJson(option('onexbet')).info.usesWithdrawalCode, isTrue);
    // Unknown to both: not a cash desk.
    expect(PaymentMethodOption.fromJson(option('unknownplat')).info.usesWithdrawalCode, isFalse);
  });
}
