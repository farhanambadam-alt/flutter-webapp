import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/auth_config.dart';

/// Thin wrapper around the official [supabase_flutter] SDK for native OAuth.
///
/// Handles Google sign-in via PKCE (RFC 8252 compliant), session lifecycle,
/// and exposes the auth state stream for the WebView bridge.
class NativeAuthService {
  SupabaseClient get _client => Supabase.instance.client;

  // ── Public getters ────────────────────────────────────────────────────────

  Session? get currentSession => _client.auth.currentSession;
  User? get currentUser => _client.auth.currentUser;
  bool get isAuthenticated => currentSession != null;

  /// The raw auth state stream from Supabase.
  Stream<AuthState> get onAuthStateChange => _client.auth.onAuthStateChange;

  // ── Google Sign-In (PKCE, external browser) ───────────────────────────────

  /// Opens Chrome Custom Tabs / SFSafariViewController for Google OAuth.
  ///
  /// Returns `true` if the browser was launched successfully.
  /// The actual session arrives asynchronously via [onAuthStateChange].
  ///
  /// Cancellation (user closes the browser) is caught silently and returns
  /// `false` — it is a normal user action, not an error.
  Future<bool> performNativeGoogleLogin() async {
    try {
      debugPrint('[NativeAuth] Starting Google sign-in via PKCE');
      final launched = await _client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: AuthConfig.redirectUri,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      debugPrint('[NativeAuth] signInWithOAuth launched: $launched');
      return launched;
    } on AuthException catch (e) {
      if (_isCancellation(e.message)) {
        debugPrint('[NativeAuth] User cancelled sign-in');
        return false;
      }
      debugPrint('[NativeAuth] AuthException: ${e.message}');
      rethrow;
    } on PlatformException catch (e) {
      if (_isCancellation(e.message ?? '')) {
        debugPrint('[NativeAuth] User cancelled sign-in');
        return false;
      }
      debugPrint('[NativeAuth] PlatformException: ${e.message}');
      rethrow;
    } catch (e) {
      if (_isCancellation(e.toString())) {
        debugPrint('[NativeAuth] User cancelled sign-in');
        return false;
      }
      debugPrint('[NativeAuth] Unexpected error: $e');
      rethrow;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  /// Signs out both the native Supabase session and clears persisted state.
  Future<void> performNativeSignOut() async {
    try {
      debugPrint('[NativeAuth] Signing out');
      await _client.auth.signOut();
      debugPrint('[NativeAuth] Sign-out complete');
    } catch (e) {
      debugPrint('[NativeAuth] Sign-out error: $e');
      rethrow;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _isCancellation(String message) {
    final lower = message.toLowerCase();
    return lower.contains('cancel') ||
        lower.contains('user_cancelled') ||
        lower.contains('dismissed');
  }
}
