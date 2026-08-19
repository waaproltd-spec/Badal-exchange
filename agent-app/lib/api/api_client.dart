import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_config.dart';
import 'api_exception.dart';
import 'token_storage.dart';

/// Thin HTTP client wrapping the Badal Exchange backend.
///
/// Responsibilities:
///  - attaches `Authorization: Bearer <accessToken>` to every request except
///    login/refresh;
///  - on a 401 from an authenticated request, attempts exactly one silent
///    refresh via POST /auth/refresh and retries the original request once;
///  - if the refresh itself fails, clears the stored session so the app can
///    route the agent back to the login screen;
///  - parses the backend's `{error:{code,message}}` envelope into
///    [ApiException].
///
/// A callback [onSessionExpired] is invoked when refresh fails, so the UI
/// layer can navigate to the login screen without this client needing to
/// know about navigation.
class ApiClient {
  ApiClient({http.Client? httpClient, TokenStorage? tokenStorage})
      : _http = httpClient ?? http.Client(),
        _tokens = tokenStorage ?? TokenStorage.instance;

  final http.Client _http;
  final TokenStorage _tokens;

  /// Invoked when a refresh attempt fails and the session must be
  /// considered logged out. Set this from app startup (see main.dart).
  void Function()? onSessionExpired;

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('${ApiConfig.baseUrl}$path').replace(queryParameters: query);
  }

  Map<String, String> _jsonHeaders({String? bearer, String? idempotencyKey}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (bearer != null) headers['Authorization'] = 'Bearer $bearer';
    if (idempotencyKey != null) headers['Idempotency-Key'] = idempotencyKey;
    return headers;
  }

  /// Public unauthenticated POST — used for /auth/agent/login and
  /// /auth/refresh only.
  Future<Map<String, dynamic>> postPublic(String path, Map<String, dynamic> body) async {
    final res = await _send(() => _http
        .post(_uri(path), headers: _jsonHeaders(), body: jsonEncode(body))
        .timeout(ApiConfig.requestTimeout));
    return _decodeOrThrow(res);
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    return _authedRequest((bearer) => _http
        .get(_uri(path, query), headers: _jsonHeaders(bearer: bearer))
        .timeout(ApiConfig.requestTimeout));
  }

  Future<dynamic> post(
    String path, {
    Map<String, dynamic>? body,
    String? idempotencyKey,
  }) async {
    return _authedRequest((bearer) => _http
        .post(
          _uri(path),
          headers: _jsonHeaders(bearer: bearer, idempotencyKey: idempotencyKey),
          body: jsonEncode(body ?? const {}),
        )
        .timeout(ApiConfig.requestTimeout));
  }

  Future<dynamic> _authedRequest(
    Future<http.Response> Function(String bearer) request,
  ) async {
    final accessToken = await _tokens.accessToken;
    if (accessToken == null) {
      throw const ApiException(statusCode: 401, code: 'NO_SESSION', message: 'Not logged in');
    }

    var res = await _send(() => request(accessToken));

    if (res.statusCode == 401) {
      final refreshed = await _tryRefresh();
      if (refreshed != null) {
        res = await _send(() => request(refreshed));
      } else {
        onSessionExpired?.call();
      }
    }

    return _decodeOrThrow(res);
  }

  /// Attempts a single refresh using the stored refresh token. Returns the
  /// new access token on success, or null (and clears the session) on
  /// failure.
  Future<String?> _tryRefresh() async {
    final refreshToken = await _tokens.refreshToken;
    if (refreshToken == null) {
      await _tokens.clear();
      return null;
    }
    try {
      final res = await _send(() => _http
          .post(
            _uri('/auth/refresh'),
            headers: _jsonHeaders(),
            body: jsonEncode({'refreshToken': refreshToken}),
          )
          .timeout(ApiConfig.requestTimeout));
      if (res.statusCode != 200) {
        await _tokens.clear();
        return null;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final newAccess = data['accessToken'] as String?;
      final newRefresh = data['refreshToken'] as String?;
      if (newAccess == null || newRefresh == null) {
        await _tokens.clear();
        return null;
      }
      await _tokens.saveTokens(accessToken: newAccess, refreshToken: newRefresh);
      return newAccess;
    } catch (_) {
      await _tokens.clear();
      return null;
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() fn) async {
    try {
      return await fn();
    } on SocketException {
      throw ApiException.network('Could not reach the server. Check your connection.');
    } on TimeoutException {
      throw ApiException.network('The request timed out. Please try again.');
    } on http.ClientException catch (e) {
      throw ApiException.network(e.message);
    }
  }

  dynamic _decodeOrThrow(http.Response res) {
    final status = res.statusCode;
    dynamic decoded;
    if (res.body.isNotEmpty) {
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        decoded = null;
      }
    }

    if (status >= 200 && status < 300) {
      return decoded;
    }

    String code = 'ERROR';
    String message = 'Request failed ($status)';
    if (decoded is Map<String, dynamic> && decoded['error'] is Map<String, dynamic>) {
      final err = decoded['error'] as Map<String, dynamic>;
      code = (err['code'] as String?) ?? code;
      message = (err['message'] as String?) ?? message;
    }
    throw ApiException(statusCode: status, code: code, message: message);
  }
}
