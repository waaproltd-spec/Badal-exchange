import 'dart:convert';
import 'dart:typed_data';

/// Models for TIPS (Shaxaha) in the Admin Dashboard and the Agent view.

const tipSports = ['football', 'basketball', 'tennis', 'volleyball', 'baseball', 'hockey', 'cricket', 'rugby', 'boxing', 'other'];

class TipMatchEntry {
  const TipMatchEntry({required this.match, this.pick = '', this.odds});

  final String match;
  final String pick;
  final double? odds;

  Map<String, dynamic> toJson() => {'match': match, 'pick': pick, if (odds != null) 'odds': odds};

  factory TipMatchEntry.fromJson(Map<String, dynamic> j) => TipMatchEntry(
        match: j['match'] as String? ?? '',
        pick: j['pick'] as String? ?? '',
        odds: (j['odds'] as num?)?.toDouble(),
      );
}

/// A tip as a manager sees it: everything, and its sales.
class ManagedTip {
  const ManagedTip({
    required this.id,
    required this.title,
    required this.sport,
    required this.teamCount,
    required this.isPaid,
    required this.price,
    required this.oddsCode,
    this.totalOdds,
    this.matches = const [],
    this.note,
    this.hasImage = false,
    this.imageBase64,
    required this.published,
    this.sales = 0,
    this.revenue = '0.00',
  });

  final String id;
  final String title;
  final String sport;
  final int teamCount;
  final bool isPaid;

  /// "2.50"; "0.00" for a free tip.
  final String price;
  final String oddsCode;
  final double? totalOdds;
  final List<TipMatchEntry> matches;
  final String? note;
  final bool hasImage;
  final String? imageBase64;
  final bool published;
  final int sales;
  final String revenue;

  Uint8List? get image {
    final b = imageBase64;
    if (b == null || b.isEmpty) return null;
    try {
      return base64Decode(b);
    } catch (_) {
      return null;
    }
  }

  factory ManagedTip.fromJson(Map<String, dynamic> j) => ManagedTip(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        sport: j['sport'] as String? ?? 'other',
        teamCount: (j['teamCount'] as num?)?.toInt() ?? 0,
        isPaid: j['isPaid'] as bool? ?? false,
        price: j['price'] as String? ?? '0.00',
        oddsCode: j['oddsCode'] as String? ?? '',
        totalOdds: (j['totalOdds'] as num?)?.toDouble(),
        matches: [for (final m in (j['matches'] as List? ?? const [])) TipMatchEntry.fromJson(m as Map<String, dynamic>)],
        note: j['note'] as String?,
        hasImage: j['hasImage'] as bool? ?? false,
        imageBase64: j['image'] as String?,
        published: j['published'] as bool? ?? false,
        sales: (j['sales'] as num?)?.toInt() ?? 0,
        revenue: j['revenue'] as String? ?? '0.00',
      );
}

class TipSale {
  const TipSale({required this.tipId, required this.title, required this.sales, required this.revenue});

  final String tipId;
  final String title;
  final int sales;
  final String revenue;

  factory TipSale.fromJson(Map<String, dynamic> j) => TipSale(
        tipId: j['tipId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        sales: (j['sales'] as num?)?.toInt() ?? 0,
        revenue: j['revenue'] as String? ?? '0.00',
      );
}

/// Totals: refunds are not revenue.
class TipsStats {
  const TipsStats({
    this.tips = 0,
    this.published = 0,
    this.paidTips = 0,
    this.freeTips = 0,
    this.sales = 0,
    this.revenue = '0.00',
    this.salesToday = 0,
    this.revenueToday = '0.00',
    this.sales7d = 0,
    this.revenue7d = '0.00',
    this.refunds = 0,
    this.refunded = '0.00',
    this.top = const [],
  });

  final int tips, published, paidTips, freeTips, sales, salesToday, sales7d, refunds;
  final String revenue, revenueToday, revenue7d, refunded;
  final List<TipSale> top;

  factory TipsStats.fromJson(Map<String, dynamic> j) => TipsStats(
        tips: (j['tips'] as num?)?.toInt() ?? 0,
        published: (j['published'] as num?)?.toInt() ?? 0,
        paidTips: (j['paidTips'] as num?)?.toInt() ?? 0,
        freeTips: (j['freeTips'] as num?)?.toInt() ?? 0,
        sales: (j['sales'] as num?)?.toInt() ?? 0,
        revenue: j['revenue'] as String? ?? '0.00',
        salesToday: (j['salesToday'] as num?)?.toInt() ?? 0,
        revenueToday: j['revenueToday'] as String? ?? '0.00',
        sales7d: (j['sales7d'] as num?)?.toInt() ?? 0,
        revenue7d: j['revenue7d'] as String? ?? '0.00',
        refunds: (j['refunds'] as num?)?.toInt() ?? 0,
        refunded: j['refunded'] as String? ?? '0.00',
        top: [for (final t in (j['top'] as List? ?? const [])) TipSale.fromJson(t as Map<String, dynamic>)],
      );
}

class TipPurchaseRecord {
  const TipPurchaseRecord({
    required this.id,
    required this.tipId,
    required this.title,
    required this.sport,
    required this.customerName,
    required this.customerPhone,
    required this.price,
    required this.status,
    this.createdAt,
    this.refundReason,
  });

  final String id, tipId, title, sport, price;
  final String? customerName, customerPhone, refundReason;

  /// completed | refunded
  final String status;
  final DateTime? createdAt;

  bool get refunded => status == 'refunded';

  factory TipPurchaseRecord.fromJson(Map<String, dynamic> j) => TipPurchaseRecord(
        id: j['id'] as String,
        tipId: j['tipId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        sport: j['sport'] as String? ?? 'other',
        customerName: j['customerName'] as String?,
        customerPhone: j['customerPhone'] as String?,
        price: j['price'] as String? ?? '0.00',
        status: j['status'] as String? ?? 'completed',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
        refundReason: j['refundReason'] as String?,
      );
}

/// The Agent App view: the figures and the purchase records.
class TipPurchasesView {
  const TipPurchasesView({required this.summary, required this.purchases});

  final TipsStats summary;
  final List<TipPurchaseRecord> purchases;

  factory TipPurchasesView.fromJson(Map<String, dynamic> j) => TipPurchasesView(
        summary: TipsStats.fromJson((j['summary'] as Map<String, dynamic>?) ?? const {}),
        purchases: [for (final p in (j['purchases'] as List? ?? const [])) TipPurchaseRecord.fromJson(p as Map<String, dynamic>)],
      );
}
