/// POST /customer/quotes response. This is the ONLY source of the
/// rate/fee/net-amount math the app displays -- the app never computes
/// these itself.
class Quote {
  const Quote({
    required this.quoteId,
    required this.method,
    required this.direction,
    required this.amount,
    required this.rate,
    required this.fee,
    required this.netAmount,
    required this.walletDelta,
  });

  final String quoteId;
  final String method; // 'evc_plus' | 'winwin'
  final String direction; // 'deposit' | 'withdraw'
  final String amount;
  final num rate;
  final String fee;
  final String netAmount;
  final String walletDelta;

  factory Quote.fromJson(Map<String, dynamic> json) {
    return Quote(
      quoteId: json['quoteId'] as String,
      method: json['method'] as String,
      direction: json['direction'] as String,
      amount: json['amount'] as String,
      rate: json['rate'] as num,
      fee: json['fee'] as String,
      netAmount: json['netAmount'] as String,
      walletDelta: json['walletDelta'] as String,
    );
  }
}
