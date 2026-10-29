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
  const AppNotification({required this.id, required this.title, required this.body, required this.createdAt});

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
