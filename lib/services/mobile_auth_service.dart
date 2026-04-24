import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import '../config/auth_config.dart';
import '../models/mobile_auth_models.dart';
import 'secure_session_storage.dart';

/// Orchestrates the native OAuth handshake for Google and Apple sign-in.
///
/// All token exchange happens server-side via the Supabase
/// `mobile-auth-handshake` edge function — no provider secrets ever touch
/// the Flutter client.
class MobileAuthService {
  final SecureSessionStorage _storage;
  final http.Client _httpClient;

  /// In-memory cache of the current session / user after a successful auth
  /// or session restore.
  MobileAuthSession? _session;
  MobileAuthUser? _user;

  MobileAuthService({
    SecureSessionStorage? storage,
    http.Client? httpClient,
  })  : _storage = storage ?? SecureSessionStorage(),
        _httpClient = httpClient ?? http.Client();

  // ── Public getters ────────────────────────────────────────────────────────

  MobileAuthSession? get session => _session;
  MobileAuthUser? get user => _user;
  bool get isAuthenticated => _session != null;

  // ── Google Sign-In (PKCE on both platforms) ───────────────────────────────

  /// Starts the full Google OAuth PKCE flow:
  /// start → browser → callback → exchange → persist.
  Future<ExchangeResponse> startGoogleSignIn() async {
    final platform = _currentPlatform;
    debugPrint('[MobileAuth] Starting Google sign-in on $platform');
    return _runPkceFlow(provider: 'google', platform: platform);
  }

  // ── Apple Sign-In (native on iOS, PKCE on Android) ───────────────────────

  /// Platform-aware Apple sign-in.
  Future<ExchangeResponse> startAppleSignIn() async {
    if (Platform.isIOS) {
      return _runNativeAppleFlow();
    }
    // Android — treat Apple as a browser PKCE flow.
    return _runPkceFlow(provider: 'apple', platform: 'android');
  }

  // ── Session lifecycle ─────────────────────────────────────────────────────

  /// Restores the session from secure storage on cold start.
  ///
  /// Returns `true` if a valid (non-expired) session was restored.
  Future<bool> restoreSession() async {
    final restored = await _storage.restoreSession();
    if (restored == null) {
      debugPrint('[MobileAuth] No stored session to restore');
      return false;
    }

    final isValid = await _storage.isSessionValid();
    if (!isValid) {
      debugPrint('[MobileAuth] Stored session is expired — clearing');
      await _storage.clearSession();
      _session = null;
      _user = null;
      return false;
    }

    _session = restored.session;
    _user = restored.user;
    debugPrint('[MobileAuth] Session restored for ${_user?.email}');
    return true;
  }

  /// Signs out: clears in-memory state and secure storage.
  Future<void> signOut() async {
    debugPrint('[MobileAuth] Signing out');
    _session = null;
    _user = null;
    await _storage.clearSession();
  }

  // ── PKCE flow (shared by Google + Apple-on-Android) ───────────────────────

  Future<ExchangeResponse> _runPkceFlow({
    required String provider,
    required String platform,
  }) async {
    // Step 1 — start handshake
    final startResponse = await _startHandshake(
      provider: provider,
      platform: platform,
    );

    if (!startResponse.success || startResponse.data == null) {
      debugPrint('[MobileAuth] Start handshake failed: ${startResponse.error}');
      return ExchangeResponse(
        success: false,
        action: 'exchange',
        status: 'error',
        requestId: startResponse.requestId,
        error: startResponse.error ??
            const MobileAuthError(
              code: 'start_failed',
              message: 'Failed to start authentication.',
            ),
      );
    }

    final startData = startResponse.data!;
    debugPrint('[MobileAuth] Handshake started — opening browser');

    // Step 2 — open authUrl in a secure browser surface
    final String callbackUrl;
    try {
      callbackUrl = await FlutterWebAuth2.authenticate(
        url: startData.authUrl,
        callbackUrlScheme: AuthConfig.callbackScheme,
      );
    } catch (e) {
      debugPrint('[MobileAuth] Browser auth cancelled or failed: $e');
      return ExchangeResponse(
        success: false,
        action: 'exchange',
        status: 'error',
        requestId: startResponse.requestId,
        error: MobileAuthError(
          code: 'browser_cancelled',
          message: 'Sign-in was cancelled.',
          retryable: true,
        ),
      );
    }

    // Step 3 — extract code + state from the callback URL
    final uri = Uri.parse(callbackUrl);
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];

    if (code == null || state == null) {
      debugPrint('[MobileAuth] Missing code/state in callback: $callbackUrl');
      return ExchangeResponse(
        success: false,
        action: 'exchange',
        status: 'error',
        requestId: startResponse.requestId,
        error: const MobileAuthError(
          code: 'missing_code',
          message: 'OAuth callback did not contain required parameters.',
        ),
      );
    }

    debugPrint('[MobileAuth] Callback received — exchanging code');

    // Step 4 — exchange code for session
    final exchangeResponse = await _exchangeCode(
      code: code,
      state: state,
      provider: provider,
      platform: platform,
    );

    // Step 5 — persist if successful
    if (exchangeResponse.success && exchangeResponse.data != null) {
      await _persistExchangeData(exchangeResponse.data!);
    }

