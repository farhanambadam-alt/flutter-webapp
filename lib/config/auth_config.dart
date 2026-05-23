/// Central configuration for the Supabase native auth bridge.
class AuthConfig {
  AuthConfig._();

  /// Supabase project URL.
  static const String supabaseUrl =
      'https://pcilcojzvipbfagofriq.supabase.co';

  /// Supabase anonymous / public key.
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBjaWxjb2p6dmlwYmZhZ29mcmlxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcwNTA3MzQsImV4cCI6MjA5MjYyNjczNH0.U7yKZu3jD1bb3zSBC-NWchX02BiSJiDCqMgerCRNHno';

  /// The custom-scheme redirect URI registered in Supabase Dashboard.
  static const String redirectUri = 'com.keshzo.app://login-callback';

  /// Just the scheme portion (no "://") — used to detect auth callbacks
  /// in the deep link handler.
  static const String callbackScheme = 'com.keshzo.app';
}
