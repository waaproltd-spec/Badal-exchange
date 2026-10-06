import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_config.dart';
import 'api_exception.dart';

/// Thin client over the BAARI Supabase backend.
///
///  - Supabase Auth holds the session (kept in the platform keystore via
///    [SecureSessionStorage]) and refreshes it automatically;
///  - every backend call is a Postgres function called with [rpc]; their
///    errors carry the app error code in `hint` and become the same
///    [ApiException] the REST backend produced;
///  - [onSessionExpired] fires when the session ends without the user logging
///    out (refresh token revoked, account disabled), so the UI can show the
///    login screen.
class ApiClient {
  ApiClient({SupabaseClient? supabase}) : _supabase = supabase;

  SupabaseClient? _supabase;
  StreamSubscription<AuthState>? _authSub;
  bool _loggingOut = false;

  void Function()? onSessionExpired;

  static Future<void> initialize() async {
    if (ApiConfig.supabaseAnonKey.isEmpty) {
      debugPrint('SUPABASE_ANON_KEY is not set; build with --dart-define=SUPABASE_ANON_KEY=...');
    }
    await Supabase.initialize(
      url: ApiConfig.supabaseUrl,
      publishableKey: ApiConfig.supabaseAnonKey.isEmpty ? 'missing-anon-key' : ApiConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        localStorage: SecureSessionStorage('badal_agent_supabase_session'),
        autoRefreshToken: true,
      ),
    );
  }

  SupabaseClient get supabase {
    final client = _supabase ??= Supabase.instance.client;
    _authSub ??= client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut && !_loggingOut) {
        onSessionExpired?.call();
      }
    });
    return client;
  }

  bool get hasSession => supabase.auth.currentSession != null;

  String? get userId => supabase.auth.currentUser?.id;

  /// Calls a backend function. Returns its JSON result (Map, List or null).
  Future<dynamic> rpc(String function, [Map<String, dynamic>? params]) {
    return guard(() => supabase.rpc(function, params: params).timeout(ApiConfig.requestTimeout));
  }

  Future<void> signIn({required String identifier, required String password}) async {
    await guard(() => supabase.auth
        .signInWithPassword(email: authEmailFor(identifier), password: password)
        .timeout(ApiConfig.requestTimeout));
  }

  Future<void> signOut() async {
    _loggingOut = true;
    try {
      await supabase.auth.signOut();
    } catch (_) {
      // Local session is cleared regardless.
    } finally {
      _loggingOut = false;
    }
  }

  /// Runs a Supabase call and maps every failure to [ApiException].
  static Future<T> guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PostgrestException catch (e) {
      throw ApiException(statusCode: _statusFor(e.code), code: e.hint ?? e.code ?? 'ERROR', message: e.message);
    } on AuthException catch (e) {
      final code = e.code ?? '';
      if (code == 'user_banned') {
        throw const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Account is disabled');
      }
      if (code == 'invalid_credentials' || e.statusCode == '400') {
        throw const ApiException(statusCode: 401, code: 'UNAUTHORIZED', message: 'Invalid credentials');
      }
      if (code == 'over_request_rate_limit') {
        throw const ApiException(statusCode: 429, code: 'RATE_LIMITED', message: 'Too many attempts, try again later.');
      }
      throw ApiException(statusCode: int.tryParse(e.statusCode ?? '') ?? 401, code: 'UNAUTHORIZED', message: e.message);
    } on SocketException {
      throw ApiException.network('Could not reach the server. Check your connection.');
    } on TimeoutException {
      throw ApiException.network('The request timed out. Please try again.');
    } on HttpException catch (e) {
      throw ApiException.network(e.message);
    } on ApiException {
      rethrow;
    } catch (e) {
      final text = e.toString();
      if (text.contains('SocketException') || text.contains('ClientException') || text.contains('Failed host lookup')) {
        throw ApiException.network('Could not reach the server. Check your connection.');
      }
      rethrow;
    }
  }

  /// SQLSTATE 'PTxyz' from the backend means HTTP status xyz.
  static int _statusFor(String? sqlState) {
    if (sqlState != null && sqlState.startsWith('PT')) {
      return int.tryParse(sqlState.substring(2)) ?? 400;
    }
    if (sqlState == '42501') return 403; // permission denied
    if (sqlState == 'PGRST301' || sqlState == 'PGRST302') return 401;
    return 400;
  }
}

/// The Supabase Auth login address for a phone number (or an email, used
/// as-is). Must match private.auth_email() in the database.
String authEmailFor(String identifier) {
  final trimmed = identifier.trim();
  if (trimmed.contains('@')) return trimmed.toLowerCase();
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  final local = digits.length >= 4
      ? digits
      : 'x${trimmed.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join()}';
  return '$local@phone.baari.invalid';
}

/// Keeps the Supabase session in the platform keystore/keychain rather than
/// plain shared preferences: it is a bearer credential for a money-moving
/// account.
class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage(this.key);

  final String key;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: key);

  @override
  Future<String?> accessToken() => _storage.read(key: key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: key);
}
