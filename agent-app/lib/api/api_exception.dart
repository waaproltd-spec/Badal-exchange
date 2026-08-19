/// Thrown by [ApiClient] when the backend returns a non-2xx response, using
/// the `{error:{code,message}}` envelope shared by every route in
/// backend/src/server.ts's error handler.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  bool get isUnauthorized => statusCode == 401;
  bool get isNetworkError => statusCode == 0;

  factory ApiException.network(String message) {
    return ApiException(statusCode: 0, code: 'NETWORK_ERROR', message: message);
  }

  @override
  String toString() => message;
}
