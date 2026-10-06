/// GET /customer/wallet response. All amounts are decimal strings on the
/// wire (e.g. "9.80") -- displayed as-is, never parsed for arithmetic.
class Wallet {
  const Wallet({
    required this.availableBalance,
    required this.pendingBalance,
    required this.totalDeposit,
    required this.totalWithdraw,
    this.bonusBalance = '0.00',
  });

  final String availableBalance;
  final String pendingBalance;
  final String totalDeposit;
  final String totalWithdraw;

  /// Not served by the backend yet; shown as "0.00" until it is.
  final String bonusBalance;

  factory Wallet.fromJson(Map<String, dynamic> json) {
    return Wallet(
      availableBalance: json['availableBalance'] as String,
      pendingBalance: json['pendingBalance'] as String,
      totalDeposit: json['totalDeposit'] as String,
      totalWithdraw: json['totalWithdraw'] as String,
      bonusBalance: json['bonusBalance'] as String? ?? '0.00',
    );
  }
}
