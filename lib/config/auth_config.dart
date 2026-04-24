/// Central configuration for the native OAuth handshake.
///
/// Replace [supabaseAnonKey] with your real Supabase anon key before testing.
class AuthConfig {
  AuthConfig._();

  /// Supabase Edge Function endpoint for mobile OAuth handshake.
  static const String edgeFunctionUrl =
      'https://pcilcojzvipbfagofriq.supabase.co/functions/v1/mobile-auth-handshake';

  /// Supabase anonymous / public key.
  /// ⚠️  Replace this placeholder with your real anon key.
  static const String supabaseAnonKey = 'YOUR_SUPABASE_ANON_KEY';

  /// The custom-scheme redirect URI registered in Supabase dashboard.
  static const String redirectUri = 'com.example.chicsalon://login-callback';

  /// Just the scheme portion (no "://") — used by flutter_web_auth_2 to detect
  /// the callback.
  static const String callbackScheme = 'com.example.chicsalon';
}
