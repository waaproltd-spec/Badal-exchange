import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'api_exception.dart';

/// Storage keys for what the app remembers about the signed-in customer.
/// The session itself is kept by Supabase Auth ([SecureSessionStorage]).
class SecureStorageKeys {
  SecureStorageKeys._();

  static const String userPhone = 'userPhone';
  static const String userName = 'userName';
}

/// Thin client over the BAARI Supabase backend.
///
///  - Supabase Auth holds the session (in the platform keystore, never plain
///    SharedPreferences) and refreshes it automatically;
///  - every backend call is a Postgres function called with [rpc]; errors
///    carry the app error code (e.g. INSUFFICIENT_BALANCE) in `hint` and are
///    normalized, like network failures, into [ApiException];
///  - [liveChanges] streams Realtime changes to the customer's own orders and
///    wallet, and new notifications, while signed in.
class ApiClient {
  ApiClient({SupabaseClient? supabase, FlutterSecureStorage? secureStorage})
      : _supabase = supabase,
        secureStorage = secureStorage ?? const FlutterSecureStorage();

  SupabaseClient? _supabase;
  final FlutterSecureStorage secureStorage;
  StreamSubscription<AuthState>? _authSub;
  bool _loggingOut = false;
  RealtimeChannel? _liveChannel;
  final _live = StreamController<String>.broadcast();

  /// Called when the session ends without the user logging out (refresh
  /// token revoked, account disabled), so the app can show the login
  /// screen. Set by `AuthProvider`.
  void Function()? onSessionExpired;

  static Future<void> initialize() async {
    if (AppConfig.supabaseAnonKey.isEmpty) {
      debugPrint('SUPABASE_ANON_KEY is not set; build with --dart-define=SUPABASE_ANON_KEY=...');
    }
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey.isEmpty ? 'missing-anon-key' : AppConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        localStorage: SecureSessionStorage('baari_customer_supabase_session'),
        autoRefreshToken: true,
      ),
    );
  }

  SupabaseClient get supabase {
    final client = _supabase ??= Supabase.instance.client;
    _authSub ??= client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut && !_loggingOut) {
        stopLive();
        onSessionExpired?.call();
      }
    });
    return client;
  }

  bool get hasSession => supabase.auth.currentSession != null;

  /// Emits 'orders', 'wallets' or 'notifications' when one changes.
  Stream<String> get liveChanges => _live.stream;

  /// Calls a backend function. Returns its JSON result (Map, List or null).
  Future<dynamic> rpc(String function, [Map<String, dynamic>? params]) {
    return guard(() => supabase.rpc(function, params: params).timeout(AppConfig.requestTimeout));
  }

  Future<void> signIn({required String phone, required String password}) async {
    await guard(() => supabase.auth
        .signInWithPassword(email: authEmailFor(phone), password: password)
        .timeout(AppConfig.requestTimeout));
  }

  Future<void> signOut() async {
    _loggingOut = true;
    try {
      stopLive();
      await supabase.auth.signOut();
    } catch (_) {
      // Local session is cleared regardless.
    } finally {
      _loggingOut = false;
    }
  }

  void startLive() {
    final uid = supabase.auth.currentUser?.id;
    if (_liveChannel != null || uid == null) return;
    final filter = PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'customer_id', value: uid);
    _liveChannel = supabase
        .channel('customer-live-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: filter,
          callback: (_) => _live.add('orders'),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'wallets',
          filter: filter,
          callback: (_) => _live.add('wallets'),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          callback: (_) => _live.add('notifications'),
        )
        .subscribe();
  }

  void stopLive() {
    final channel = _liveChannel;
    _liveChannel = null;
    if (channel != null) unawaited(supabase.removeChannel(channel));
  }

  /// Runs a Supabase call and maps every failure to [ApiException].
  static Future<T> guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PostgrestException catch (e) {
      throw ApiException(status: _statusFor(e.code), code: e.hint ?? e.code ?? 'ERROR', message: e.message, details: e.details);
    } on AuthException catch (e) {
      final code = e.code ?? '';
      if (code == 'user_banned') {
        throw const ApiException(status: 403, code: 'FORBIDDEN', message: 'Account is disabled');
      }
      if (code == 'invalid_credentials' || e.statusCode == '400') {
        throw const ApiException(status: 401, code: 'UNAUTHORIZED', message: 'Invalid credentials');
      }
      if (code == 'over_request_rate_limit') {
        throw const ApiException(status: 429, code: 'RATE_LIMITED', message: 'Too many attempts, try again later.');
      }
      throw ApiException(status: int.tryParse(e.statusCode ?? '') ?? 401, code: 'UNAUTHORIZED', message: e.message);
    } on ApiException {
      rethrow;
    } on SocketException {
      throw _network;
    } on TimeoutException {
      throw _network;
    } catch (e) {
      final text = e.toString();
      if (text.contains('SocketException') || text.contains('ClientException') || text.contains('Failed host lookup')) {
        throw _network;
      }
      rethrow;
    }
  }

  static const _network = ApiException(
    status: 0,
    code: 'NETWORK_ERROR',
    message: 'Could not reach the server. Check your internet connection and try again.',
  );

  /// SQLSTATE 'PTxyz' from the backend means HTTP status xyz.
  static int _statusFor(String? sqlState) {
    if (sqlState != null && sqlState.startsWith('PT')) {
      return int.tryParse(sqlState.substring(2)) ?? 400;
    }
    if (sqlState == '42501') return 403;
    if (sqlState == 'PGRST301' || sqlState == 'PGRST302') return 401;
    return 400;
  }
}

/// The Supabase Auth login address for a phone number. Must match
/// private.auth_email() in the database.
String authEmailFor(String identifier) {
  final trimmed = identifier.trim();
  if (trimmed.contains('@')) return trimmed.toLowerCase();
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  final local = digits.length >= 4
      ? digits
      : 'x${trimmed.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join()}';
  return '$local@phone.baari.invalid';
}

/// Keeps the Supabase session in the platform keystore/keychain.
class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage(this.key);

  final String key;

  static const _storage = FlutterSecureStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: key);

  @override
  Future<String?> accessToken() => _storage.read(key: key);

  @override
  Future<void> persistSession(String persistSessionString) => _storage.write(key: key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: key);
}
