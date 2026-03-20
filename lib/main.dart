import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:app_links/app_links.dart';

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

class _WebViewScreenState extends State<WebViewScreen> with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  static const String _rootRoute = "/";
  static const String _webAppUrl = 'https://bare-react-bliss.lovable.app';
  
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  
  bool _isPageLoaded = false;
  bool _historyCleared = false;
  String? _pendingPath;
  String _currentRoute = _rootRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeepLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
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

    debugPrint("Navigating React to: $path");
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

        // Root check: If at / or empty, exit the app
        if (_currentRoute == _rootRoute || _currentRoute.isEmpty) {
          SystemNavigator.pop();
          return;
        }

        // Native behavior: Delegate back navigation ONLY to React via JS bridge
        try {
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
        backgroundColor: Colors.black,
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_webAppUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            useHybridComposition: true,
            // Disable hardware acceleration to prevent renderer crashes on certain devices (e.g. Vivo)
            hardwareAcceleration: false,
            overScrollMode: OverScrollMode.NEVER,
            verticalScrollBarEnabled: false,
            horizontalScrollBarEnabled: false,
            transparentBackground: true,
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
                  debugPrint("React route changed: $_currentRoute");
                }
              },
            );
          },
          onLoadStart: (controller, url) {
            _isPageLoaded = false;
          },
          onLoadStop: (controller, url) async {
             _isPageLoaded = true;
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
          onUpdateVisitedHistory: (controller, url, androidIsReload) {
              _injectSafeArea();
          },
          onRenderProcessGone: (controller, detail) async {
            _isPageLoaded = false;
            await controller.reload();
            _injectSafeArea();
          },
        ),
      ),
    );
  }
}
