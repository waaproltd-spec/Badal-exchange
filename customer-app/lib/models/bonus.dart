/// The Bonus wallet (customer_bonus): what is in it, the customer's rate and
/// what came in and went out. Amounts are decimal strings, shown as is; a
/// bonus can be a fraction of a cent ("0.006").
class BonusInfo {
  const BonusInfo({
    required this.balance,
    required this.rate,
    required this.totalEarned,
    required this.entries,
    this.transferable = '0.00',
  });

  final String balance;

  /// The whole cents of [balance]: what a transfer moves to the main wallet.
  final String transferable;

  /// "1%", "1.5%"; "0%" when the bonus is off for this customer.
  final String rate;
  final String totalEarned;
  final List<BonusEntry> entries;

  /// At least a cent to transfer.
  bool get canTransfer => (double.tryParse(transferable) ?? 0) > 0;

  factory BonusInfo.fromJson(Map<String, dynamic> json) => BonusInfo(
        balance: json['balance'] as String? ?? '0.00',
        transferable: json['transferable'] as String? ?? json['balance'] as String? ?? '0.00',
        rate: json['rate'] as String? ?? '0%',
        totalEarned: json['totalEarned'] as String? ?? '0.00',
        entries: [
          for (final e in (json['entries'] as List? ?? const [])) BonusEntry.fromJson(e as Map<String, dynamic>),
        ],
      );
}

/// One line of bonus history: earned on a withdrawal, or moved to the main wallet.
class BonusEntry {
  const BonusEntry({
    required this.kind,
    required this.amount,
    required this.createdAt,
    this.rate,
    this.orderCode,
    this.orderAmount,
    this.direction,
    this.methodLabel,
  });

  /// 'earned' or 'moved'.
  final String kind;
  final String amount;
  final DateTime createdAt;

  /// The percentage it was worked out with ("2%"); earned entries only.
  final String? rate;
  final String? orderCode;

  /// The order it was earned on: its amount, 'deposit' or 'withdraw', method.
  final String? orderAmount;
  final String? direction;
  final String? methodLabel;

  bool get earned => kind == 'earned';

  factory BonusEntry.fromJson(Map<String, dynamic> json) => BonusEntry(
        kind: json['kind'] as String,
        amount: json['amount'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        rate: json['rate'] as String?,
        orderCode: json['orderCode'] as String?,
        orderAmount: (json['orderAmount'] ?? json['withdrawal']) as String?,
        direction: json['direction'] as String? ?? (json['withdrawal'] != null ? 'withdraw' : null),
        methodLabel: json['methodLabel'] as String?,
      );
}

/// What a withdrawal will earn once it is paid (customer_bonus_preview).
class BonusPreview {
  const BonusPreview({required this.rate, required this.amount});

  final String rate;
  final String amount;

  factory BonusPreview.fromJson(Map<String, dynamic> json) =>
      BonusPreview(rate: json['rate'] as String, amount: json['amount'] as String);
}
