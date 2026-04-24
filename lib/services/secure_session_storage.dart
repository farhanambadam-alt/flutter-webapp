import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/mobile_auth_models.dart';

/// Wraps [FlutterSecureStorage] to persist and restore the Supabase auth
/// session produced by the native OAuth handshake.
class SecureSessionStorage {
  static const _keyAccessToken = 'auth_access_token';
  static const _keyRefreshToken = 'auth_refresh_token';
  static const _keyExpiresAt = 'auth_expires_at';
  static const _keyUserJson = 'auth_user_json';
  static const _keySessionJson = 'auth_session_json';

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

  /// Persists the [session] and [user] into encrypted storage.
  Future<void> saveSession(
    MobileAuthSession session,
    MobileAuthUser user,
  ) async {
    try {
      await Future.wait([
        _storage.write(key: _keyAccessToken, value: session.accessToken),
        _storage.write(key: _keyRefreshToken, value: session.refreshToken),
        _storage.write(
            key: _keyExpiresAt, value: session.expiresAt.toString()),
        _storage.write(
            key: _keySessionJson, value: jsonEncode(session.toJson())),
        _storage.write(key: _keyUserJson, value: jsonEncode(user.toJson())),
      ]);
      debugPrint('[SecureSessionStorage] Session saved successfully');
    } catch (e, stack) {
      debugPrint('[SecureSessionStorage] Save failed: $e\n$stack');
      rethrow;
    }
  }

  // ── Restore ───────────────────────────────────────────────────────────────

  /// Attempts to restore a previously persisted session.
  ///
  /// Returns `null` if nothing is stored or if the data is corrupt.
  Future<({MobileAuthSession session, MobileAuthUser user})?> restoreSession() async {
    try {
      final sessionJson = await _storage.read(key: _keySessionJson);
      final userJson = await _storage.read(key: _keyUserJson);

      if (sessionJson == null || userJson == null) {
        debugPrint('[SecureSessionStorage] No stored session found');
        return null;
      }

      final session = MobileAuthSession.fromJson(
        jsonDecode(sessionJson) as Map<String, dynamic>,
      );
      final user = MobileAuthUser.fromJson(
        jsonDecode(userJson) as Map<String, dynamic>,
      );

      debugPrint('[SecureSessionStorage] Session restored for ${user.email}');
      return (session: session, user: user);
    } catch (e, stack) {
      debugPrint('[SecureSessionStorage] Restore failed: $e\n$stack');
      return null;
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
        _storage.delete(key: _keySessionJson),
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
