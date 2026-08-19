import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/customer_api.dart';
import '../models/auth_user.dart';
import '../screens/auth/login_screen.dart';

/// Session state: current user, and the login/register/logout flows.
/// Tokens themselves live only in secure storage (via [ApiClient]) -- this
/// class never holds a raw token in memory beyond the moment it's written.
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
      final token = await apiClient.secureStorage.read(key: SecureStorageKeys.accessToken);
      final phone = await apiClient.secureStorage.read(key: SecureStorageKeys.userPhone);
      final name = await apiClient.secureStorage.read(key: SecureStorageKeys.userName);
      if (token != null && phone != null) {
        _user = AuthUser(phone: phone, name: name ?? '');
      }
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> login({required String phone, required String password}) async {
    final result = await customerApi.login(phone: phone, password: password);
    final resolvedName = result.name.isNotEmpty ? result.name : phone;
    await _persistSession(
      phone: phone,
      name: resolvedName,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
    );
  }

  Future<void> register({
    required String phone,
    required String name,
    required String password,
  }) async {
    final result = await customerApi.register(phone: phone, name: name, password: password);
    await _persistSession(
      phone: phone,
      name: name,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
    );
  }

  Future<void> logout() async {
    final refreshToken = await apiClient.secureStorage.read(key: SecureStorageKeys.refreshToken);
    if (refreshToken != null) {
      try {
        await customerApi.logout(refreshToken: refreshToken);
      } catch (_) {
        // Best-effort: still clear the local session even if the network
        // call fails.
      }
    }
    await _clearSession();
  }

  Future<void> _persistSession({
    required String phone,
    required String name,
    required String accessToken,
    required String refreshToken,
  }) async {
    await apiClient.secureStorage.write(key: SecureStorageKeys.accessToken, value: accessToken);
    await apiClient.secureStorage.write(key: SecureStorageKeys.refreshToken, value: refreshToken);
    await apiClient.secureStorage.write(key: SecureStorageKeys.userPhone, value: phone);
    await apiClient.secureStorage.write(key: SecureStorageKeys.userName, value: name);
    _user = AuthUser(phone: phone, name: name);
    notifyListeners();
  }

  Future<void> _clearSession() async {
    await apiClient.secureStorage.deleteAll();
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
