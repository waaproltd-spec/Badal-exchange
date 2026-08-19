import 'package:intl/intl.dart';

/// Purely presentational formatting helpers.
///
/// IMPORTANT: these never compute money (no rounding, no arithmetic on
/// amounts) -- they only add a currency prefix or format a date the backend
/// already gave us. All fee/rate/net-amount math stays server-side.
class Formatters {
  Formatters._();

  static final DateFormat _dateTimeFormat = DateFormat('MMM d, yyyy • h:mm a');

  /// Prefixes a backend-provided decimal string with a currency symbol.
  /// Does NOT parse or re-round the value.
  static String money(String value, {String symbol = '\$'}) => '$symbol$value';

  static String dateTime(DateTime dt) => _dateTimeFormat.format(dt.toLocal());
}
