/// Typed error surfaced from the API client. Wraps the backend's
/// `{error:{code,message,details}}` shape (or a local network failure) so
/// screens can always show `message` to the user and branch on `code` when
/// they need to (e.g. INSUFFICIENT_BALANCE, DUPLICATE_WITHDRAWAL).
class ApiException implements Exception {
  const ApiException({
    required this.status,
    required this.code,
    required this.message,
    this.details,
  });

  /// HTTP status code, or 0 for a local/network failure (no response).
  final int status;
  final String code;
  final String message;
  final dynamic details;

  @override
  String toString() => 'ApiException(status: $status, code: $code, message: $message)';
}
