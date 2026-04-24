import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

import 'config/auth_config.dart';
import 'models/mobile_auth_models.dart';
import 'services/mobile_auth_service.dart';
import 'services/auth_error_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Edge-to-edge system UI
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  ));
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  
  // Lock to portrait mode
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  
  runApp(const ChicSalonApp());
}

class ChicSalonApp extends StatelessWidget {
  const ChicSalonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChicSalon',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
      ),
      home: const WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  InAppWebViewController? _controller;
  static const String _rootRoute = "/";
  static const String _webAppUrl = 'https://kesh1.lovable.app';
  
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  
  bool _isPageLoaded = false;
  bool _showLoading = true;
  bool _hasError = false;
  bool _isOffline = false;
  bool _isRetryPressed = false;
  static const Duration _pageLoadTimeout = Duration(seconds: 12);
  bool _didPageLoadTimeout = false;
  Timer? _pageLoadTimeoutTimer;
  String? _pendingPath;
  String _currentRoute = _rootRoute;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  late AnimationController _loadingAnimController;
  late Animation<double> _loadingAnimation;

  // ── Native Auth State ─────────────────────────────────────────────────────
  late final MobileAuthService _authService;
  bool _isAuthenticated = false;
  bool _isAuthenticating = false;
  MobileAuthUser? _currentUser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Initialise auth service and restore session before anything else.
    _authService = MobileAuthService();
    _restoreAuthSession();

    _initDeepLinks();
    _initConnectivity();

    _loadingAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _loadingAnimation = CurvedAnimation(
      parent: _loadingAnimController,
      curve: Curves.easeInOut,
    );
  }

  /// Attempts to restore a previously persisted auth session on cold start.
  Future<void> _restoreAuthSession() async {
    try {
      final restored = await _authService.restoreSession();
      if (!mounted) return;
      if (restored) {
        setState(() {
          _isAuthenticated = true;
          _currentUser = _authService.user;
        });
        debugPrint('🔑 Auth session restored for ${_currentUser?.email}');
      } else {
        debugPrint('🔑 No valid auth session to restore');
      }
    } catch (e) {
      debugPrint('🔑 Auth restore error: $e');
    }
  }

  Future<void> _initConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _updateConnectionStatus(result);
    } catch (e) {
      debugPrint("Connectivity error: $e");
    }
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(_updateConnectionStatus);
  }

  void _updateConnectionStatus(List<ConnectivityResult> result) {
    if (!mounted) return;
    final isOffline = result.isEmpty || result.contains(ConnectivityResult.none);
    if (isOffline != _isOffline) {
      setState(() {
        _isOffline = isOffline;
      });
      if (isOffline) {
        debugPrint("🔴 Internet Disconnected - Showing Offline Popup");
      } else {
        debugPrint("🟢 Internet Reconnected - Auto-reloading WebView");
        if (_controller != null) {
          setState(() {
            _hasError = false;
            _showLoading = true;
          });
          _controller!.loadUrl(urlRequest: URLRequest(url: WebUri(_webAppUrl)));
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _cancelPageLoadTimeout();
    _loadingAnimController.dispose();
    super.dispose();
  }

  void _cancelPageLoadTimeout() {
    _pageLoadTimeoutTimer?.cancel();
    _pageLoadTimeoutTimer = null;
  }

  void _startPageLoadTimeout() {
    _cancelPageLoadTimeout();
    _didPageLoadTimeout = false;
    _pageLoadTimeoutTimer = Timer(_pageLoadTimeout, () {
      if (!mounted) return;
      debugPrint("Page load timed out; showing connection error overlay");
      setState(() {
        _hasError = true;
        _showLoading = false;
        _didPageLoadTimeout = true;
      });
    });
  }

  Future<void> _initDeepLinks() async {
    try {
      _appLinks = AppLinks();

      // Check initial link if app was closed
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _handleDeepLink(initialUri);
      }

      // Listen for incoming links while app is running
      _linkSubscription = _appLinks.uriLinkStream.listen(
        (uri) {
          _handleDeepLink(uri);
        },
        onError: (Object e, StackTrace s) {
          debugPrint("Deep link stream error: $e\n$s");
        },
      );
    } catch (e, stack) {
      debugPrint("Deep link init failed: $e\n$stack");
    }
  }

  void _handleDeepLink(Uri uri) {
    debugPrint("Incoming deep link: $uri");

    // ── OAuth callback routing ──────────────────────────────────────────────
    // If the deep link is an OAuth callback (com.example.chicsalon://login-callback)
    // route it to the auth service instead of the WebView.
    if (uri.scheme == AuthConfig.callbackScheme && uri.host == 'login-callback') {
      debugPrint('🔑 OAuth callback detected — routing to auth service');
      // Note: flutter_web_auth_2 handles the callback interception internally
      // via its own activity/session. This branch is a safety net for any
      // callbacks that arrive through app_links instead (e.g. cold start).
      return;
    }

    // ── Standard deep link → WebView navigation ─────────────────────────────
    // Extract path from chicsalon://app/<path> or https://yourdomain.com/<path>
    String path = uri.path;
    if (path.isEmpty) path = "/";
    if (!path.startsWith("/")) path = "/$path";

    debugPrint("Parsed deep link path: $path");

    if (_isPageLoaded) {
      navigateTo(path);
    } else {
      _pendingPath = path;
    }
  }

  // ── Native Auth Handlers ────────────────────────────────────────────────

  /// Handles a native sign-in request from the WebView.
  ///
  /// [provider] must be `"google"` or `"apple"`.
  Future<void> _handleNativeSignIn(String provider) async {
    if (_isAuthenticating) {
      debugPrint('🔑 Sign-in already in progress — ignoring');
      return;
    }

    setState(() => _isAuthenticating = true);
    debugPrint('🔑 Starting native $provider sign-in');

    try {
      final ExchangeResponse response;
      if (provider == 'apple') {
        response = await _authService.startAppleSignIn();
      } else {
        response = await _authService.startGoogleSignIn();
      }

      if (!mounted) return;

      if (response.success && response.data != null) {
        setState(() {
          _isAuthenticated = true;
          _currentUser = _authService.user;
          _isAuthenticating = false;
        });
        debugPrint('🔑 Sign-in successful for ${_currentUser?.email}');

        // Bridge session into WebView
        _injectAuthSessionIntoWebView();

        // Notify React that sign-in completed
        _controller?.evaluateJavascript(source: '''
          if (window.onNativeSignInComplete) {
            window.onNativeSignInComplete({ success: true, provider: "$provider" });
          }
        ''');
      } else {
        setState(() => _isAuthenticating = false);

        final errorMsg = AuthErrorHandler.userMessage(response.error);
        final shouldRestart = AuthErrorHandler.shouldRestartFlow(response.error);
        debugPrint('🔑 Sign-in failed: ${response.error}');

        // Notify React of the error
        final escapedMsg = errorMsg.replaceAll('"', '\\"');
        _controller?.evaluateJavascript(source: '''
          if (window.onNativeSignInComplete) {
            window.onNativeSignInComplete({
              success: false,
              provider: "$provider",
              error: "$escapedMsg",
              shouldRestart: $shouldRestart
            });
          }
        ''');
      }
    } catch (e) {
      debugPrint('🔑 Sign-in exception: $e');
      if (!mounted) return;
      setState(() => _isAuthenticating = false);

      _controller?.evaluateJavascript(source: '''
        if (window.onNativeSignInComplete) {
          window.onNativeSignInComplete({
            success: false,
            provider: "$provider",
            error: "An unexpected error occurred. Please try again.",
            shouldRestart: true
          });
        }
      ''');
    }
  }

  /// Handles a sign-out request from the WebView.
  Future<void> _handleNativeSignOut() async {
    debugPrint('🔑 Signing out');
    await _authService.signOut();
    if (!mounted) return;
    setState(() {
      _isAuthenticated = false;
      _currentUser = null;
    });

    // Notify React that sign-out completed
    _controller?.evaluateJavascript(source: '''
      if (window.onNativeSignOutComplete) {
        window.onNativeSignOutComplete();
      }
    ''');
  }

  /// Injects the current auth session into the WebView so React can consume
  /// the already-authenticated state without initiating OAuth itself.
  void _injectAuthSessionIntoWebView() {
    final session = _authService.session;
    final user = _authService.user;
    if (session == null || user == null) return;

    final payload = jsonEncode({
      'accessToken': session.accessToken,
      'refreshToken': session.refreshToken,
      'expiresAt': session.expiresAt,
      'tokenType': session.tokenType,
      'user': user.toJson(),
    });

    debugPrint('🔑 Injecting auth session into WebView');
    _controller?.evaluateJavascript(source: '''
      if (window.setAuthSession) {
        window.setAuthSession($payload);
      }
    ''');
  }

  Future<void> navigateTo(String path) async {
    if (_controller == null || !mounted) return;

    // Guard: Prevent duplicate navigation to the same route
    if (_currentRoute == path) return;

    debugPrint("🚀 Flutter navigating to: $path");
    try {
      await _controller?.evaluateJavascript(
        source: "if (window.navigateTo) { window.navigateTo('$path'); }"
      );
      // Update route locally to prevent race conditions/double navigation
      _currentRoute = path;
    } catch (e) {
      debugPrint("Navigation bridge error: $e");
    }
  }

  Future<void> _handleLocationRequest() async {
    try {
      // 1. Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        // GPS is OFF — open system settings and notify React
        await _handleEnableLocationServices();
        return;
      }

      // 2. Check & request permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _sendLocationError('Location permission denied.');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _sendLocationError(
          'Location permission permanently denied. Please enable it in Settings.',
        );
        return;
      }

      // 3. Get current position with HIGH ACCURACY
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      // 4. Reverse geocode (optional — React will also reverse geocode)
      String? cityName;
      String? areaName;
      try {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final place = placemarks.first;
          cityName = place.locality ??
              place.subAdministrativeArea ??
              place.administrativeArea;
          areaName = place.subLocality ?? place.thoroughfare;
        }
      } catch (e) {
        debugPrint('Geocoding failed: $e — React will handle it');
      }

      // 5. Send result to React
      final js = '''
        if (window.setLocationFromNative) {
          window.setLocationFromNative({
            lat: ${position.latitude},
            lng: ${position.longitude},
            city: ${cityName != null ? '"$cityName"' : 'null'},
            area: ${areaName != null ? '"$areaName"' : 'null'}
          });
        }
      ''';
      await _controller?.evaluateJavascript(source: js);
    } catch (e) {
      debugPrint('Location error: $e');
      _sendLocationError('Failed to get location. Please try again.');
    }
  }

  Future<void> _handleEnableLocationServices() async {
    try {
      // 1. Handle permission first — no point opening GPS settings if permission is denied
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _sendLocationError('Location permission denied.');
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        _sendLocationError(
          'Location permission permanently denied. Please enable in Settings.',
        );
        return;
      }

      // 2. GUARD: If GPS is already ON, notify React immediately — do NOT open settings
      // This prevents the infinite loop: React calls enableLocationServices → Flutter
      // opens settings → detects GPS ON → notifies React → React calls again → loop
      if (await Geolocator.isLocationServiceEnabled()) {
        debugPrint('GPS already ON — notifying React without opening settings');
        await _controller?.evaluateJavascript(
          source: '''
            if (window.onLocationServicesEnabled) {
              window.onLocationServicesEnabled();
            }
          ''',
        );
        return;
      }

      // GPS is OFF — open the Android system location settings dialog
      bool opened = await Geolocator.openLocationSettings();

      if (opened) {
        // Poll for location services to become enabled (max 30 seconds)
        for (int i = 0; i < 15; i++) {
          await Future.delayed(const Duration(seconds: 2));
          if (await Geolocator.isLocationServiceEnabled()) {
            // GPS is now ON — notify React to retry
            await _controller?.evaluateJavascript(
              source: '''
                if (window.onLocationServicesEnabled) {
                  window.onLocationServicesEnabled();
                }
              ''',
            );
            return;
          }
        }
        // Timed out waiting
        _sendLocationError('GPS was not enabled. Please try again.');
      } else {
        _sendLocationError('Could not open location settings.');
      }
    } catch (e) {
      debugPrint('Enable location error: $e');
      _sendLocationError('Could not open location settings.');
    }
  }

  void _sendLocationError(String message) {
    final js = '''
      if (window.setLocationError) {
        window.setLocationError("$message");
      }
    ''';
    _controller?.evaluateJavascript(source: js);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _injectSafeArea();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _injectSafeArea();
    }
  }

  void _injectSafeArea() {
    if (_controller == null || !mounted) return;
    
    final view = View.of(context);
    final padding = MediaQueryData.fromView(view).padding;
    
    try {
      // Don't let JS evaluation Future exceptions become unhandled.
      _controller
          ?.evaluateJavascript(source: '''
        try {
          document.documentElement.style.setProperty('--flutter-top', '${padding.top}px');
          document.documentElement.style.setProperty('--flutter-bottom', '${padding.bottom}px');
          document.documentElement.style.setProperty('--flutter-left', '${padding.left}px');
          document.documentElement.style.setProperty('--flutter-right', '${padding.right}px');
          document.documentElement.classList.add('safe-ready');
        } catch(e) {}
      ''')
          .catchError((Object e, StackTrace s) {
        debugPrint("Safe-area JS inject failed: $e\n$s");
      });
    } catch (e, stack) {
      debugPrint("Safe-area injection threw: $e\n$stack");
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        
        final controller = _controller;
        if (controller == null) return;

        debugPrint("📱 BACK PRESSED → currentRoute: $_currentRoute");

        // Always ask React via window.isRootRoute?.() — if true, exit.
        // Never use local route checks for exit except as JS-call failure fallback.
        try {
          final isRoot = await controller.evaluateJavascript(
            source: "window.isRootRoute?.()",
          );
          if (isRoot == true || isRoot == 'true') {
            SystemNavigator.pop();
            return;
          }
        } catch (e) {
          debugPrint("isRootRoute check failed: $e");
          // JS-call failure fallback — only place local route is used
          if (_currentRoute == _rootRoute || _currentRoute.isEmpty) {
            SystemNavigator.pop();
            return;
          }
        }

        // Not root — delegate back navigation to React
        try {
          debugPrint("📲 Calling window.appBack()");
          await controller.evaluateJavascript(source: """
            if (window.appBack) {
              window.appBack();
            }
          """);
        } catch (e) {
          debugPrint("Back bridge error: $e");
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_webAppUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            useHybridComposition: true,
            // [TEST] Hardware acceleration enabled — monitor onRenderProcessGone for crashes on Vivo
            hardwareAcceleration: true,
            overScrollMode: OverScrollMode.NEVER,
            verticalScrollBarEnabled: false,
            horizontalScrollBarEnabled: false,
            transparentBackground: true,
            allowsInlineMediaPlayback: true,  // Play audio/video inline without full-screen takeover
            supportZoom: false,               // Prevent accidental pinch-zoom breaking UI layout
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            
            // Register JS Handler for route synchronization
            try {
              controller.addJavaScriptHandler(
                handlerName: 'routeChanged',
                callback: (args) {
                  if (args.isNotEmpty) {
                    if (!mounted) return;
                    setState(() {
                      _currentRoute = args.first.toString();
                    });
                    debugPrint("🌐 React reported route: ${args.first}");
                  }
                },
              );

              controller.addJavaScriptHandler(
                handlerName: 'requestLocation',
                callback: (args) {
                  _handleLocationRequest();
                  return null;
                },
              );

              // Enable location services — called when GPS is detected as OFF
              controller.addJavaScriptHandler(
                handlerName: 'enableLocationServices',
                callback: (args) {
                  _handleEnableLocationServices();
                  return null;
                },
              );

              // Silent location status check — called on every app startup by React
              // NEVER opens settings, requests permissions, or shows any UI
              // Returns FAST — no getCurrentPosition (that was causing React timeout)
              controller.addJavaScriptHandler(
                handlerName: 'checkLocationStatus',
                callback: (args) async {
                  debugPrint('checkLocationStatus called — checking silently');
                  bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
                  LocationPermission permission = await Geolocator.checkPermission(); // NOT requestPermission!
                  debugPrint('checkLocationStatus — service: $serviceEnabled, permission: $permission');

                  if (serviceEnabled &&
                      permission != LocationPermission.denied &&
                      permission != LocationPermission.deniedForever) {
                    _controller?.evaluateJavascript(source:
                      "if (window.setLocationCheckResult) { window.setLocationCheckResult({enabled:true}); }");
                  } else {
                    _controller?.evaluateJavascript(source:
                      "if (window.setLocationCheckResult) { window.setLocationCheckResult({enabled:false}); }");
                  }
                  return null;
                },
              );

              // Map active handler — disable gesture interception when map is displayed
              controller.addJavaScriptHandler(
                handlerName: 'mapActive',
                callback: (args) {
                  final bool active = args.isNotEmpty && args[0] == true;
                  debugPrint('Map active: $active');
                },
              );

              // ── NEW: Directions handler ──
              controller.addJavaScriptHandler(
                handlerName: 'openDirections',
                callback: (args) async {
                  debugPrint('[MAP] openDirections received');

                  if (args.isEmpty) {
                    debugPrint('[MAP] ERROR: No payload received');
                    return;
                  }

                  final data = args[0] as Map<String, dynamic>;
                  final double lat = (data['lat'] as num).toDouble();
                  final double lng = (data['lng'] as num).toDouble();
                  final String address = data['address'] as String? ?? '';

                  debugPrint('[MAP] Destination: $lat, $lng ($address)');

                  final nativeUri = Uri.parse('google.navigation:q=$lat,$lng');
                  debugPrint('[MAP] Trying native maps: $nativeUri');

                  if (await canLaunchUrl(nativeUri)) {
                    debugPrint('[MAP] Launching native Google Maps');
                    await launchUrl(nativeUri);
                    return;
                  }

                  final browserUri = Uri.parse(
                    'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng',
                  );
                  debugPrint('[MAP] Fallback to browser: $browserUri');

                  if (await canLaunchUrl(browserUri)) {
                    await launchUrl(browserUri, mode: LaunchMode.externalApplication);
                  } else {
                    debugPrint('[MAP] ERROR: Cannot launch any maps URL');
                  }
                },
              );

              // ── NEW: Share handler ──
              controller.addJavaScriptHandler(
                handlerName: 'shareContent',
                callback: (args) {
                  final data = args.isNotEmpty ? args[0] as Map<String, dynamic> : {};
                  final title = data['title']?.toString() ?? '';
                  final text = data['text']?.toString() ?? '';
                  final url = data['url']?.toString() ?? '';
                  debugPrint('[SHARE] shareContent received: $title');
                  debugPrint('[SHARE] Opening native share sheet');
                  Share.share(
                    '$text\n$url',
                    subject: title,
                  );
                },
              );
              // ── Native Auth: Sign-in handler ──
              // React calls this to trigger native Google or Apple sign-in.
              // Payload: { provider: "google" | "apple" }
              controller.addJavaScriptHandler(
                handlerName: 'requestNativeSignIn',
                callback: (args) {
                  final data = args.isNotEmpty ? args[0] as Map<String, dynamic> : {};
                  final provider = data['provider']?.toString() ?? 'google';
                  debugPrint('[AUTH] requestNativeSignIn: $provider');
                  _handleNativeSignIn(provider);
                  return null;
                },
              );

              // ── Native Auth: Sign-out handler ──
              controller.addJavaScriptHandler(
                handlerName: 'requestNativeSignOut',
                callback: (args) {
                  debugPrint('[AUTH] requestNativeSignOut');
                  _handleNativeSignOut();
                  return null;
                },
              );

              // ── Native Auth: Query current auth state ──
              // React can call this to check if Flutter has a valid session.
              controller.addJavaScriptHandler(
                handlerName: 'getAuthState',
                callback: (args) {
                  debugPrint('[AUTH] getAuthState — authenticated=$_isAuthenticated');
                  final user = _currentUser;
                  final session = _authService.session;
                  return {
                    'isAuthenticated': _isAuthenticated,
                    'user': user != null ? {
                      'id': user.id,
                      'email': user.email,
                      'provider': user.provider,
                    } : null,
                    'accessToken': session?.accessToken,
                    'expiresAt': session?.expiresAt,
                  };
                },
              );
            } catch (e, stack) {
              debugPrint("JS handler registration failed: $e\n$stack");
            }
          },
          onLoadStart: (controller, url) {
            debugPrint("🔄 PAGE LOAD START");
            _isPageLoaded = false;
            setState(() { _showLoading = true; _hasError = false; });
            _startPageLoadTimeout();
          },
          onLoadStop: (controller, url) async {
            debugPrint("✅ PAGE LOAD STOP");
            try {
              if (!mounted) return;

              _cancelPageLoadTimeout();
              if (_didPageLoadTimeout) {
                // WebView finished "loading" an error page after our timeout fired.
                // Keep showing the Flutter overlay instead of clearing it.
                setState(() {
                  _hasError = true;
                  _showLoading = false;
                });
                return;
              }
              _isPageLoaded = true;
              setState(() {
                _showLoading = false;
                _hasError = false;
              });

              _injectSafeArea();

              // Bridge authenticated session into WebView on every page load.
              // Flutter is the source of truth for auth — React consumes it.
              if (_isAuthenticated) {
                _injectAuthSessionIntoWebView();
              }

              // HARD RESET: Completely clear WebView history to prevent browser-like behavior
              await controller.clearHistory();

              // Sync initial route to Flutter immediately after load
              await controller.evaluateJavascript(source: """
                window.flutter_inappwebview.callHandler(
                  'routeChanged',
                  window.location.pathname
                );
              """);

              // If there was a pending deep link path, navigate now
              if (_pendingPath != null) {
                await navigateTo(_pendingPath!);
                _pendingPath = null;
              }

              await controller.evaluateJavascript(source: '''
                var style = document.createElement('style');
                style.innerHTML = `
                  ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
                  * { scrollbar-width: none !important; -webkit-tap-highlight-color: transparent !important; }
                `;
                document.head.appendChild(style);
              ''');
            } catch (e, stack) {
              debugPrint("onLoadStop failed: $e\n$stack");
              if (!mounted) return;
              setState(() {
                _hasError = true;
                _showLoading = false;
              });
            }
          },
          onReceivedError: (controller, request, error) {
            _cancelPageLoadTimeout();

            // Only surface main frame errors to avoid noise from sub-resource failures.
            // Also treat timeouts as connection errors so we can hide the WebView default error page.
            final desc = error.description;
            final normalized = desc.toLowerCase();
            final isTimedOut = normalized.contains('timed out') ||
                normalized.contains('err_timed_out') ||
                normalized.contains('timeout');
            final isMainFrame = request.isForMainFrame ?? false;

            if (isMainFrame || isTimedOut) {
              debugPrint("❌ WebView load error: $desc (url: ${request.url})");
              setState(() {
                _hasError = true;
                _showLoading = false;
                if (isTimedOut) _didPageLoadTimeout = true;
              });
            }
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri == null) return NavigationActionPolicy.CANCEL;
            // Allow only the current WebView host (remove legacy URL allowlist).
            const allowedHost = "kesh1.lovable.app";
            if (uri.host == allowedHost) return NavigationActionPolicy.ALLOW;
            return NavigationActionPolicy.CANCEL;
          },
          onUpdateVisitedHistory: (controller, url, androidIsReload) {
              _injectSafeArea();
          },
          onRenderProcessGone: (controller, detail) async {
            // 🔴 RENDER CRASH DETECTED — track this during hardware acceleration test
            final crashTime = DateTime.now().toIso8601String();
            final didCrash = detail.didCrash;
            debugPrint("💥 [$crashTime] RenderProcessGone — didCrash: $didCrash");
            debugPrint("💥 Detail: $detail");

            _isPageLoaded = false;
            try {
              await controller.reload();
              _injectSafeArea();
              debugPrint("✅ WebView recovered after render crash");
            } catch (e, stack) {
              debugPrint("❎ Recovery failed after RenderProcessGone: $e");
              debugPrint("📋 Stack trace: $stack");
            }
          },
            ),
            // Custom loading screen
            if (_showLoading)
              Container(
                width: double.infinity,
                height: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFE0BBE4), // soft purple
                      Color(0xFFF5F3F7), // pale lavender/off-white
                    ],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: 1.8,
                        child: Image.asset(
                          'assets/unisex-loding-image.png',
                          width: MediaQuery.of(context).size.width * 0.75,
                          height: MediaQuery.of(context).size.width * 0.75,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: 200,
                        child: AnimatedBuilder(
                          animation: _loadingAnimation,
                          builder: (context, child) {
                            return LinearProgressIndicator(
                              value: null, // indeterminate
                              minHeight: 4,
                              borderRadius: BorderRadius.circular(8),
                              backgroundColor: Color(0xFFD4B8D8).withValues(alpha: 0.4),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Color(0xFFB57BBA),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Unified Error & Offline Custom Overlay
            if (_hasError || _isOffline)
              Container(
                color: const Color(0xFFF5F3F7), // Opaque backdrop to completely hide WebView errors
                width: double.infinity,
                height: double.infinity,
                child: Center(
                  child: Container(
                    width: math.min(MediaQuery.of(context).size.width * 0.85, 400),
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFFFF1EB), // soft pearl pink
                          Color(0xFFF3E7E9),
                          Color(0xFFE3EEFF), // soft pearl blue
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 30,
                          offset: const Offset(0, 10),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: _StardustPainter()),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ShaderMask(
                              shaderCallback: (Rect bounds) {
                                return const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Color(0xFFFF7EB3), Color(0xFF8FD3F4)],
                                ).createShader(bounds);
                              },
                              child: const Icon(Icons.wifi_off_rounded, size: 90, color: Colors.white),
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'Could not connect',
                              style: TextStyle(
                                color: Color(0xFF333333),
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 32),
                            GestureDetector(
                              onTapDown: (_) {
                                if (!mounted) return;
                                HapticFeedback.lightImpact();
                                setState(() => _isRetryPressed = true);
                              },
                              onTapCancel: () {
                                if (!mounted) return;
                                setState(() => _isRetryPressed = false);
                              },
                              onTapUp: (_) {
                                if (!mounted) return;
                                setState(() => _isRetryPressed = false);
                              },
                              onTap: () async {
                                if (!mounted) return;
                                // Give the button 150ms so the user can visually see the shrink/grow animation
                                // before we instantly remove this view and show the loading screen
                                await Future.delayed(const Duration(milliseconds: 150));
                                if (!mounted) return;

                                setState(() {
                                  _hasError = false;
                                  _showLoading = true;
                                });
                                await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(_webAppUrl)));
                              },
                              child: AnimatedScale(
                                scale: _isRetryPressed ? 0.92 : 1.0,
                                duration: const Duration(milliseconds: 100),
                                curve: Curves.easeOutCubic,
                                child: AnimatedOpacity(
                                  opacity: _isRetryPressed ? 0.8 : 1.0,
                                  duration: const Duration(milliseconds: 100),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(30),
                                      border: Border.all(color: Colors.white, width: 1.5),
                                      gradient: const LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        colors: [
                                          Color(0xFFFF7EB3),
                                          Color(0xFF8FD3F4),
                                        ],
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.1),
                                          blurRadius: 8,
                                          offset: const Offset(0, 4),
                                        ),
                                        BoxShadow(
                                          color: const Color(0xFFFF7EB3).withValues(alpha: 0.3),
                                          blurRadius: 12,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
                                    child: const Text(
                                      'Retry',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StardustPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42);
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.6);
    
    for (int i = 0; i < 40; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final radius = random.nextDouble() * 2.0 + 0.5;

      if (i % 8 == 0) {
        final path = Path()
          ..moveTo(x, y - radius * 4)
          ..quadraticBezierTo(x, y, x + radius * 4, y)
          ..quadraticBezierTo(x, y, x, y + radius * 4)
          ..quadraticBezierTo(x, y, x - radius * 4, y)
          ..quadraticBezierTo(x, y, x, y - radius * 4)
          ..close();
        
        canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.9));
      } else {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
