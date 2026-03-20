import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
  // !! REPLACE WITH YOUR DEPLOYED URL !!
  static const String _webAppUrl = 'https://hello-blank-react.lovable.app';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Re-inject on orientation/metrics change
    _injectSafeArea();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Re-inject on resume
      _injectSafeArea();
    }
  }

  void _injectSafeArea() {
    if (_controller == null || !mounted) return;
    
    // Use View to safely get padding outside of the build phase
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
    return Scaffold(
      // CRITICAL: Prevent layout jump when keyboard opens
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black, // Prevents white flash
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(_webAppUrl)),
        initialSettings: InAppWebViewSettings( // Replaces generic options
          javaScriptEnabled: true,
          domStorageEnabled: true,
          overScrollMode: OverScrollMode.NEVER, // Disable overscroll glow
          verticalScrollBarEnabled: false,      // Disable native scrollbars
          horizontalScrollBarEnabled: false,
          useHybridComposition: true,           // Enable hybrid composition globally
          transparentBackground: true,
        ),
        onWebViewCreated: (controller) {
          _controller = controller;
        },
        onLoadStop: (controller, url) {
           // Inject explicit safe-areas right after page load
           _injectSafeArea();
           
           // Inject CSS cleanup specifically for Chromium scrollbars
           controller.evaluateJavascript(source: '''
              var style = document.createElement('style');
              style.innerHTML = `
                ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
                * { scrollbar-width: none !important; -webkit-tap-highlight-color: transparent !important; }
              `;
              document.head.appendChild(style);
           ''');
        },
        onUpdateVisitedHistory: (controller, url, androidIsReload) {
            // Equivalent hook for catching DOM readies when load completes/commits
            _injectSafeArea();
        },
        onRenderProcessGone: (controller, detail) async {
          // CRITICAL: Recover from WebView crashes automatically
          await controller.reload();
          
          // re-inject safe area AFTER reload
          _injectSafeArea();
        },
      ),
    );
  }
}
