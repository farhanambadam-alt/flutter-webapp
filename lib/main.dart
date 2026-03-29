import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Edge-to-edge system UI
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  
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
  static const String _webAppUrl = 'https://quickstart-bliss.lovable.app';
  
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
          _controller!.reload();
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
    // Extract path from chicsalon://app/<path> or https://yourdomain.com/<path>
    String path = uri.path;
    if (path.isEmpty) path = "/";
    if (!path.startsWith("/")) path = "/$path";

    debugPrint("Incoming deep link: $uri -> parsed path: $path");

    if (_isPageLoaded) {
      navigateTo(path);
    } else {
      _pendingPath = path;
    }
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

        // Root check: If at / or empty, exit the app
        if (_currentRoute == _rootRoute || _currentRoute.isEmpty) {
          SystemNavigator.pop();
          return;
        }

        // Delegate all other back navigation to React via JS bridge.
        // React's window.appBack() will now handle whether to go back 
        // to a previous page or jump directly to Home (/) if on a main tab.
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
            const allowedHost = "quickstart-bliss.lovable.app";
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
                            Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(30),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(30),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(30),
                                  splashColor: Colors.white.withValues(alpha: 0.16),
                                  highlightColor: Colors.white.withValues(alpha: 0.08),
                                  onTapDown: (_) {
                                    if (!mounted) return;
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
                                    setState(() => _isRetryPressed = false);
                                    setState(() {
                                      _hasError = false;
                                      _showLoading = true;
                                    });
                                    await _controller?.reload();
                                  },
                                  child: AnimatedScale(
                                    scale: _isRetryPressed ? 0.88 : 1.0,
                                    duration: const Duration(milliseconds: 20),
                                    curve: Curves.easeInOut,
                                    child: AnimatedOpacity(
                                      opacity: _isRetryPressed ? 0.72 : 1.0,
                                      duration: const Duration(milliseconds: 20),
                                      child: Ink(
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
                                              color: Color(0xFFFF7EB3).withValues(alpha: 0.3),
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
