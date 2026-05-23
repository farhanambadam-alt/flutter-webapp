import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps [FlutterSecureStorage] to persist and restore supplementary
/// auth data (e.g. custom metadata or refresh tokens).
///
/// Note: Primary session persistence is handled by `supabase_flutter` itself.
/// This class is kept for secure storage of any auxiliary data the app may
/// need (e.g. device tokens, push notification state, etc.).
class SecureSessionStorage {
  static const _keyAccessToken = 'auth_access_token';
  static const _keyRefreshToken = 'auth_refresh_token';
  static const _keyExpiresAt = 'auth_expires_at';
  static const _keyUserJson = 'auth_user_json';

  final FlutterSecureStorage _storage;

  SecureSessionStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  // ── Save ──────────────────────────────────────────────────────────────────

  /// Persists auth tokens into encrypted storage.
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresAt,
    Map<String, dynamic>? userJson,
  }) async {
    try {
      await Future.wait([
        _storage.write(key: _keyAccessToken, value: accessToken),
        _storage.write(key: _keyRefreshToken, value: refreshToken),
        _storage.write(key: _keyExpiresAt, value: expiresAt.toString()),
        if (userJson != null)
          _storage.write(key: _keyUserJson, value: jsonEncode(userJson)),
      ]);
      debugPrint('[SecureSessionStorage] Tokens saved successfully');
    } catch (e, stack) {
      debugPrint('[SecureSessionStorage] Save failed: $e\n$stack');
      rethrow;
    }
  }

  // ── Validity check ────────────────────────────────────────────────────────

  /// Returns `true` if a session is stored and has not expired.
  Future<bool> isSessionValid() async {
    try {
      final expiresAtStr = await _storage.read(key: _keyExpiresAt);
      if (expiresAtStr == null) return false;

      final expiresAt = int.tryParse(expiresAtStr);
      if (expiresAt == null) return false;

      final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // Allow a 60-second grace period for clock skew.
      return expiresAt > (nowEpoch + 60);
    } catch (e) {
      debugPrint('[SecureSessionStorage] Validity check failed: $e');
      return false;
    }
  }

  // ── Clear ─────────────────────────────────────────────────────────────────

  /// Removes all persisted auth data.
  Future<void> clearSession() async {
    try {
      await Future.wait([
        _storage.delete(key: _keyAccessToken),
        _storage.delete(key: _keyRefreshToken),
        _storage.delete(key: _keyExpiresAt),
        _storage.delete(key: _keyUserJson),
      ]);
      debugPrint('[SecureSessionStorage] Session cleared');
    } catch (e, stack) {
      debugPrint('[SecureSessionStorage] Clear failed: $e\n$stack');
    }
  }

  // ── Quick access ──────────────────────────────────────────────────────────

  /// Returns the stored access token, or `null`.
  Future<String?> getAccessToken() => _storage.read(key: _keyAccessToken);

  /// Returns the stored refresh token, or `null`.
  Future<String?> getRefreshToken() => _storage.read(key: _keyRefreshToken);
}
