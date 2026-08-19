import 'package:flutter_test/flutter_test.dart';
import 'package:badal_exchange_customer/utils/formatters.dart';

void main() {
  group('Formatters.money', () {
    test('prefixes a backend-provided decimal string as-is, without re-parsing it', () {
      expect(Formatters.money('9.80'), r'$9.80');
      expect(Formatters.money('0.00'), r'$0.00');
      // Deliberately not "normalized" -- proves the helper never touches
      // the value's precision, since only the backend is allowed to do
      // money math.
      expect(Formatters.money('1234.5'), r'$1234.5');
    });

    test('supports a custom currency symbol', () {
      expect(Formatters.money('10.00', symbol: '€'), '€10.00');
    });
  });

  group('Formatters.dateTime', () {
    test('formats a UTC timestamp without throwing', () {
      final dt = DateTime.parse('2026-08-19T17:13:52.907Z');
      final formatted = Formatters.dateTime(dt);
      expect(formatted, isNotEmpty);
      expect(formatted, contains('2026'));
    });
  });
}
