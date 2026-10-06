/// App-wide configuration: the Supabase project BAARI's backend runs on.
///
/// Set at build time:
///   flutter build apk --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
///                     --dart-define=SUPABASE_ANON_KEY=<publishable/anon key>
///
/// The publishable (anon) key only identifies the project and is meant to
/// ship inside apps; what a user can see and do is decided by their login
/// and the database's own permission checks and row level security. For a
/// local stack (`supabase start`) an Android emulator reaches the host at
/// http://10.0.2.2:54321.
class AppConfig {
  AppConfig._();

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://onbezsojnpsrtuxzwsjr.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static const Duration requestTimeout = Duration(seconds: 20);
}
