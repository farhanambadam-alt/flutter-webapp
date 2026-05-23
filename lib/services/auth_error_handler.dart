import 'package:supabase_flutter/supabase_flutter.dart';

/// Maps Supabase auth errors to user-friendly messages.
class AuthErrorHandler {
  AuthErrorHandler._();

  /// Returns a short, user-friendly message for the given [error].
  ///
  /// Never exposes raw exception text to the user.
  static String userMessage(Object? error) {
    if (error == null) return 'An unexpected error occurred. Please try again.';

    if (error is AuthException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('cancel') || msg.contains('dismissed')) {
        return 'Sign-in was cancelled.';
      }
      if (msg.contains('network') || msg.contains('timeout') || msg.contains('socket')) {
        return 'Network error. Please check your connection and try again.';
      }
      if (msg.contains('invalid') || msg.contains('expired')) {
        return 'Sign-in failed. Please try again.';
      }
      // Surface Supabase's own message if it looks user-safe
      if (error.message.length < 120 && !msg.contains('exception')) {
        return error.message;
      }
    }

    return 'An unexpected error occurred. Please try again.';
  }

  /// Returns `true` when the caller should automatically retry.
  static bool shouldAutoRetry(Object? error) {
    if (error is AuthException) {
      final msg = error.message.toLowerCase();
      return msg.contains('network') || msg.contains('timeout');
    }
    return false;
  }
}
