import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Storage keys used across the app. Centralized here since both
/// [ApiClient] (token refresh) and `AuthProvider` (session bookkeeping)
/// read/write them.
class SecureStorageKeys {
  SecureStorageKeys._();

  static const String accessToken = 'accessToken';
  static const String refreshToken = 'refreshToken';
  static const String userPhone = 'userPhone';
  static const String userName = 'userName';
}

/// Thin HTTP client for the Badal Exchange backend.
///
/// Responsibilities:
///  - attaches `Authorization: Bearer <accessToken>` to every request,
///  - transparently refreshes the access token on a 401 and retries the
///    request exactly once,
///  - normalizes backend errors (`{error:{code,message,details}}`) and
///    network failures into [ApiException].
///
/// Tokens are persisted in [FlutterSecureStorage] -- never in plain
/// SharedPreferences.
class ApiClient {
  ApiClient({required this.baseUrl, FlutterSecureStorage? secureStorage, http.Client? httpClient})
      : secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final FlutterSecureStorage secureStorage;
  final http.Client _http;

  /// Called when a refresh attempt fails (refresh token missing/expired),
  /// so the app can drop the user back to the login screen. Set by
  /// `AuthProvider`.
  void Function()? onSessionExpired;

  Future<dynamic> get(String path) => _send('GET', path);

  Future<dynamic> post(String path, {Map<String, dynamic>? body, String? idempotencyKey}) =>
      _send('POST', path, body: body, idempotencyKey: idempotencyKey);

  Future<Map<String, String>> _headers({String? idempotencyKey}) async {
    final token = await secureStorage.read(key: SecureStorageKeys.accessToken);
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? idempotencyKey,
    bool isRetryAfterRefresh = false,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = await _headers(idempotencyKey: idempotencyKey);
    final encodedBody = body != null ? jsonEncode(body) : null;

    http.Response response;
    try {
      switch (method) {
        case 'GET':
          response = await _http.get(uri, headers: headers);
          break;
        case 'POST':
          response = await _http.post(uri, headers: headers, body: encodedBody);
          break;
        default:
          throw UnsupportedError('Unsupported HTTP method: $method');
      }
    } catch (_) {
      throw const ApiException(
        status: 0,
        code: 'NETWORK_ERROR',
        message: 'Could not reach the server. Check your internet connection and try again.',
      );
    }

    if (response.statusCode == 401 && !isRetryAfterRefresh && path != '/auth/refresh') {
      final refreshed = await _tryRefreshToken();
      if (refreshed) {
        return _send(
          method,
          path,
          body: body,
          idempotencyKey: idempotencyKey,
          isRetryAfterRefresh: true,
        );
      }
      onSessionExpired?.call();
      throw const ApiException(
        status: 401,
        code: 'SESSION_EXPIRED',
        message: 'Your session has expired. Please log in again.',
      );
    }

    return _parse(response);
  }

  dynamic _parse(http.Response response) {
    dynamic decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    final errorObj = (decoded is Map && decoded['error'] is Map)
        ? decoded['error'] as Map<dynamic, dynamic>
        : const <dynamic, dynamic>{};

    throw ApiException(
      status: response.statusCode,
      code: (errorObj['code'] as String?) ?? 'UNKNOWN_ERROR',
      message: (errorObj['message'] as String?) ?? 'Something went wrong. Please try again.',
      details: errorObj['details'],
    );
  }

  Future<bool> _tryRefreshToken() async {
    final refreshToken = await secureStorage.read(key: SecureStorageKeys.refreshToken);
    if (refreshToken == null) return false;

    try {
      final uri = Uri.parse('$baseUrl/auth/refresh');
      final response = await _http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': refreshToken}),
      );
      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final newAccessToken = data['accessToken'] as String?;
      final newRefreshToken = data['refreshToken'] as String?;
      if (newAccessToken == null || newRefreshToken == null) return false;

      await secureStorage.write(key: SecureStorageKeys.accessToken, value: newAccessToken);
      await secureStorage.write(key: SecureStorageKeys.refreshToken, value: newRefreshToken);
      return true;
    } catch (_) {
      return false;
    }
  }
}
