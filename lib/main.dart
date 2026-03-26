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
  bool _historyCleared = false;
  bool _showLoading = true;
  bool _hasError = false;
  bool _isOffline = false;
  bool _isRetryPressed = false;
  String _errorDescription = '';
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
    _loadingAnimController.dispose();
    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    _appLinks = AppLinks();

    // Check initial link if app was closed
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) {
      _handleDeepLink(initialUri);
    }

    // Listen for incoming links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });
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
    
    _controller?.evaluateJavascript(source: '''
      try {
        document.documentElement.style.setProperty('--flutter-top', '${padding.top}px');
        document.documentElement.style.setProperty('--flutter-bottom', '${padding.bottom}px');
        document.documentElement.style.setProperty('--flutter-left', '${padding.left}px');
        document.documentElement.style.setProperty('--flutter-right', '${padding.right}px');
        document.documentElement.classList.add('safe-ready');
      } catch(e) {}
    ''');
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
            controller.addJavaScriptHandler(
              handlerName: 'routeChanged',
              callback: (args) {
                if (args.isNotEmpty) {
                  setState(() {
                    _currentRoute = args.first.toString();
                  });
                  debugPrint("🌐 React reported route: ${args.first}");
                }
              },
            );
          },
          onLoadStart: (controller, url) {
            debugPrint("🔄 PAGE LOAD START");
            _isPageLoaded = false;
            setState(() { _showLoading = true; _hasError = false; });
          },
          onLoadStop: (controller, url) async {
             debugPrint("✅ PAGE LOAD STOP");
             _isPageLoaded = true;
             setState(() { _showLoading = false; _hasError = false; });
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
          },
          onReceivedError: (controller, request, error) {
            // Only surface main frame errors to avoid noise from sub-resource failures
            if (request.isForMainFrame ?? false) {
              final desc = error.description;
              debugPrint("❌ WebView load error: $desc (url: ${request.url})");
              setState(() { _hasError = true; _showLoading = false; _errorDescription = desc; });
            }
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri == null) return NavigationActionPolicy.CANCEL;
            const allowedHost = "zen-react-launch.lovable.app";
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
              debugPrint("❌ Recovery failed after RenderProcessGone: $e");
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
                              backgroundColor: const Color(0xFFD4B8D8).withOpacity(0.4),
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
                      border: Border.all(color: Colors.white.withOpacity(0.8), width: 2),
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
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 30,
                          offset: const Offset(0, 10),
                        ),
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
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
                              onTapDown: (_) => setState(() => _isRetryPressed = true),
                              onTapUp: (_) {
                                setState(() => _isRetryPressed = false);
                                setState(() {
                                  _hasError = false;
                                  _showLoading = true;
                                });
                                _controller?.reload();
                              },
                              onTapCancel: () => setState(() => _isRetryPressed = false),
                              child: AnimatedScale(
                                scale: _isRetryPressed ? 0.95 : 1.0,
                                duration: const Duration(milliseconds: 100),
                                curve: Curves.easeInOut,
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
                                        colors: [Color(0xFFFF7EB3), Color(0xFF8FD3F4)],
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.1),
                                          blurRadius: 8,
                                          offset: const Offset(0, 4),
                                        ),
                                        BoxShadow(
                                          color: const Color(0xFFFF7EB3).withOpacity(0.3),
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
    final paint = Paint()..color = Colors.white.withOpacity(0.6);
    
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
        
        canvas.drawPath(path, Paint()..color = Colors.white.withOpacity(0.9));
      } else {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
