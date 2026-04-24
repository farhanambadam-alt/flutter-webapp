

// ---------------------------------------------------------------------------
// Top-level response envelope
// ---------------------------------------------------------------------------

/// Generic envelope returned by the `mobile-auth-handshake` edge function.
///
/// Parsing strategy:
/// 1. Read the top-level envelope first.
/// 2. Use [success] as the primary discriminator.
/// 3. Use [action] + [status] as the secondary discriminator.
/// 4. Never assume [data] exists when [success] is `false`.
/// 5. Surface [requestId] in logs and error reporting.
/// 6. Use [error.retryable] to decide whether to auto-retry or restart.
class MobileAuthEnvelope<T> {
  final bool success;
  final String action;
  final String status;
  final String? requestId;
  final T? data;
  final MobileAuthError? error;

  const MobileAuthEnvelope({
    required this.success,
    required this.action,
    required this.status,
    this.requestId,
    this.data,
    this.error,
  });

  /// Parses the raw JSON [map] into an envelope.
  ///
  /// [dataParser] converts the `data` sub-object into the concrete type [T].
  factory MobileAuthEnvelope.fromJson(
    Map<String, dynamic> map,
    T Function(Map<String, dynamic>)? dataParser,
  ) {
    return MobileAuthEnvelope<T>(
      success: map['success'] as bool? ?? false,
      action: map['action'] as String? ?? '',
      status: map['status'] as String? ?? '',
      requestId: map['requestId'] as String?,
      data: map['success'] == true && map['data'] != null && dataParser != null
          ? dataParser(map['data'] as Map<String, dynamic>)
          : null,
      error: map['success'] == false && map['error'] != null
          ? MobileAuthError.fromJson(map['error'] as Map<String, dynamic>)
          : null,
    );
  }

  @override
  String toString() =>
      'MobileAuthEnvelope(success=$success, action=$action, status=$status, '
      'requestId=$requestId, data=$data, error=$error)';
}

// ---------------------------------------------------------------------------
// Start handshake data
// ---------------------------------------------------------------------------

class MobileAuthStartData {
  final String provider;
  final String platform;
  final String redirectUri;
  final String authUrl;
  final String state;
  final String? codeVerifier;
  final String? codeChallenge;
  final String? codeChallengeMethod;
  final int expiresInSeconds;

  const MobileAuthStartData({
    required this.provider,
    required this.platform,
    required this.redirectUri,
    required this.authUrl,
    required this.state,
    this.codeVerifier,
    this.codeChallenge,
    this.codeChallengeMethod,
    required this.expiresInSeconds,
  });

  factory MobileAuthStartData.fromJson(Map<String, dynamic> map) {
    return MobileAuthStartData(
      provider: map['provider'] as String? ?? '',
      platform: map['platform'] as String? ?? '',
      redirectUri: map['redirectUri'] as String? ?? '',
      authUrl: map['authUrl'] as String? ?? '',
      state: map['state'] as String? ?? '',
      codeVerifier: map['codeVerifier'] as String?,
      codeChallenge: map['codeChallenge'] as String?,
      codeChallengeMethod: map['codeChallengeMethod'] as String?,
      expiresInSeconds: map['expiresInSeconds'] as int? ?? 600,
    );
  }

  @override
  String toString() =>
      'MobileAuthStartData(provider=$provider, platform=$platform, '
      'authUrl=${authUrl.substring(0, authUrl.length.clamp(0, 60))}…)';
}

// ---------------------------------------------------------------------------
// Exchange response data (session + user)
// ---------------------------------------------------------------------------

class MobileAuthExchangeData {
  final MobileAuthSession session;
  final MobileAuthUser user;

  const MobileAuthExchangeData({
    required this.session,
    required this.user,
  });

  factory MobileAuthExchangeData.fromJson(Map<String, dynamic> map) {
    return MobileAuthExchangeData(
      session:
          MobileAuthSession.fromJson(map['session'] as Map<String, dynamic>),
      user: MobileAuthUser.fromJson(map['user'] as Map<String, dynamic>),
    );
  }

