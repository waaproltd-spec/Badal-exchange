/// App-wide configuration.
class AppConfig {
  AppConfig._();

  /// Base URL of the Badal Exchange backend.
  ///
  /// Override at build/run time with:
  ///   flutter run --dart-define=API_BASE_URL=http://YOUR_HOST:4000
  ///
  /// Defaults to 10.0.2.2, which is how the Android emulator reaches the
  /// host machine's localhost. Point this at a real deployed backend URL
  /// for a physical device or production build.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:4000',
  );
}