    return exchangeResponse;
  }

  // ── Native Apple flow (iOS only) ──────────────────────────────────────────

  Future<ExchangeResponse> _runNativeAppleFlow() async {
    debugPrint('[MobileAuth] Starting native Apple sign-in (iOS)');

    // Generate a raw nonce; hash it for Apple.
    final rawNonce = _generateNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final identityToken = credential.identityToken;
      if (identityToken == null) {
        debugPrint('[MobileAuth] Apple credential missing identityToken');
        return ExchangeResponse(
          success: false,
          action: 'exchange',
          status: 'error',
          error: const MobileAuthError(
            code: 'missing_id_token',
            message: 'Apple Sign-In did not return an identity token.',
          ),
        );
      }

      debugPrint('[MobileAuth] Apple identityToken obtained — exchanging');

      // Exchange with backend
      final response = await _exchangeAppleIdToken(
        idToken: identityToken,
        nonce: rawNonce,
      );

      if (response.success && response.data != null) {
        await _persistExchangeData(response.data!);
      }

      return response;
    } on SignInWithAppleAuthorizationException catch (e) {
      debugPrint('[MobileAuth] Apple sign-in exception: $e');

      if (e.code == AuthorizationErrorCode.canceled) {
        return ExchangeResponse(
          success: false,
          action: 'exchange',
          status: 'error',
          error: const MobileAuthError(
            code: 'browser_cancelled',
            message: 'Apple Sign-In was cancelled.',
            retryable: true,
          ),
        );
      }

      return ExchangeResponse(
        success: false,
        action: 'exchange',
        status: 'error',
        error: MobileAuthError(
          code: 'exchange_failed',
          message: 'Apple Sign-In failed: ${e.message}',
        ),
      );
    } catch (e) {
      debugPrint('[MobileAuth] Apple sign-in error: $e');
      return ExchangeResponse(
        success: false,
        action: 'exchange',
        status: 'error',
        error: MobileAuthError(
          code: 'exchange_failed',
          message: 'Apple Sign-In failed unexpectedly.',
        ),
      );
    }
  }

  // ── HTTP helpers ──────────────────────────────────────────────────────────

  Map<String, String> get _headers => {
        'apikey': AuthConfig.supabaseAnonKey,
        'Authorization': 'Bearer ${AuthConfig.supabaseAnonKey}',
        'Content-Type': 'application/json',
      };

  /// POST `action: start` to begin the handshake.
  Future<StartHandshakeResponse> _startHandshake({
    required String provider,
    required String platform,
  }) async {
    final body = jsonEncode({
      'action': 'start',
      'provider': provider,
      'platform': platform,
      'redirectUri': AuthConfig.redirectUri,
    });

    debugPrint('[MobileAuth] POST start ($provider/$platform)');

    try {
      final response = await _httpClient
          .post(
            Uri.parse(AuthConfig.edgeFunctionUrl),
            headers: _headers,
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      debugPrint('[MobileAuth] start response ${response.statusCode}');

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return StartHandshakeResponse.fromJson(json, MobileAuthStartData.fromJson);
    } catch (e, stack) {
      debugPrint('[MobileAuth] start request failed: $e\n$stack');
      return StartHandshakeResponse(
        success: false,
        action: 'start',
        status: 'error',
        error: MobileAuthError(
          code: 'start_failed',
          message: 'Network error: ${e.toString()}',
          retryable: true,
        ),
      );
    }
  }

  /// POST `action: exchange` with a PKCE authorization code.
  Future<ExchangeResponse> _exchangeCode({
    required String code,
    required String state,
    required String provider,
    required String platform,
  }) async {
    final body = jsonEncode({
      'action': 'exchange',
      'provider': provider,
      'platform': platform,
      'code': code,
      'state': state,
    });

    return _postExchange(body);
  }

  /// POST `action: exchange` with an Apple `id_token`.
  Future<ExchangeResponse> _exchangeAppleIdToken({
    required String idToken,
    required String nonce,
  }) async {
    final body = jsonEncode({
      'action': 'exchange',
      'grantType': 'id_token',
      'provider': 'apple',
      'platform': 'ios',
      'idToken': idToken,
      'nonce': nonce,
      'redirectUri': AuthConfig.redirectUri,
    });

    return _postExchange(body);
  }

  Future<ExchangeResponse> _postExchange(String body) async {
    debugPrint('[MobileAuth] POST exchange');

    try {
      final response = await _httpClient
          .post(
            Uri.parse(AuthConfig.edgeFunctionUrl),
            headers: _headers,
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      debugPrint('[MobileAuth] exchange response ${response.statusCode}');

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return ExchangeResponse.fromJson(json, MobileAuthExchangeData.fromJson);
    } catch (e, stack) {
      debugPrint('[MobileAuth] exchange request failed: $e\n$stack');
      return ExchangeResponse(
        success: false,
        action: 'exchange',
        status: 'error',
        error: MobileAuthError(
          code: 'exchange_failed',
          message: 'Network error: ${e.toString()}',
          retryable: true,
        ),
      );
    }
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _persistExchangeData(MobileAuthExchangeData data) async {
    _session = data.session;
    _user = data.user;
    await _storage.saveSession(data.session, data.user);
    debugPrint('[MobileAuth] Session persisted for ${data.user.email}');
  }

  String get _currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// Generates a cryptographically random nonce string.
  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }
}
