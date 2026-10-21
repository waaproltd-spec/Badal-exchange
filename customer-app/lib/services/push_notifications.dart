import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../api/customer_api.dart';

/// A notification the backend sent: 'deposit_completed' or
/// 'withdraw_completed', for the order [orderId]. The text comes from the
/// server (in Somali); the app only uses the type and the order id.
class PushMessage {
  const PushMessage({required this.type, required this.orderId, this.title, this.body});

  final String type;
  final String orderId;
  final String? title;
  final String? body;

  static const types = {'deposit_completed', 'withdraw_completed'};

  /// Null for anything that isn't one of our two notifications.
  static PushMessage? fromData(Map<String, dynamic> data, {String? title, String? body}) {
    final type = data['type'];
    final orderId = data['orderId'];
    if (type is! String || !types.contains(type) || orderId is! String || orderId.isEmpty) return null;
    return PushMessage(type: type, orderId: orderId, title: title, body: body);
  }
}

/// What the app needs from Firebase Cloud Messaging; [FirebasePushPlatform]
/// in the app, a fake in tests.
abstract class PushPlatform {
  /// Asks for permission to show notifications (Android 13+); true if given.
  Future<bool> requestPermission();
  Future<String?> getToken();
  Future<void> deleteToken();
  Stream<String> get onTokenRefresh;

  /// Arrived while the app is open (Android shows nothing on its own then).
  Stream<PushMessage> get onForeground;

  /// The customer tapped a notification while the app was in the background.
  Stream<PushMessage> get onOpened;

  /// The notification tapped to start the app, if any.
  Future<PushMessage?> initialMessage();
}

class FirebasePushPlatform implements PushPlatform {
  FirebaseMessaging get _fcm => FirebaseMessaging.instance;

  static PushMessage? _from(RemoteMessage m) =>
      PushMessage.fromData(m.data, title: m.notification?.title, body: m.notification?.body);

  @override
  Future<bool> requestPermission() async {
    final s = await _fcm.requestPermission();
    return s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> getToken() => _fcm.getToken();

  @override
  Future<void> deleteToken() => _fcm.deleteToken();

  @override
  Stream<String> get onTokenRefresh => _fcm.onTokenRefresh;

  @override
  Stream<PushMessage> get onForeground =>
      FirebaseMessaging.onMessage.map(_from).where((m) => m != null).cast<PushMessage>();

  @override
  Stream<PushMessage> get onOpened =>
      FirebaseMessaging.onMessageOpenedApp.map(_from).where((m) => m != null).cast<PushMessage>();

  @override
  Future<PushMessage?> initialMessage() async {
    final m = await _fcm.getInitialMessage();
    return m == null ? null : _from(m);
  }
}

/// Customer push notifications: registers this device's token for the
/// signed-in customer (and removes it on logout), and hands the screens the
/// order to open when a notification is tapped ([openOrder]) or a banner to
/// show when one arrives while the app is open ([foreground]).
///
/// [instance] is set in main() when Firebase is configured; null otherwise,
/// and every use is then a no-op.
class PushNotifications {
  PushNotifications(this._platform) {
    _subs.add(_platform.onOpened.listen((m) => openOrder.value = m.orderId));
    _subs.add(_platform.onForeground.listen((m) => foreground.value = m));
    _platform.initialMessage().then((m) {
      if (m != null) openOrder.value = m.orderId;
    }).catchError((_) {});
  }

  static PushNotifications? instance;

  final PushPlatform _platform;
  final _subs = <StreamSubscription<dynamic>>[];
  StreamSubscription<String>? _refresh;
  String? _token;

  /// The order whose details to open; the shell opens it and clears it.
  final ValueNotifier<String?> openOrder = ValueNotifier(null);

  /// A notification that arrived while the app was open.
  final ValueNotifier<PushMessage?> foreground = ValueNotifier(null);

  /// After login: asks for permission and registers this device. Never
  /// throws -- notifications are a convenience.
  Future<void> start(CustomerApi api) async {
    try {
      if (!await _platform.requestPermission()) return;
      final token = await _platform.getToken();
      if (token != null) await _register(api, token);
      await _refresh?.cancel();
      _refresh = _platform.onTokenRefresh.listen((t) => _register(api, t));
    } catch (e) {
      debugPrint('Push notifications not started: $e');
    }
  }

  Future<void> _register(CustomerApi api, String token) async {
    try {
      await api.registerPushToken(token);
      _token = token;
    } catch (e) {
      debugPrint('Push token not registered: $e');
    }
  }

  /// Before logout (while still signed in): this device stops receiving the
  /// customer's notifications.
  Future<void> stop(CustomerApi api) async {
    await _refresh?.cancel();
    _refresh = null;
    final token = _token ?? await _platform.getToken().catchError((_) => null);
    _token = null;
    if (token == null) return;
    try {
      await api.unregisterPushToken(token);
    } catch (_) {}
    try {
      await _platform.deleteToken();
    } catch (_) {}
  }
}
