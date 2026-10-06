/// Home-screen ads and in-app notifications, managed from the Agent App.
class HomeAd {
  const HomeAd({required this.id, required this.title, this.body, this.imageUrl, this.linkUrl});

  final String id;
  final String title;
  final String? body;
  final String? imageUrl;
  final String? linkUrl;

  factory HomeAd.fromJson(Map<String, dynamic> json) => HomeAd(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        body: json['body'] as String?,
        imageUrl: json['imageUrl'] as String?,
        linkUrl: json['linkUrl'] as String?,
      );
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
