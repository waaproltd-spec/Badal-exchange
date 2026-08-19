/// Backend base URL.
///
/// During development against the backend started with `npm run dev` in
/// `backend/` (listening on http://localhost:4000), an Android emulator
/// reaches the host machine's localhost via the special alias 10.0.2.2, not
/// `localhost` itself — hence the default below. A physical device on the
/// same network would instead need the host machine's LAN IP, and a real
/// deployment needs the production backend's HTTPS URL.
///
/// Override at build/run time with:
///   flutter run --dart-define=API_BASE_URL=https://api.badalexchange.example
class ApiConfig {
  ApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:4000',
  );

  static const Duration requestTimeout = Duration(seconds: 20);
}
