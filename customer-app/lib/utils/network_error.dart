import '../api/api_exception.dart';

/// Is this failure the phone's connection (no internet, weak signal, a timeout, DNS), not the server's
/// answer? Such a failure is shown with the friendly internet message only: never the technical text
/// (SocketException, a Supabase address, DNS errors).
bool isNetworkError(Object? error) {
  if (error == null) return false;
  if (error is ApiException) return error.code == 'NETWORK_ERROR';
  final text = error.toString();
  const marks = [
    'SocketException',
    'ClientException',
    'HandshakeException',
    'TlsException',
    'HttpException',
    'TimeoutException',
    'AuthRetryableFetchException',
    'Failed host lookup',
    'Network is unreachable',
    'Connection refused',
    'Connection reset',
    'Connection closed',
    'Connection timed out',
    'No address associated',
    'Software caused connection abort',
    'errno =',
  ];
  return marks.any(text.contains);
}