  @override
  String toString() =>
      'MobileAuthExchangeData(session=$session, user=$user)';
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

class MobileAuthSession {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final int expiresAt;
  final String tokenType;
  final String? providerToken;
  final String? providerRefreshToken;

  const MobileAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.expiresAt,
    required this.tokenType,
    this.providerToken,
    this.providerRefreshToken,
  });

  factory MobileAuthSession.fromJson(Map<String, dynamic> map) {
    return MobileAuthSession(
      accessToken: map['accessToken'] as String? ?? '',
      refreshToken: map['refreshToken'] as String? ?? '',
      expiresIn: map['expiresIn'] as int? ?? 0,
      expiresAt: map['expiresAt'] as int? ?? 0,
      tokenType: map['tokenType'] as String? ?? 'bearer',
      providerToken: map['providerToken'] as String?,
      providerRefreshToken: map['providerRefreshToken'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresIn': expiresIn,
        'expiresAt': expiresAt,
        'tokenType': tokenType,
        'providerToken': providerToken,
        'providerRefreshToken': providerRefreshToken,
      };

  @override
  String toString() =>
      'MobileAuthSession(expiresAt=$expiresAt, tokenType=$tokenType)';
}

// ---------------------------------------------------------------------------
// User
// ---------------------------------------------------------------------------

class MobileAuthUser {
  final String id;
  final String email;
  final String? phone;
  final String? aud;
  final String? role;
  final String provider;
  final String platform;
  final String? redirectUri;
  final Map<String, dynamic> appMetadata;
  final Map<String, dynamic> userMetadata;

  const MobileAuthUser({
    required this.id,
    required this.email,
    this.phone,
    this.aud,
    this.role,
    required this.provider,
    required this.platform,
    this.redirectUri,
    this.appMetadata = const {},
    this.userMetadata = const {},
  });

  factory MobileAuthUser.fromJson(Map<String, dynamic> map) {
    return MobileAuthUser(
      id: map['id'] as String? ?? '',
      email: map['email'] as String? ?? '',
      phone: map['phone'] as String?,
      aud: map['aud'] as String?,
      role: map['role'] as String?,
      provider: map['provider'] as String? ?? '',
      platform: map['platform'] as String? ?? '',
      redirectUri: map['redirectUri'] as String?,
      appMetadata: (map['appMetadata'] as Map<String, dynamic>?) ?? {},
      userMetadata: (map['userMetadata'] as Map<String, dynamic>?) ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'phone': phone,
        'aud': aud,
        'role': role,
        'provider': provider,
        'platform': platform,
        'redirectUri': redirectUri,
        'appMetadata': appMetadata,
        'userMetadata': userMetadata,
      };

  @override
  String toString() => 'MobileAuthUser(id=$id, email=$email, provider=$provider)';
}

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

class MobileAuthError {
  final String code;
  final String message;
  final bool retryable;
  final int? httpStatus;
  final Map<String, dynamic> details;

  const MobileAuthError({
    required this.code,
    required this.message,
    this.retryable = false,
    this.httpStatus,
    this.details = const {},
  });

  factory MobileAuthError.fromJson(Map<String, dynamic> map) {
    return MobileAuthError(
      code: map['code'] as String? ?? 'unknown',
      message: map['message'] as String? ?? 'An unknown error occurred.',
      retryable: map['retryable'] as bool? ?? false,
      httpStatus: map['httpStatus'] as int?,
      details: (map['details'] as Map<String, dynamic>?) ?? {},
    );
  }

  @override
  String toString() =>
      'MobileAuthError(code=$code, retryable=$retryable, message=$message)';
}

// ---------------------------------------------------------------------------
// Convenience type aliases
// ---------------------------------------------------------------------------

typedef StartHandshakeResponse = MobileAuthEnvelope<MobileAuthStartData>;
typedef ExchangeResponse = MobileAuthEnvelope<MobileAuthExchangeData>;
