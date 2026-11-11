import 'dart:convert';
import 'dart:typed_data';

/// Home-screen ads and in-app notifications, managed from the Agent App.
class HomeAd {
  const HomeAd({required this.id, required this.title, this.body, this.imageUrl, this.image, this.linkUrl});

  final String id;
  final String title;
  final String? body;
  final String? imageUrl;

  /// The picture a manager chose from their gallery (JPEG, PNG or WebP);
  /// shown in place of [imageUrl] when there is one.
  final Uint8List? image;
  final String? linkUrl;

  factory HomeAd.fromJson(Map<String, dynamic> json) => HomeAd(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        body: json['body'] as String?,
        imageUrl: json['imageUrl'] as String?,
        image: _adImage(json['image']),
        linkUrl: json['linkUrl'] as String?,
      );
}

Uint8List? _adImage(Object? v) {
  if (v is! String || v.isEmpty) return null;
  try {
    return base64Decode(v);
  } catch (_) {
    return null;
  }
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.kind = 'broadcast',
    this.status,
    this.amount,
    this.method,
    this.reference,
    this.transactionRef,
    this.balanceAfter,
    this.counterpartName,
    this.counterpartWalletId,
  });

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;

  /// broadcast | deposit | withdraw | transfer_sent | transfer_received (an older server sends none: a broadcast).
  final String kind;

  /// completed | failed | pending, for a money movement.
  final String? status;
  final String? amount;
  final String? method;

  /// The order code or the transfer reference, and the provider's transaction reference when there is one.
  final String? reference;
  final String? transactionRef;
  final String? balanceAfter;
  final String? counterpartName;
  final String? counterpartWalletId;

  bool get isMoney => kind != 'broadcast';

  /// The reference the customer copies: the provider's own when it has one, else the order / transfer reference.
  /// Sahal's own payout reference ("Sahal 7559059001") is not shown to the customer: the order code is shown instead.
  String? get copyRef {
    final t = (transactionRef ?? '').trim();
    return t.isNotEmpty && !RegExp(r'^sahal', caseSensitive: false).hasMatch(t) ? t : reference;
  }

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        kind: json['kind'] as String? ?? 'broadcast',
        status: json['status'] as String?,
        amount: json['amount'] as String?,
        method: json['method'] as String?,
        reference: json['reference'] as String?,
        transactionRef: json['transactionRef'] as String?,
        balanceAfter: json['balanceAfter'] as String?,
        counterpartName: json['counterpartName'] as String?,
        counterpartWalletId: json['counterpartWalletId'] as String?,
      );
}
