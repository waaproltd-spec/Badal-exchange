import 'dart:convert';
import 'dart:typed_data';

/// One match of a tip: "Arsenal v Chelsea", the pick and its odds.
class TipMatch {
  const TipMatch({required this.match, required this.pick, this.odds});

  final String match;
  final String pick;
  final double? odds;

  factory TipMatch.fromJson(Map<String, dynamic> json) => TipMatch(
        match: json['match'] as String? ?? '',
        pick: json['pick'] as String? ?? '',
        odds: (json['odds'] as num?)?.toDouble(),
      );
}

/// A tip as the server sends it to a customer (customer_tips / customer_tip).
/// A paid tip that is not bought yet has no [oddsCode], no matches and no picture:
/// the server does not send them, so there is nothing to find in the app.
class Tip {
  const Tip({
    required this.id,
    required this.title,
    required this.sport,
    required this.teamCount,
    required this.isPaid,
    this.price,
    this.totalOdds,
    this.note,
    this.owned = false,
    this.oddsCode,
    this.matches = const [],
    this.hasImage = false,
    this.imageBase64,
    this.publishedAt,
  });

  final String id;
  final String title;

  /// football, basketball, tennis, volleyball, baseball, hockey, cricket, rugby, boxing, other.
  final String sport;
  final int teamCount;
  final bool isPaid;

  /// "2.50" for a paid tip.
  final String? price;
  final double? totalOdds;
  final String? note;

  /// A paid tip the customer already bought.
  final bool owned;
  final String? oddsCode;
  final List<TipMatch> matches;
  final bool hasImage;
  final String? imageBase64;
  final DateTime? publishedAt;

  /// A paid tip that is still to be bought: the code is hidden.
  bool get locked => isPaid && !owned;

  Uint8List? get imageBytes {
    final b = imageBase64;
    if (b == null || b.isEmpty) return null;
    try {
      return base64Decode(b);
    } catch (_) {
      return null;
    }
  }

  factory Tip.fromJson(Map<String, dynamic> json) => Tip(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        sport: json['sport'] as String? ?? 'other',
        teamCount: (json['teamCount'] as num?)?.toInt() ?? 0,
        isPaid: json['isPaid'] as bool? ?? false,
        price: json['price'] as String?,
        totalOdds: (json['totalOdds'] as num?)?.toDouble(),
        note: json['note'] as String?,
        owned: json['owned'] as bool? ?? false,
        oddsCode: json['oddsCode'] as String?,
        matches: [
          for (final m in (json['matches'] as List? ?? const [])) TipMatch.fromJson(m as Map<String, dynamic>),
        ],
        hasImage: json['hasImage'] as bool? ?? false,
        imageBase64: json['image'] as String?,
        publishedAt: DateTime.tryParse(json['publishedAt'] as String? ?? ''),
      );
}

/// The answer to buying: the unlocked tip, the new balance, and whether money was taken
/// ([charged] is false when the customer already owned the tip).
class TipPurchase {
  const TipPurchase({required this.tip, required this.charged, required this.availableBalance});

  final Tip tip;
  final bool charged;
  final String availableBalance;

  factory TipPurchase.fromJson(Map<String, dynamic> json) => TipPurchase(
        tip: Tip.fromJson(json['tip'] as Map<String, dynamic>),
        charged: json['charged'] as bool? ?? false,
        availableBalance: json['availableBalance'] as String? ?? '0.00',
      );
}
