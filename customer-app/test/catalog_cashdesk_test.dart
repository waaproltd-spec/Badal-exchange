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
}
