import 'package:intl/intl.dart';

import 'language.dart';

const _somaliMonths = {
  'Jan': 'Jan',
  'Feb': 'Feb',
  'Mar': 'Mar',
  'Apr': 'Abr',
  'May': 'May',
  'Jun': 'Jun',
  'Jul': 'Luu',
  'Aug': 'Ago',
  'Sep': 'Sep',
  'Oct': 'Okt',
  'Nov': 'Nof',
  'Dec': 'Dis',
};

/// A [DateFormat] whose month names follow the app language: the dates read
/// "4 Nof 2026" in Somali and "4 Nov 2026" in English (intl has no Somali data).
class AppDateFormat {
  AppDateFormat(String pattern) : _format = DateFormat(pattern);
  final DateFormat _format;

  String format(DateTime date) {
    final text = _format.format(date);
    if (!AppLanguage.isSomali) return text;
    return text.replaceAllMapped(RegExp('Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec'), (m) => _somaliMonths[m.group(0)]!);
  }
}
