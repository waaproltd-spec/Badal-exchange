import 'package:badal_exchange_customer/utils/ussd.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cents are separated by a star: the dialer drops a "."', () {
    expect(ussdAmount('57.52'), '57*52');
    expect(ussdAmount('1.5'), '1*50');
    expect(ussdAmount('1.50'), '1*50');
    expect(ussdAmount('0.10'), '0*10');
    expect(ussdAmount('.5'), '0*50');
    expect(ussdAmount('1,25'), '1*25');
  });

  test('whole dollars carry no cents', () {
    expect(ussdAmount('5'), '5');
    expect(ussdAmount('5.00'), '5');
    expect(ussdAmount('57.'), '57');
    expect(ussdAmount(' 100 '), '100');
    expect(ussdAmount('007'), '7');
    expect(ussdAmount('0'), '0');
  });
}
