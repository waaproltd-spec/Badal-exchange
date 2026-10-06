/// Filters for the History tab. Other tabs open History pre-filtered
/// (e.g. Dashboard "Failed" -> status=failed) through [HomeShell.openHistory].
class HistoryFilter {
  /// 'all' | 'deposit' | 'withdraw' | 'order' | 'confirmation'
  final String type;
  final String? status;
  final String? method;

  /// Inclusive dates, YYYY-MM-DD.
  final String? from;
  final String? to;

  /// Free-text search: customer name, phone, account ID, order code.
  final String query;

  const HistoryFilter({
    this.type = 'all',
    this.status,
    this.method,
    this.from,
    this.to,
    this.query = '',
  });

  bool get hasExtraFilters => status != null || method != null || from != null || to != null;

  HistoryFilter copyWith({
    String? type,
    String? Function()? status,
    String? Function()? method,
    String? Function()? from,
    String? Function()? to,
    String? query,
  }) {
    return HistoryFilter(
      type: type ?? this.type,
      status: status != null ? status() : this.status,
      method: method != null ? method() : this.method,
      from: from != null ? from() : this.from,
      to: to != null ? to() : this.to,
      query: query ?? this.query,
    );
  }
}
