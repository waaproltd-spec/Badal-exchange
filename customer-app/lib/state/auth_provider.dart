import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../services/app_lock.dart';
import '../services/blocked_memory.dart';
import '../services/push_notifications.dart';
import '../models/auth_user.dart';
import '../l10n/strings.dart';
import '../screens/auth/login_screen.dart';

/// Session state: current user, and the login/register/logout flows.
/// The session tokens are held by Supabase Auth (in secure storage); this
/// class never handles a raw token.
class AuthProvider extends ChangeNotifier {
  AuthProvider({required this.apiClient, required this.customerApi, this.navigatorKey, AppLock? appLock})
      : _appLock = appLock ?? AppLock.instance {
    apiClient.onSessionExpired = _handleSessionExpired;
    apiClient.onSessionReplaced = _handleSessionReplaced;
    apiClient.onAccountBlocked = _handleAccountBlocked;
  }

  final ApiClient apiClient;
  final CustomerApi customerApi;
  final AppLock _appLock;

  /// Used to bounce back to the login screen if a token refresh fails
  /// while the user is deep in some other screen (not just at startup).
  final GlobalKey<NavigatorState>? navigatorKey;

  AuthUser? _user;
  AuthUser? get user => _user;
  bool get isAuthenticated => _user != null;

  bool _initializing = true;
  bool get initializing => _initializing;

  /// Restores a previously-persisted session (if any) from secure storage.
  /// Must be awaited (or listened for via [initializing]) before deciding
  /// whether to show the login screen or the app shell.
  Future<void> bootstrap() async {
    _initializing = true;
    notifyListeners();
    try {
      final phone = await apiClient.secureStorage.read(key: SecureStorageKeys.userPhone);
      final name = await apiClient.secureStorage.read(key: SecureStorageKeys.userName);
      if (apiClient.hasSession && phone != null && !await _rememberMe()) {
        // "Remember me" was off: start from the login screen.
        await _setRememberMe(true);
        await logout();
      } else if (apiClient.hasSession && phone != null) {
        _user = AuthUser(phone: phone, name: name ?? '');
        unawaited(apiClient.startLive());
        unawaited(_verifyRestoredSession());
        _startAccountCheck();
      } else if (apiClient.hasSession) {
        await apiClient.signOut();
      }
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  /// A restored session whose account was disabled is signed out.
  Future<void> _verifyRestoredSession() async {
    try {
      if (!await customerApi.verifySession()) await logout();
    } on ApiException catch (e) {
      if (e.status == 401 || e.status == 403) await logout();
    } catch (_) {
      // Offline: keep the session; calls retry when back online.
    }
  }

  Future<void> login({required String phone, required String password}) async {
    final result = await customerApi.login(phone: phone, password: password);
    final resolvedName = result.name.isNotEmpty ? result.name : phone;
    await _persistSession(phone: phone, name: resolvedName);
  }

  /// Logs in with the 9 local digits typed after +252. Accounts are stored
  /// as 252XXXXXXXXX; older ones may have been registered as 0XXXXXXXXX or
  /// the 9 digits alone, so those are tried when the first is refused.
  Future<void> loginWithLocalNumber({
    required String local,
    required String password,
    bool rememberMe = true,
  }) async {
    ApiException? refused;
    for (final phone in ['252$local', '0$local', local]) {
      try {
        await login(phone: phone, password: password);
        await _setRememberMe(rememberMe);
        return;
      } on ApiException catch (e) {
        if (e.status != 401) rethrow;
        refused = e;
      }
    }
    throw refused!;
  }

  static const String _rememberMeKey = 'remember_me';

  /// Off: the session is not restored the next time the app starts.
  Future<void> _setRememberMe(bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_rememberMeKey, value);
    } catch (_) {}
  }

  Future<bool> _rememberMe() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_rememberMeKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> register({
    required String phone,
    required String name,
    required String password,
  }) async {
    await customerApi.register(phone: phone, name: name, password: password);
    await _persistSession(phone: phone, name: name);
  }

  Future<void> logout() async {
    // While still signed in: this device stops getting the notifications.
    await PushNotifications.instance?.stop(customerApi);
    await customerApi.logout();
    await _clearSession();
  }

  Future<void> _persistSession({required String phone, required String name}) async {
    await apiClient.secureStorage.write(key: SecureStorageKeys.userPhone, value: phone);
    await apiClient.secureStorage.write(key: SecureStorageKeys.userName, value: name);
    unawaited(apiClient.startLive());
    _user = AuthUser(phone: phone, name: name);
    _startAccountCheck();
    notifyListeners();
  }

  /// Signs out and shows the login screen with [message] (verification: too
  /// many wrong PINs, the password is then the only way in).
  Future<void> logoutToLogin(String message) async {
    await logout();
    navigatorKey?.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(message: message)),
      (route) => false,
    );
  }

  /// How often a signed-in phone asks the server whether the account is still open (a block is also seen
  /// at once by any call the app makes, and when the wallet changes live).
  static const _accountCheckEvery = Duration(seconds: 20);
  Timer? _accountCheck;

  void _startAccountCheck() {
    _accountCheck?.cancel();
    _accountCheck = Timer.periodic(_accountCheckEvery, (_) => checkAccount());
  }

  /// Asks the server; a blocked account signs this phone out through [onAccountBlocked].
  Future<void> checkAccount() async {
    if (_user == null) return;
    try {
      await customerApi.verifySession();
    } catch (_) {
      // Blocked: handled by the api client. Offline or anything else: try again later.
    }
  }

  /// For tests: signed in as [user] without a server.
  @visibleForTesting
  void debugSignIn(AuthUser user) {
    _user = user;
    notifyListeners();
  }

  /// The administrator blocked this account: this phone is signed out (the server already ended every
  /// session on every device) and the login screen shows the Account Blocked card. Nothing of the
  /// customer's data is touched.
  void _handleAccountBlocked() {
    if (_user == null) return;
    unawaited(() async {
      _accountCheck?.cancel();
      await BlockedMemory.mark(); // the next accepted login means it was unblocked
      try {
        await customerApi.logout();
      } catch (_) {}
      await _clearSession();
      navigatorKey?.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen(blocked: true)),
        (route) => false,
      );
    }());
  }

  Future<void> _clearSession() async {
    _accountCheck?.cancel();
    // The PIN and fingerprint choice belong to this sign-in only.
    await _appLock.disable();
    await apiClient.secureStorage.delete(key: SecureStorageKeys.userPhone);
    await apiClient.secureStorage.delete(key: SecureStorageKeys.userName);
    // Tokens written by app versions that used the old REST backend.
    await apiClient.secureStorage.delete(key: 'accessToken');
    await apiClient.secureStorage.delete(key: 'refreshToken');
    _user = null;
    notifyListeners();
  }

  /// The account was opened on another phone: this phone signs out (its
  /// own session only) and shows why.
  void _handleSessionReplaced() {
    if (_user == null) return;
    unawaited(() async {
      await customerApi.logout();
      await _clearSession();
      navigatorKey?.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => LoginScreen(message: AppStrings.openedOnAnotherPhone)),
        (route) => false,
      );
    }());
  }

  void _handleSessionExpired() {
    // Fire and forget: clears storage + user, notifies listeners, and (if
    // we have a navigator to reach) bounces straight back to the login
    // screen even if this happened deep inside some other flow.
    unawaited(_clearSession().then((_) {
      final navState = navigatorKey?.currentState;
      if (navState == null) return;
      navState.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }));
  }
}
