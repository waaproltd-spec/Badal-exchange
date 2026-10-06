import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../models/auth_user.dart';
import '../screens/auth/login_screen.dart';

/// Session state: current user, and the login/register/logout flows.
/// The session tokens are held by Supabase Auth (in secure storage); this
/// class never handles a raw token.
class AuthProvider extends ChangeNotifier {
  AuthProvider({required this.apiClient, required this.customerApi, this.navigatorKey}) {
    apiClient.onSessionExpired = _handleSessionExpired;
  }

  final ApiClient apiClient;
  final CustomerApi customerApi;

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
      if (apiClient.hasSession && phone != null) {
        _user = AuthUser(phone: phone, name: name ?? '');
        unawaited(apiClient.startLive());
        unawaited(_verifyRestoredSession());
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

  Future<void> register({
    required String phone,
    required String name,
    required String password,
  }) async {
    await customerApi.register(phone: phone, name: name, password: password);
    await _persistSession(phone: phone, name: name);
  }

  Future<void> logout() async {
    await customerApi.logout();
    await _clearSession();
  }

  Future<void> _persistSession({required String phone, required String name}) async {
    await apiClient.secureStorage.write(key: SecureStorageKeys.userPhone, value: phone);
    await apiClient.secureStorage.write(key: SecureStorageKeys.userName, value: name);
    unawaited(apiClient.startLive());
    _user = AuthUser(phone: phone, name: name);
    notifyListeners();
  }

  Future<void> _clearSession() async {
    await apiClient.secureStorage.delete(key: SecureStorageKeys.userPhone);
    await apiClient.secureStorage.delete(key: SecureStorageKeys.userName);
    // Tokens written by app versions that used the old REST backend.
    await apiClient.secureStorage.delete(key: 'accessToken');
    await apiClient.secureStorage.delete(key: 'refreshToken');
    _user = null;
    notifyListeners();
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
