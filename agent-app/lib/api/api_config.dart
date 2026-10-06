/// Supabase project the app talks to (BAARI's backend).
///
/// Set at build time:
///   flutter build apk --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
///                     --dart-define=SUPABASE_ANON_KEY=<publishable/anon key>
///
/// The anon (publishable) key is designed to ship inside apps: it only
/// identifies the project. What a user can see and do is decided by their
/// login and the database's own permission checks and row level security.
/// For a local stack (`supabase start`), an Android emulator reaches the host
/// at http://10.0.2.2:54321.
class ApiConfig {
  ApiConfig._();

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://onbezsojnpsrtuxzwsjr.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static const Duration requestTimeout = Duration(seconds: 20);
}
