/// GET /customer/wallet response. All amounts are decimal strings on the
/// wire (e.g. "9.80") -- displayed as-is, never parsed for arithmetic.
class Wallet {
  const Wallet({
    required this.availableBalance,
    required this.pendingBalance,
    required this.totalDeposit,
    required this.totalWithdraw,
    this.bonusBalance = '0.00',
    this.walletId,
    this.promoCode,
  });

  final String availableBalance;
  final String pendingBalance;
  final String totalDeposit;
  final String totalWithdraw;

  final String bonusBalance;

  /// The customer's permanent Wallet ID (e.g. BE482913), assigned by the
  /// backend when the wallet was created.
  final String? walletId;

  /// The promo code set in the Agent App, or null when there is none.
  final String? promoCode;

  factory Wallet.fromJson(Map<String, dynamic> json) {
    return Wallet(
      availableBalance: json['availableBalance'] as String,
      pendingBalance: json['pendingBalance'] as String,
      totalDeposit: json['totalDeposit'] as String,
      totalWithdraw: json['totalWithdraw'] as String,
      bonusBalance: json['bonusBalance'] as String? ?? '0.00',
      walletId: json['walletId'] as String?,
      promoCode: json['promoCode'] as String?,
    );
  }
}
