import '../models/mobile_auth_models.dart';

/// Maps backend error codes from the `mobile-auth-handshake` edge function to
/// user-friendly messages and determines retry behaviour.
class AuthErrorHandler {
  AuthErrorHandler._();

  /// User-facing messages keyed by backend error code.
  static const Map<String, String> _userMessages = {
    'method_not_allowed': 'Something went wrong. Please try again.',
    'invalid_json': 'Something went wrong. Please try again.',
    'invalid_action': 'Something went wrong. Please try again.',
    'invalid_start_request': 'Unable to start sign-in. Please try again.',
    'start_failed': 'Unable to start sign-in. Please try again.',
    'invalid_exchange_request': 'Sign-in failed. Please try again.',
    'handshake_not_found': 'Sign-in session expired. Please try again.',
    'handshake_consumed':
        'This sign-in link was already used. Please start over.',
    'handshake_expired': 'Sign-in session expired. Please try again.',
    'platform_mismatch': 'Platform mismatch. Please try again.',
    'exchange_failed':
        'Sign-in could not be completed. Please try again.',
    'missing_code': 'Sign-in failed. Please try again.',
    'missing_code_verifier': 'Sign-in failed. Please try again.',
    'missing_id_token': 'Apple Sign-In failed. Please try again.',
    'invalid_redirect_uri': 'Configuration error. Please contact support.',
  };

  /// Returns a user-friendly message for the given [error].
  static String userMessage(MobileAuthError? error) {
    if (error == null) return 'An unexpected error occurred. Please try again.';
    return _userMessages[error.code] ??
        (error.message.isNotEmpty
            ? error.message
            : 'An unexpected error occurred. Please try again.');
  }

  /// Returns `true` when the caller should automatically retry the request
  /// (at most once).
  static bool shouldAutoRetry(MobileAuthError? error) {
    return error?.retryable == true;
  }

  /// Returns `true` when the entire auth flow must be restarted from scratch
  /// (e.g. handshake consumed / expired).
  static bool shouldRestartFlow(MobileAuthError? error) {
    if (error == null) return true;
    const restartCodes = {
      'handshake_not_found',
      'handshake_consumed',
      'handshake_expired',
      'platform_mismatch',
    };
    return restartCodes.contains(error.code);
  }
}
