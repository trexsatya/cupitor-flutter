import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WebView Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: WebViewExample(),
    );
  }
}

class WebViewExample extends StatefulWidget {
  @override
  WebViewExampleState createState() => WebViewExampleState();
}

class WebViewExampleState extends State<WebViewExample> with WidgetsBindingObserver {
  late final WebViewController _controller;
  WebViewController? dialogController;
  final TextEditingController _urlController = TextEditingController(text: 'https://google.com');
  String _dialogUrl = 'https://satyendra.website/language.html';
  final List<String> _languages = ['sv', 'es'];
  final Map<String, String> _languageParams = {'sv': 'swedish', 'es': 'spanish'};
  String _selectedLanguage = 'sv';
  bool _isControllerReady = false;
  List<String> _bookmarks = [];
  Map<String, String> _bookmarkNames = {};
  int _pageZoomLevel = 0; // each step ≈ 15% on top of 1.0, clamped to [-4, 10]
  // Minimize state for dialog webviews — when true, the dialog was dismissed via
  // the Minimize button and can be restored from the main screen. The controllers
  // stay alive so the page state (scroll, form input) survives.
  bool _dialog1Minimized = false;
  bool _dialog1EverMinimized = false; // Track if dialog1 has ever been minimized
  // Is dialog1 currently presented on the Navigator stack? Used to suppress
  // duplicate showDialog pushes from re-entrant calls — e.g. voice input
  // fired from inside the open dialog already updates the live WebView via
  // runJavaScript, so it must not also push a fresh dialog route on top.
  bool _dialog1Visible = false;

  // Multiple dialog2 instances - each link opens a new dialog
  Map<String, WebViewController> _dialog2Controllers = {};
  Map<String, ValueNotifier<String?>> _dialog2ErrorNotifiers = {};
  Map<String, String> _dialog2Urls = {};
  Set<String> _minimizedDialog2s = {};
  Set<String> _everMinimizedDialog2s = {}; // Track dialogs that have ever been minimized
  String _currentDialogText = '';
  String? _cachedRemoteSnippet;
  final Set<String> _handledPdfUrls = {};
  bool _isTextView = false;
  bool _isShowingOurHtml = false;
  bool _isExtractingPdf = false;
  String? _currentPdfUrl;
  String? _extractedPdfHtml;
  String _lastStartedUrl = '';
  bool _isEinkMode = true;
  // Mirrors _isEinkMode for widgets that live outside the State's rebuild scope
  // — namely the WebViews inside `showDialog`-built dialog routes, which the
  // parent's setState() does not reach. Updated alongside _isEinkMode in the
  // Tools-drawer toggle.
  final ValueNotifier<bool> _einkModeNotifier = ValueNotifier(true);
  static const ColorFilter _einkColorFilter = ColorFilter.matrix([
    0.1913, 0.6437, 0.0650, 0, 0.05,
    0.1850, 0.6222, 0.0628, 0, 0.04,
    0.1722, 0.5793, 0.0585, 0, 0.02,
    0,      0,      0,      1, 0,
  ]);
  static const ColorFilter _identityColorFilter = ColorFilter.matrix([
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ]);
  // In-memory buffer for console output captured from the injected remote
  // snippet. Lives until the app process exits — no persistence.
  final List<String> _snippetLogs = [];
  final ValueNotifier<int> _snippetLogVersion = ValueNotifier(0);
  static const int _kSnippetLogCap = 500;
  bool _showToolbar = false;
  bool _showAppBar = true;
  String? _githubToken;
  int _pdfTextFontSize = 15;
  bool _showFindBar = false;
  bool _urlBarFocused = false;
  String _pdfSelectedText = '';
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  // Mirror of _isListening for widgets in showDialog routes (which the outer
  // setState() doesn't reach).
  final ValueNotifier<bool> _isListeningNotifier = ValueNotifier(false);
  final TextEditingController _findController = TextEditingController();
  int? _pendingScrollToPage;
  int? _pendingPdfPage;
  // Scroll position cache: URL → scrollY or pdfPage (max 50 entries, persisted)
  Map<String, double> _scrollPositions = {};
  static const int _maxScrollEntries = 50;
  String? _prevPageUrl; // URL of the page we're navigating away from
  PdfViewerController? _pdfViewerController;
  double _pdfFitZoom = 0.0;
  int _pdfZoomLevel = 0;
  // Tracks Android main-frame navigations to detect the second onNavigationRequest
  // call that the download listener makes when WebView can't render a response
  // (e.g. application/pdf). First call = normal navigation; second call = download trigger.
  final Set<String> _androidPendingUrls = {};
  final ValueNotifier<String?> _dialogErrorNotifier = ValueNotifier(null);
  static const _adBlockChannel = MethodChannel('cupitor/adblock');
  // Hosts auto-detected by the native ad-blocker that haven't been confirmed yet.
  final List<String> _detectedAdHosts = [];
  bool _adBlockEnabled = true;

  // YouTube playback mode. Empty/null = native YouTube (with our JSON-prune
  // ad-blocker). Otherwise the hostname of an Invidious/Piped front-end (e.g.
  // "piped.video", "yewtu.be") to redirect youtube.com URLs to. Persisted
  // under SharedPreferences key "youtubeFrontend".
  String? _youtubeFrontend;

  // Filmot: persistent channel blacklist (results from these YouTube channels
  // are hidden on filmot.com pages). Edited per-page from the dialog.
  Set<String> _filmotChannelBlacklist = {};
  // When true, blacklist is suppressed in-session only — not persisted.
  bool _filmotBlacklistDisabled = false;
  // Persisted list of saved videos. Each entry: {url, title, channel, savedAt}.
  List<Map<String, String>> _savedVideos = [];
  // Channels observed on the currently-loaded filmot page (in-memory only).
  // Keyed by dialog id so multiple filmot dialogs don't clobber each other.
  final Map<String, Set<String>> _filmotChannelsSeen = {};
  // Persistent videoId → channelName cache. Populated by oEmbed lookups, used
  // to apply the channel blacklist to Filmot search results (whose HTML does
  // not include the channel name).
  Map<String, String> _videoChannelCache = {};
  // In-flight oEmbed lookups (by id) so duplicate batches don't double-fetch.
  final Set<String> _videoChannelInflight = {};

  // Floating minimized-dialog chips. They live on the root Overlay so they
  // appear above any open showDialog route (the default bottom-right column
  // is hidden behind a dialog's barrier and inaccessible while a dialog is
  // showing). Each chip remembers its drag position keyed by dialog id.
  OverlayEntry? _floatingChipsEntry;
  final Map<String, Offset> _chipPositions = {};
  final ValueNotifier<int> _minimizedVersion = ValueNotifier(0);

  // Pretend to be Chrome — the default Android WebView UA contains "; wv)",
  // which Google explicitly checks for and uses to refuse OAuth flows
  // ("disallowed_useragent"). Without this, Sign-in-with-Google on sites like
  // filmot.com fails. Applied to every WebViewController we create.
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36';

  static const List<String> _youtubeFrontendInstances = [
    'piped.video',
    'yewtu.be',
    'invidious.fdn.fr',
    'invidious.privacydev.net',
    'inv.nadeko.net',
  ];

  @override
  void dispose() {
    _appBarTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _adBlockChannel.setMethodCallHandler(null); // stop receiving callbacks
    // Save scroll position of the current page before disposing
    final url = _urlController.text.trim();
    if (url.isNotEmpty) _saveScrollPosition(url);
    _urlController.dispose();
    _findController.dispose();
    _dialogErrorNotifier.dispose();
    _einkModeNotifier.dispose();
    _snippetLogVersion.dispose();
    // Clean up all dialog controllers on app dispose
    dialogController = null;
    _dialog2Controllers.clear();
    for (final notifier in _dialog2ErrorNotifiers.values) {
      notifier.dispose();
    }
    _dialog2ErrorNotifiers.clear();
    _dialog2Urls.clear();
    _minimizedDialog2s.clear();
    _everMinimizedDialog2s.clear(); // Clean up tracking state
    _floatingChipsEntry?.remove();
    _floatingChipsEntry = null;
    _minimizedVersion.dispose();
    _isListeningNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable();
    } else if (state == AppLifecycleState.paused) {
      WakelockPlus.disable();
      // Flush WebView cookies to disk so logins survive a force-kill that
      // happens before the system's next periodic flush.
      _flushCookies();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    // Listen for auto-detected ad hosts coming from the native layer
    if (Platform.isAndroid) {
      _adBlockChannel.setMethodCallHandler((call) async {
        if (call.method == 'onHostDetected') {
          final host = call.arguments['host'] as String?;
          if (host != null && mounted) _showDetectedAdHostBanner(host);
        }
      });
    }
    SharedPreferences.getInstance().then((prefs) {
      final savedUrl = prefs.getString('lastUrl') ?? _urlController.text;
      _urlController.text = savedUrl;
      // Load persisted scroll positions
      final scrollJson = prefs.getString('scrollPositions');
      if (scrollJson != null) {
        try {
          final decoded = jsonDecode(scrollJson) as Map<String, dynamic>;
          _scrollPositions = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
        } catch (_) {}
      }
      _bookmarks = prefs.getStringList('bookmarks') ?? [];
      final namesJson = prefs.getString('bookmarkNames');
      if (namesJson != null) {
        try {
          final decoded = jsonDecode(namesJson) as Map<String, dynamic>;
          _bookmarkNames = decoded.map((k, v) => MapEntry(k, v.toString()));
        } catch (_) {}
      }
      _githubToken = prefs.getString('githubToken');
      _pageZoomLevel = prefs.getInt('pageZoom') ?? 0;
      final yf = prefs.getString('youtubeFrontend');
      _youtubeFrontend = (yf != null && yf.isNotEmpty) ? yf : null;
      _filmotChannelBlacklist = (prefs.getStringList('filmotChannelBlacklist') ?? []).toSet();
      final savedJson = prefs.getString('savedVideos');
      if (savedJson != null) {
        try {
          final decoded = jsonDecode(savedJson) as List<dynamic>;
          _savedVideos = decoded.map((e) {
            final m = (e as Map<String, dynamic>);
            return m.map((k, v) => MapEntry(k, (v ?? '').toString()));
          }).toList();
        } catch (_) {}
      }
      final vcJson = prefs.getString('videoChannelCache');
      if (vcJson != null) {
        try {
          final decoded = jsonDecode(vcJson) as Map<String, dynamic>;
          _videoChannelCache = decoded.map((k, v) => MapEntry(k, v.toString()));
        } catch (_) {}
      }
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(_userAgent)
        ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) => _openDialogWithWebview(msg.message.toString().replaceAll('"', '')))
        ..addJavaScriptChannel('PdfIframeDetector', onMessageReceived: (msg) => _handlePdfIframe(msg.message))
        ..addJavaScriptChannel('SpaNavigationDetector', onMessageReceived: (msg) => _onSpaNavigation(msg.message))
        ..addJavaScriptChannel('AdHostDetector', onMessageReceived: (msg) => _onJsAdHostDetected(msg.message))
        ..addJavaScriptChannel('SelectionChannel', onMessageReceived: (_) {
          if (Platform.isAndroid && !_showAppBar) _showAppBarWithTimer();
        })
        ..addJavaScriptChannel('SnippetLogChannel', onMessageReceived: (msg) {
          final raw = msg.message;
          final pipe = raw.indexOf('|');
          if (pipe < 0) {
            _appendSnippetLog('log', raw);
          } else {
            _appendSnippetLog(raw.substring(0, pipe), raw.substring(pipe + 1));
          }
        })
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) async {
              if (!request.isMainFrame) return NavigationDecision.navigate;
              // Redirect YouTube → Invidious/Piped if the user has chosen a
              // front-end. The rewritten URL re-enters this delegate but no
              // longer matches the YouTube host check, so no infinite loop.
              final rewritten = _rewriteYouTubeUrl(request.url);
              if (rewritten != null) {
                _controller.loadRequest(Uri.parse(rewritten));
                return NavigationDecision.prevent;
              }
              final url = request.url;
              // Always intercept .pdf extension URLs on Android before WebView touches them.
              if (Platform.isAndroid && _looksLikePdfUrl(url)) {
                if (mounted) setState(() {
                  _urlController.text = url;
                  _currentPdfUrl = url;
                  _lastStartedUrl = url;
                  _extractedPdfHtml = null;
                  _isTextView = false;
                  _isShowingOurHtml = false;
                  _handledPdfUrls.clear();
                });
                return NavigationDecision.prevent;
              }
              if (Platform.isAndroid) {
                if (_androidPendingUrls.contains(url)) {
                  // Second call for this URL = download listener fired = WebView
                  // cannot render the content. Check if it is a PDF.
                  _androidPendingUrls.remove(url);
                  try {
                    final response = await http
                        .head(Uri.parse(url))
                        .timeout(const Duration(seconds: 5));
                    final ct = response.headers['content-type'] ?? '';
                    if (ct.contains('application/pdf') && mounted) {
                      setState(() {
                        _urlController.text = url;
                        _currentPdfUrl = url;
                        _lastStartedUrl = url;
                        _extractedPdfHtml = null;
                        _isTextView = false;
                        _isShowingOurHtml = false;
                        _handledPdfUrls.clear();
                      });
                      return NavigationDecision.prevent;
                    }
                  } catch (_) { /* network error — let it proceed */ }
                } else {
                  // First call — allow, but remember so we catch the second call.
                  _androidPendingUrls.add(url);
                  // Auto-clean after 30 s so the set never grows unbounded.
                  Future.delayed(
                    const Duration(seconds: 30),
                    () => _androidPendingUrls.remove(url),
                  );
                }
              }
              return NavigationDecision.navigate;
            },
            onPageStarted: (url) {
              if (_isShowingOurHtml) return; // our own HTML page, don't reset state
              // Save scroll position of the page we're leaving
              if (_prevPageUrl != null) _saveScrollPosition(_prevPageUrl!);
              _prevPageUrl = url.split('#').first;
              _lastStartedUrl = url;
              setState(() {
                // Show the clean URL without #page=N fragment
                _urlController.text = url.split('#').first;
                if (_looksLikePdfUrl(url)) {
                  // Strip fragment (#page=N) when comparing so reloading
                  // the same PDF with a page anchor doesn't reset state.
                  final baseUrl = url.split('#').first;
                  final baseCurrentPdf = (_currentPdfUrl ?? '').split('#').first;
                  if (baseCurrentPdf != baseUrl) {
                    _currentPdfUrl = baseUrl;
                    _extractedPdfHtml = null;
                    _isTextView = false;
                  }
                } else {
                  _currentPdfUrl = null;
                  _extractedPdfHtml = null;
                  _isTextView = false;
                  _isShowingOurHtml = false;
                  _handledPdfUrls.clear();
                  _pdfViewerController = null;
                  _pdfFitZoom = 0.0;
                  _pdfZoomLevel = 0;
                }
              });
              // On Android, start PDF detection right here — onPageFinished may never
              // fire if the WebView triggers a download intent for the content.
              if (Platform.isAndroid && _currentPdfUrl == null) {
                _checkForPdf(url);
              }
              // Inject the YT ad-blocker as early as possible so its property
              // setter on window.ytInitialPlayerResponse can fire before
              // YouTube's inline assignment script. The script is hostname-
              // gated and idempotent, so it's safe to call on every navigation.
              _injectYouTubeAdBlocker();
            },
            onPageFinished: (url) {
              if (_isShowingOurHtml) {
                _injectJs(); // only need word-click JS on our own text page
                // Scroll to preserved page position if switching from PDF view
                if (_pendingScrollToPage != null && _pendingScrollToPage! > 1) {
                  final pg = _pendingScrollToPage!;
                  _pendingScrollToPage = null;
                  _controller.runJavaScript(
                    'document.getElementById("pg-$pg")?.scrollIntoView({behavior:"instant"});'
                  );
                }
                return;
              }
              _pendingPdfPage = null; // clear after PDF loads
              if (Platform.isAndroid) _attachAndroidAdBlocker();
              _injectJs();
              _injectAdBlocker();
              _injectSpaHook();
              _injectPageZoom();
              _injectSelectionWatcher();
              // Detect PDF by content-type (handles non-.pdf URLs like download links)
              // and defer _injectPdfDetector so it never fires on native PDF pages.
              _detectPdfAndInject(url);
              // Restore scroll position for this URL
              _restoreScrollPosition(url);
              _injectRemoteSnippet();
            },
          ),
        )
        ..loadRequest(Uri.parse(savedUrl));
      _enableThirdPartyCookies(_controller);
      setState(() {
        _isControllerReady = true;
      });
    });
  }

  void _showTokenDialog() {
    final ctrl = TextEditingController(text: _githubToken ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('GitHub Token'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: InputDecoration(
            hintText: 'ghp_...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            child: Text('Clear'),
            onPressed: () async {
              setState(() => _githubToken = null);
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('githubToken');
              Navigator.of(ctx).pop();
            },
          ),
          TextButton(
            child: Text('Save'),
            onPressed: () async {
              final token = ctrl.text.trim();
              setState(() => _githubToken = token.isEmpty ? null : token);
              final prefs = await SharedPreferences.getInstance();
              if (token.isEmpty) {
                await prefs.remove('githubToken');
              } else {
                await prefs.setString('githubToken', token);
              }
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }

  /// Save current scroll position for the given URL.
  Future<void> _saveScrollPosition(String url) async {
    if (url.isEmpty || url == 'about:blank') return;
    final baseUrl = url.split('#').first;
    double pos = 0;
    if (_currentPdfUrl != null && !_isTextView) {
      // PDF view: save page number as scroll position
      pos = (_pdfViewerController?.pageNumber ?? 1).toDouble();
    } else {
      // WebView (HTML or text view): save scrollY
      try {
        final result = await _controller.runJavaScriptReturningResult('window.scrollY');
        pos = double.tryParse(result.toString()) ?? 0;
      } catch (_) {}
    }
    if (pos <= 0) return;
    _scrollPositions[baseUrl] = pos;
    // Evict oldest entries if over limit
    if (_scrollPositions.length > _maxScrollEntries) {
      final keys = _scrollPositions.keys.toList();
      for (int i = 0; i < keys.length - _maxScrollEntries; i++) {
        _scrollPositions.remove(keys[i]);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('scrollPositions', jsonEncode(_scrollPositions));
  }

  /// Restore scroll position for the given URL.
  void _restoreScrollPosition(String url) {
    final baseUrl = url.split('#').first;
    final pos = _scrollPositions[baseUrl];
    if (pos == null || pos <= 0) return;
    if (_currentPdfUrl != null) {
      // PDF view: restore page number
      _pdfViewerController?.goToPage(pageNumber: pos.round());
    } else {
      // WebView: restore scrollY with a delay for layout to settle
      _controller.runJavaScript(
        'setTimeout(function(){window.scrollTo(0,$pos);},300);'
      );
    }
  }

  /// For text view: adjusts the CSS --fs variable in the loaded HTML.
  /// For native PDF view: steps through pdfrx zoom stops, but anchors to
  /// fit-to-width so tapping the page never resets the level.
  void _changePdfZoom(int delta) {
    if (_isTextView) {
      final newSize = (_pdfTextFontSize + delta).clamp(10, 32);
      if (newSize == _pdfTextFontSize) return;
      setState(() => _pdfTextFontSize = newSize);
      _controller.runJavaScript(
          "document.documentElement.style.setProperty('--fs','${newSize}px');");
    } else if (_pdfViewerController != null) {
      final newLevel = (_pdfZoomLevel + delta).clamp(-2, 8);
      if (newLevel == _pdfZoomLevel) return;
      _pdfZoomLevel = newLevel;
      _applyPdfZoom();
    }
  }

  void _applyPdfZoom() {
    final ctrl = _pdfViewerController;
    if (ctrl == null || _pdfFitZoom <= 0) return;
    final vs = ctrl.viewSize;
    if (vs == null) return;
    final targetZoom = _pdfFitZoom * (1.0 + _pdfZoomLevel * 0.25).clamp(0.25, 4.0);
    final cur = ctrl.currentZoom;
    final t = ctrl.value.getTranslation();
    ctrl.setZoom(
      Offset((vs.width / 2 - t.x) / cur, (vs.height / 2 - t.y) / cur),
      targetZoom,
      duration: const Duration(milliseconds: 200),
    );
  }

  bool _looksLikePdfUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    return path.toLowerCase().endsWith('.pdf');
  }

  /// Watches the page for non-empty text selections and pings Flutter when one
  /// appears, so we can pop the app bar back into view. Debounced so that the
  /// channel doesn't fire for every cursor tick during a drag-select.
  void _injectSelectionWatcher() {
    _controller.runJavaScript(r'''
      (function(){
        if (window.__cupSelectionWatcher) return;
        window.__cupSelectionWatcher = true;
        var lastNonEmpty = '';
        var timer = null;
        document.addEventListener('selectionchange', function(){
          if (timer) clearTimeout(timer);
          timer = setTimeout(function(){
            try {
              var s = (window.getSelection ? window.getSelection().toString() : '') || '';
              s = s.trim();
              if (s && s !== lastNonEmpty) {
                lastNonEmpty = s;
                try { SelectionChannel.postMessage('1'); } catch(e) {}
              } else if (!s) {
                lastNonEmpty = '';
              }
            } catch(e) {}
          }, 150);
        });
      })();
    ''');
  }

  void _injectPageZoom() {
    // Only apply scaling when the user actually set a non-default level.
    // Using transform: scale() instead of CSS zoom to avoid layout breakage.
    // CSS zoom creates a new containing block and breaks many modern layouts,
    // while transform: scale() preserves the original layout structure.
    if (_pageZoomLevel == 0) {
      _controller.runJavaScript('''
        document.documentElement.style.removeProperty('transform');
        document.documentElement.style.removeProperty('transform-origin');
        document.body.style.removeProperty('width');
        document.body.style.removeProperty('overflow-x');
      ''');
      return;
    }
    final scale = (1.0 + _pageZoomLevel * 0.15).clamp(0.5, 2.5);
    _controller.runJavaScript('''
      // Use transform: scale() which preserves layout flow
      document.documentElement.style.transform = 'scale($scale)';
      document.documentElement.style.transformOrigin = 'top left';
      // Adjust body width to prevent horizontal scrollbar issues
      if ($scale < 1.0) {
        document.body.style.width = '${(100 / scale).toStringAsFixed(1)}%';
        document.body.style.overflowX = 'hidden';
      } else {
        document.body.style.removeProperty('width');
        document.body.style.removeProperty('overflow-x');
      }
    ''');
  }

  Future<void> _changePageZoom(int delta) async {
    final next = (_pageZoomLevel + delta).clamp(-4, 10);
    if (next == _pageZoomLevel) return;
    setState(() => _pageZoomLevel = next);
    _injectPageZoom();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pageZoom', _pageZoomLevel);
  }

  /// Does a HEAD request to check if [url] serves PDF content.
  /// Sets [_currentPdfUrl] if confirmed. Safe to call from both
  /// onPageStarted and onPageFinished — the _lastStartedUrl guard
  /// discards results that arrive after the user has navigated away.
  Future<void> _checkForPdf(String url) async {
    if (_currentPdfUrl != null) return;
    try {
      final response = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 5));
      final ct = response.headers['content-type'] ?? '';
      if (ct.contains('application/pdf')) {
        if (!mounted || _lastStartedUrl != url) return;
        setState(() { _currentPdfUrl = url; });
      }
    } catch (_) { /* best-effort; non-critical */ }
  }

  /// After page load, check if the page is a PDF and — if not — inject the
  /// iframe PDF detector. (The detector must NOT run on native PDF pages.)
  Future<void> _detectPdfAndInject(String url) async {
    await _checkForPdf(url);
    if (_currentPdfUrl != null) return; // it's a PDF — don't inject iframe detector
    if (!mounted || _lastStartedUrl != url) return;
    _injectPdfDetector();
  }

  Future<void> _togglePdfTextView() async {
    if (_currentPdfUrl == null) return;
    if (_isTextView) {
      // --- Text → PDF: get visible page number from text view ---
      int visiblePage = 1;
      try {
        final result = await _controller.runJavaScriptReturningResult('''
          (function() {
            var best = 1;
            var els = document.querySelectorAll('.pg[id^="pg-"]');
            for (var i = 0; i < els.length; i++) {
              var r = els[i].getBoundingClientRect();
              if (r.top <= window.innerHeight / 2) {
                best = parseInt(els[i].id.replace('pg-', ''));
              }
            }
            return best;
          })();
        ''');
        visiblePage = int.tryParse(result.toString()) ?? 1;
      } catch (_) {}

      // Switch state — PdfViewer overlay reappears and navigates to page
      setState(() { _isTextView = false; _isShowingOurHtml = false; });
      _pdfViewerController?.goToPage(pageNumber: visiblePage);
      return;
    }

    // --- PDF → Text: get current page from PdfViewer ---
    int currentPage = _pdfViewerController?.pageNumber ?? 1;

    // Build or reuse cached rich HTML
    if (_extractedPdfHtml == null) {
      setState(() => _isExtractingPdf = true);
      try {
        final response = await http.get(Uri.parse(_currentPdfUrl!), headers: {
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        }).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          debugPrint('PDF fetch failed: HTTP ${response.statusCode}');
          setState(() => _isExtractingPdf = false);
          return;
        }
        final doc = await PdfDocument.openData(response.bodyBytes);
        _extractedPdfHtml = await _buildPdfHtml(doc);
        await doc.dispose();
      } catch (e) {
        debugPrint('PDF extraction error: $e');
        setState(() => _isExtractingPdf = false);
        return;
      }
      setState(() => _isExtractingPdf = false);
    }
    if (_extractedPdfHtml == null || _extractedPdfHtml!.isEmpty) {
      debugPrint('No extractable text in PDF (image-based?).');
      return;
    }
    setState(() { _isTextView = true; _isShowingOurHtml = true; });
    await _controller.loadHtmlString(_extractedPdfHtml!);
    // After page loads, scroll to the page marker
    _pendingScrollToPage = currentPage;
    // onPageFinished will inject utils.js and scroll to the page marker
  }

  // ---------------------------------------------------------------------------
  // Rich PDF HTML builder (research-paper-aware)
  // ---------------------------------------------------------------------------

  Future<String> _buildPdfHtml(PdfDocument doc) async {
    final buf = StringBuffer();
    buf.write('<!DOCTYPE html><html><head>'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>'
        ':root{--fs:${_pdfTextFontSize}px}'
        'body{font-family:Georgia,serif;font-size:var(--fs);line-height:1.75;'
        'padding:20px 28px;margin:0 auto;max-width:720px;background:#fff;'
        '-webkit-user-select:text;user-select:text;}'
        'p{margin:0 0 0.45em;}'
        '.pg{text-align:center;color:#888;font-size:0.78em;'
        'margin:1.4em 0 1em;letter-spacing:0.12em;}'
        '.gap{display:block;border:1px dashed #bbb;border-radius:4px;'
        'padding:8px 12px;margin:10px 0;color:#999;font-style:italic;'
        'font-size:0.82em;text-align:center;background:#f8f8f8;}'
        '.fn{border-top:1px solid #ccc;margin-top:14px;padding-top:8px;'
        'font-size:0.80em;color:#444;line-height:1.5;}'
        '.fn-lbl{color:#999;font-size:0.75em;letter-spacing:0.08em;margin-bottom:4px;}'
        '</style></head><body>');
    bool hasAnyText = false;
    for (int pi = 0; pi < doc.pages.length; pi++) {
      final page = doc.pages[pi];
      final pt = await page.loadText();
      final allFrags = pt.fragments.where((f) => f.text.trim().isNotEmpty).toList();
      buf.write('<div class="pg" id="pg-${pi + 1}">— Page ${pi + 1} —</div>');
      if (allFrags.isEmpty) continue;
      hasAnyText = true;

      // Compute per-fragment average char heights for font-size detection
      final fragHeights = <double>[];
      for (final f in allFrags) {
        final rects = f.charRects.where((r) => r.height > 1).toList();
        fragHeights.add(rects.isEmpty ? 0.0
            : rects.map((r) => r.height).reduce((a, b) => a + b) / rects.length);
      }

      // Median char height ≈ body font size in PDF points
      final nonZeroH = fragHeights.where((h) => h > 0).toList()..sort();
      final medH = nonZeroH.isEmpty ? 10.0 : nonZeroH[nonZeroH.length ~/ 2];

      // Detect footnotes by structure: cluster fragments into lines, then
      // scan from bottom up looking for lines that start with a digit
      // (e.g. "1 Some footnote text..." or "12 Another footnote").
      // The footnote block is the contiguous run of such numbered lines
      // at the bottom of the page (in the lower 40%).

      // First, cluster ALL fragments into lines (same logic as _emitLines)
      final sorted = [...allFrags]..sort((a, b) => b.bounds.top.compareTo(a.bounds.top));
      final pageLines = <List<PdfPageTextFragment>>[];
      {
        var cur = <PdfPageTextFragment>[sorted.first];
        double cySum = sorted.first.bounds.top;
        int cyCount = 1;
        final yt = medH * 0.6;
        for (int i = 1; i < sorted.length; i++) {
          final f = sorted[i];
          if ((cySum / cyCount - f.bounds.top).abs() < yt) {
            cur.add(f);
            cySum += f.bounds.top;
            cyCount++;
          } else {
            pageLines.add(cur);
            cur = [f];
            cySum = f.bounds.top;
            cyCount = 1;
          }
        }
        pageLines.add(cur);
      }
      // Sort fragments within each line left-to-right
      for (final line in pageLines) {
        line.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      }

      // Scan from the last line upward; collect lines that belong to footnotes.
      // A footnote-starting line begins with a digit. Continuation lines
      // (that don't start with a digit) are included if they follow a
      // footnote-starting line without a large gap.
      final pageBottom = page.height * 0.45; // only look in lower 45%
      final fnLineIndices = <int>{};
      bool inFootnoteRegion = false;

      // Pre-compute average char height per line
      final lineAvgHeights = <int, double>{};
      for (int li = 0; li < pageLines.length; li++) {
        double h = 0; int c = 0;
        for (final f in pageLines[li]) {
          for (final r in f.charRects) {
            if (r.height > 1) { h += r.height; c++; }
          }
        }
        lineAvgHeights[li] = c > 0 ? h / c : medH;
      }

      for (int li = pageLines.length - 1; li >= 0; li--) {
        final line = pageLines[li];
        final lineTop = line.map((f) => f.bounds.top).reduce(math.max);
        if (lineTop > pageBottom) break; // past the lower region

        final lineText = line.map((f) => f.text).join(' ').trim();
        if (lineText.isEmpty) continue;

        // Skip lone page numbers (just digits, very short)
        if (RegExp(r'^\d{1,4}$').hasMatch(lineText)) continue;

        final avgLineH = lineAvgHeights[li] ?? medH;
        final isSmallFont = avgLineH < medH * 0.93;

        // "1. Text..." or "12. Text..." — numbered footnote pattern
        final startsWithNum = RegExp(r'^\d+[\.\)]?\s').hasMatch(lineText);
        if (startsWithNum && isSmallFont) {
          // Strong: numbered + smaller font → footnote start
          inFootnoteRegion = true;
          fnLineIndices.add(li);
        } else if (inFootnoteRegion && isSmallFont) {
          // Continuation line (wrapped footnote text, same small font)
          fnLineIndices.add(li);
        } else if (inFootnoteRegion && !isSmallFont) {
          // Hit normal-sized text — footnote region ends
          break;
        }
      }

      // Separate body and footnote fragments
      final body = <PdfPageTextFragment>[];
      final fn = <PdfPageTextFragment>[];
      if (fnLineIndices.isNotEmpty) {
        final fnFrags = <PdfPageTextFragment>{};
        for (final li in fnLineIndices) {
          fnFrags.addAll(pageLines[li]);
        }
        for (final f in allFrags) {
          if (fnFrags.contains(f)) {
            fn.add(f);
          } else {
            body.add(f);
          }
        }
      } else {
        body.addAll(allFrags);
      }

      // Sort top-to-bottom (largest y = top of page in PDF coords)
      body.sort((a, b) => b.bounds.top.compareTo(a.bounds.top));
      fn.sort((a, b) => b.bounds.top.compareTo(a.bounds.top));

      _emitLines(buf, body, medH, isFootnote: false);
      if (fn.isNotEmpty) {
        buf.write('<div class="fn"><div class="fn-lbl">Footnotes</div>');
        _emitLines(buf, fn, medH, isFootnote: true);
        buf.write('</div>');
      }
    }
    if (!hasAnyText) return '';
    buf.write('</body></html>');
    return buf.toString();
  }

  void _emitLines(StringBuffer buf, List<PdfPageTextFragment> frags,
      double medH, {required bool isFootnote}) {
    if (frags.isEmpty) return;

    // --- Step 1: Cluster fragments into lines by y-position ---
    // Use a running average for the cluster's y so drift doesn't accumulate.
    final lines = <List<PdfPageTextFragment>>[];
    var cur = <PdfPageTextFragment>[frags.first];
    double clusterYSum = frags.first.bounds.top;
    int clusterCount = 1;
    final yThresh = medH * 0.6; // tighter threshold: 60% of median char height

    for (int i = 1; i < frags.length; i++) {
      final f = frags[i];
      final clusterAvgY = clusterYSum / clusterCount;
      if ((clusterAvgY - f.bounds.top).abs() < yThresh) {
        cur.add(f);
        clusterYSum += f.bounds.top;
        clusterCount++;
      } else {
        lines.add(cur);
        cur = [f];
        clusterYSum = f.bounds.top;
        clusterCount = 1;
      }
    }
    lines.add(cur);

    // --- Step 2: Compute line positions and typical spacing ---
    // Pre-sort each line and compute top/bottom for gap analysis.
    final lineTops = <double>[];
    final lineBottoms = <double>[];
    for (final line in lines) {
      line.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      lineTops.add(line.map((f) => f.bounds.top).reduce(math.max));
      lineBottoms.add(line.map((f) => f.bounds.bottom).reduce(math.min));
    }

    // Compute typical inter-line gap from the middle 80% of gaps
    // (excludes heading gaps at top and section breaks)
    final interGaps = <double>[];
    for (int i = 1; i < lines.length; i++) {
      final gap = lineBottoms[i - 1] - lineTops[i];
      if (gap > 0) interGaps.add(gap);
    }
    interGaps.sort();
    final medGap = interGaps.isEmpty ? medH * 1.5
        : interGaps[interGaps.length ~/ 2];
    // A gap is "large" if it exceeds both:
    //   - 3× the median inter-line gap (adapts to the page's actual spacing)
    //   - 2.5× the body font height (absolute floor)
    final largeGapThresh = math.max(medGap * 3.0, medH * 2.5);

    // --- Step 3: Render each line with gap-aware joining ---
    for (int li = 0; li < lines.length; li++) {
      final line = lines[li];

      // Detect large vertical gaps → image/figure placeholder
      // Skip last line (page number). Check that both flanking lines have
      // substantial text so lone headers/page numbers don't trigger it.
      if (!isFootnote && li > 0 && li < lines.length - 1
          && lineBottoms[li - 1] - lineTops[li] > largeGapThresh) {
        final prevText = lines[li - 1].map((f) => f.text).join(' ').trim();
        final curText = line.map((f) => f.text).join(' ').trim();
        if (prevText.length > 10 && curText.length > 10) {
          buf.write('<span class="gap">[ Figure / Image / Diagram ]</span>');
        }
      }

      // Compute average char width for space-detection threshold
      double totalW = 0; int charCount = 0;
      for (final f in line) {
        for (final r in f.charRects) {
          if (r.width > 0.5) { totalW += r.width; charCount++; }
        }
      }
      final avgCharW = charCount > 0 ? totalW / charCount : medH * 0.5;

      // Join fragments: use actual horizontal gap to decide spacing
      final sb = StringBuffer();
      for (int i = 0; i < line.length; i++) {
        final frag = line[i];
        if (i > 0) {
          final prevRight = line[i - 1].bounds.right;
          final curLeft = frag.bounds.left;
          final gap = curLeft - prevRight;
          // Gap wider than ~30% of avg char width → insert a space
          if (gap > avgCharW * 0.3) {
            sb.write(' ');
          }
          // Negative or tiny gap → fragments touch, no space needed
        }
        sb.write(_esc(frag.text));
      }
      final text = sb.toString();
      if (text.trim().isNotEmpty) buf.write('<p>$text</p>');
    }
  }

  String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  void _findInPage(String query, {bool forward = true}) {
    if (query.isEmpty) {
      _clearFindHighlights();
      return;
    }
    final jsStr = jsonEncode(query);
    _controller.runJavaScript('''
      (function() {
        // If query changed, rebuild highlights
        if (window._findQuery !== $jsStr) {
          // Clear old highlights
          document.querySelectorAll('mark._fh').forEach(function(m) {
            var p = m.parentNode;
            p.replaceChild(document.createTextNode(m.textContent), m);
            p.normalize();
          });
          window._findQuery = $jsStr;
          window._findIdx = -1;
          window._findMarks = [];
          // Walk text nodes and wrap matches
          var query = $jsStr.toLowerCase();
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          var node, matches = [];
          while (node = walker.nextNode()) {
            var text = node.textContent.toLowerCase();
            var idx = 0;
            while ((idx = text.indexOf(query, idx)) !== -1) {
              matches.push({node: node, start: idx, length: query.length});
              idx += query.length;
            }
          }
          // Apply marks in reverse so offsets stay valid
          for (var i = matches.length - 1; i >= 0; i--) {
            var m = matches[i];
            var range = document.createRange();
            range.setStart(m.node, m.start);
            range.setEnd(m.node, m.start + m.length);
            var mark = document.createElement('mark');
            mark.className = '_fh';
            mark.style.cssText = 'background:#ffeb3b;padding:0;margin:0;';
            range.surroundContents(mark);
          }
          window._findMarks = Array.from(document.querySelectorAll('mark._fh'));
        }
        if (window._findMarks.length === 0) return;
        // Navigate
        var dir = ${forward ? '1' : '-1'};
        window._findIdx = (window._findIdx + dir + window._findMarks.length) % window._findMarks.length;
        // Reset all to yellow, highlight current in orange
        window._findMarks.forEach(function(m) { m.style.background = '#ffeb3b'; });
        var cur = window._findMarks[window._findIdx];
        cur.style.background = '#ff9800';
        cur.scrollIntoView({block: 'center', behavior: 'smooth'});
      })();
    ''');
  }

  void _clearFindHighlights() {
    _controller.runJavaScript('''
      (function() {
        document.querySelectorAll('mark._fh').forEach(function(m) {
          var p = m.parentNode;
          p.replaceChild(document.createTextNode(m.textContent), m);
          p.normalize();
        });
        window._findQuery = '';
        window._findIdx = -1;
        window._findMarks = [];
      })();
    ''');
  }

  Future<void> _injectSpaHook() {
    const js = r'''
      (function() {
        if (window._spaHooked) return;
        window._spaHooked = true;
        function notify() {
          SpaNavigationDetector.postMessage(window.location.href);
        }
        const _push = history.pushState.bind(history);
        history.pushState = function(...args) { _push(...args); notify(); };
        const _replace = history.replaceState.bind(history);
        history.replaceState = function(...args) { _replace(...args); notify(); };
        window.addEventListener('popstate', notify);
        window.addEventListener('hashchange', notify);
      })();
    ''';
    return _controller.runJavaScript(js);
  }

  void _onSpaNavigation(String url) async {
    setState(() => _urlController.text = url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lastUrl', url);
    _injectJs();
    _injectRemoteSnippet();
    _injectAdBlocker();
    _injectYouTubeAdBlocker();
    _injectPdfDetector();
  }

  Future<void> _injectPdfDetector() {
    const js = r'''
      (function() {
        function checkEl(el) {
          const src = el.src || el.data || '';
          if (!src || el.dataset.pdfHandled) return;
          if (/\.pdf(\?.*)?$/i.test(src) || el.type === 'application/pdf') {
            el.dataset.pdfHandled = '1';
            // Resolve relative URLs against the current page
            const abs = new URL(src, window.location.href).href;
            const id = 'pdf_flutter_' + Math.random().toString(36).slice(2);
            el.id = id;
            PdfIframeDetector.postMessage(JSON.stringify({id: id, url: abs}));
          }
        }
        document.querySelectorAll('iframe, embed, object').forEach(checkEl);
        if (!window._pdfObserverAttached) {
          window._pdfObserverAttached = true;
          new MutationObserver(mutations => {
            mutations.forEach(m => m.addedNodes.forEach(node => {
              if (node.nodeType !== 1) return;
              if (['IFRAME','EMBED','OBJECT'].includes(node.tagName)) checkEl(node);
              node.querySelectorAll && node.querySelectorAll('iframe, embed, object').forEach(checkEl);
            }));
          }).observe(document.body, {childList: true, subtree: true});
        }
      })();
    ''';
    return _controller.runJavaScript(js);
  }

  Future<void> _handlePdfIframe(String message) async {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final id = data['id'] as String;
      final url = data['url'] as String;
      final uri = Uri.tryParse(url);
      if (uri == null) return;

      final response = await http.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        debugPrint('PDF fetch failed: HTTP ${response.statusCode} for $url');
        return;
      }

      final doc = await PdfDocument.openData(response.bodyBytes);
      final buffer = StringBuffer('--- Page 1 ---\n\n');
      for (int i = 0; i < doc.pages.length; i++) {
        final pageText = await doc.pages[i].loadText();
        buffer.write(pageText.fullText);
        if (i < doc.pages.length - 1) {
          buffer.write('\n\n--- Page ${i + 2} ---\n\n');
        }
      }
      await doc.dispose();

      // Use jsonEncode so all special characters are properly escaped as a JS string literal
      final textJson = jsonEncode(buffer.toString());
      final js = '''
        (function() {
          const el = document.getElementById('$id');
          if (!el) return;
          const div = document.createElement('div');
          div.style.cssText = 'width:100%;height:100%;overflow:auto;padding:16px;box-sizing:border-box;font-family:serif;font-size:15px;line-height:1.7;white-space:pre-wrap;user-select:text;-webkit-user-select:text;';
          div.textContent = $textJson;
          el.parentNode.replaceChild(div, el);
        })();
      ''';
      _controller.runJavaScript(js);
    } catch (e) {
      debugPrint('PDF handling error: $e');
    }
  }

  Future<void> _injectJs() async {
    final jsCode = await rootBundle.loadString('assets/js/utils.js');
    _controller.runJavaScript(jsCode);
  }

  void _injectRemoteSnippet() {
    http.get(
      Uri.parse('https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/refs/heads/gh-pages/db/js/snippet.js'),
    ).timeout(const Duration(seconds: 5)).then((response) {
      if (response.statusCode == 200) {
        _cachedRemoteSnippet = response.body;
        _controller.runJavaScript(_wrapSnippetWithLogShim(_cachedRemoteSnippet!));
      }
    }).catchError((_) {
      // Network unavailable, timeout, or server error — skip silently
      if (_cachedRemoteSnippet != null) {
        _controller.runJavaScript(_wrapSnippetWithLogShim(_cachedRemoteSnippet!));
      }
    });
  }

  // Wraps the remote snippet in an outer IIFE that shadows `console` with a
  // forwarder to SnippetLogChannel. Closure scope means only code inside this
  // wrapper sees the shim — page scripts continue to use the global console.
  String _wrapSnippetWithLogShim(String snippet) => '''
(function() {
  function _ser(args) {
    return Array.from(args).map(function(a) {
      if (typeof a === 'string') return a;
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }).join(' ');
  }
  function _s(level) {
    return function() {
      try { SnippetLogChannel.postMessage(level + '|' + _ser(arguments)); } catch (e) {}
    };
  }
  var console = { log: _s('log'), info: _s('info'), warn: _s('warn'), error: _s('error'), debug: _s('debug') };
  $snippet
})();
''';

  void _appendSnippetLog(String level, String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    _snippetLogs.add('[$ts] [$level] $msg');
    if (_snippetLogs.length > _kSnippetLogCap) {
      _snippetLogs.removeRange(0, _snippetLogs.length - _kSnippetLogCap);
    }
    _snippetLogVersion.value++;
  }

  void _showSnippetLogs() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: const Text('Snippet logs'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear',
              onPressed: () {
                _snippetLogs.clear();
                _snippetLogVersion.value++;
              },
            ),
          ],
        ),
        body: SafeArea(
          child: ValueListenableBuilder<int>(
            valueListenable: _snippetLogVersion,
            builder: (_, __, ___) => _snippetLogs.isEmpty
                ? const Center(child: Text('No logs yet'))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _snippetLogs.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    ));
  }

  /// Attaches the native Android ad-blocking WebViewClient via a platform
  /// channel. Safe to call on every page load — the Kotlin side is idempotent.
  /// Called when JS detects a 3rd-party host contacted during a confirmed ad.
  void _onJsAdHostDetected(String host) {
    if (!mounted) return;
    _showDetectedAdHostBanner(host);
  }

  void _attachAndroidAdBlocker() {
    _adBlockChannel.invokeMethod<void>('attach').catchError((_) {});
  }

  /// Enable third-party cookies on the underlying Android WebView. Many sign-in
  /// flows (OAuth callbacks, Google / GitHub login redirects) set a cookie on
  /// one host and read it back from another — those break unless third-party
  /// cookies are explicitly enabled. Cookies themselves persist across dialog
  /// open/close cycles by default because Android's CookieManager is shared
  /// across all WebViews in the app.
  void _enableThirdPartyCookies(WebViewController controller) {
    if (!Platform.isAndroid) return;
    try {
      final cookieMgr = WebViewCookieManager().platform;
      final platform = controller.platform;
      if (cookieMgr is AndroidWebViewCookieManager
          && platform is AndroidWebViewController) {
        cookieMgr.setAcceptThirdPartyCookies(platform, true);
      }
    } catch (_) { /* best-effort — fall back to default cookie policy */ }
  }

  /// Tell Android's CookieManager to flush its in-memory cookie jar to disk.
  /// WebView flushes periodically on its own, but a force-kill before the
  /// next periodic flush loses recently-set cookies (logins). Called on app
  /// pause so persistence is guaranteed.
  Future<void> _flushCookies() async {
    if (!Platform.isAndroid) return;
    try {
      await _adBlockChannel.invokeMethod<void>('flushCookies');
    } catch (_) {}
  }

  /// If [_youtubeFrontend] is set and [url] points to YouTube, return the URL
  /// rewritten to the chosen Invidious/Piped instance. Returns null otherwise.
  String? _rewriteYouTubeUrl(String url) {
    final frontend = _youtubeFrontend;
    if (frontend == null || frontend.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') {
      // Short-link: /VIDEO_ID → /watch?v=VIDEO_ID, preserve any other params.
      if (uri.pathSegments.isEmpty) return null;
      final id = uri.pathSegments.first;
      final params = Map<String, String>.from(uri.queryParameters);
      params['v'] = id;
      return Uri(
        scheme: 'https', host: frontend, path: '/watch', queryParameters: params,
      ).toString();
    }
    final isYouTube = host == 'youtube.com'
        || host == 'www.youtube.com'
        || host == 'm.youtube.com';
    if (!isYouTube) return null;
    return uri.replace(scheme: 'https', host: frontend).toString();
  }

  /// Shows a persistent SnackBar when the native layer auto-detects a new ad host.
  /// The user can tap "Block" to confirm adding it, or "Dismiss" to ignore.
  void _showDetectedAdHostBanner(String host) {
    if (_detectedAdHosts.contains(host)) return; // already shown
    _detectedAdHosts.add(host);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 12),
        content: Text('New ad host detected: $host'),
        action: SnackBarAction(
          label: 'Block it',
          onPressed: () {
            addAdHost(host);
            messenger.showSnackBar(
              SnackBar(
                content: Text('$host added to blocklist'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Adds [host] to the runtime ad-host list and persists it.
  Future<bool> addAdHost(String host) async {
    if (!Platform.isAndroid) return false;
    try {
      final added = await _adBlockChannel.invokeMethod<bool>('addHost', {'host': host});
      return added ?? false;
    } catch (_) { return false; }
  }

  /// Removes [host] from the runtime ad-host list and persists the change.
  Future<bool> removeAdHost(String host) async {
    if (!Platform.isAndroid) return false;
    try {
      final removed = await _adBlockChannel.invokeMethod<bool>('removeHost', {'host': host});
      return removed ?? false;
    } catch (_) { return false; }
  }

  /// Returns only custom (user-added + auto-detected) ad hosts.
  Future<List<String>> getAdHosts() async {
    if (!Platform.isAndroid) return [];
    try {
      final list = await _adBlockChannel.invokeMethod<List>('getCustomHosts');
      return list?.cast<String>() ?? [];
    } catch (_) { return []; }
  }

  Future<void> setAdBlockEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    setState(() => _adBlockEnabled = enabled);
    try {
      await _adBlockChannel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  /// Inject the YouTube ad-blocker. Designed to be safe to call from
  /// onPageStarted (DOM may not exist yet) — DOM-dependent setup is deferred
  /// until DOMContentLoaded.
  ///
  /// The core trick is the same as Brave / uBlock Origin's `json-prune`
  /// scriptlet: YouTube's player decides when to splice ads into the stream
  /// by reading specific fields on the player config blob. If those fields
  /// are gone before the player reads them, no ads get inserted.
  ///   * `window.ytInitialPlayerResponse` — set inline on first page load.
  ///     We define a property setter that strips ad fields on assignment.
  ///   * `/youtubei/v1/player` API responses — fetched for every video
  ///     navigated to inside the SPA. We wrap fetch and prune the JSON.
  ///
  /// CSS hiding and the skip-button click observer are kept as defence in
  /// depth (in case YouTube renames the ad fields and pruning breaks).
  void _injectYouTubeAdBlocker([WebViewController? ctrl]) {
    const js = r'''
      (function() {
        if (!location.hostname.includes('youtube.com')) return;
        if (window._ytAdBlockerInjected) return;
        window._ytAdBlockerInjected = true;

        // ---- 1. JSON pruning (the actual ad killer) ----
        const AD_KEYS = ['playerAds', 'adPlacements', 'adSlots', 'adServingData'];
        function prune(obj) {
          if (!obj || typeof obj !== 'object') return;
          for (const k of AD_KEYS) {
            if (k in obj) try { delete obj[k]; } catch (_) {}
          }
        }

        // Best-effort: prune anything already assigned by an inline <script>
        // that ran before us (we sometimes lose the race since webview_flutter
        // can't inject at document-start).
        try { prune(window.ytInitialPlayerResponse); } catch (_) {}

        // Property setter for future assignments. The watch-page inline
        // script assigns this; SPA navigations re-assign it after fetching.
        try {
          let _ipr = window.ytInitialPlayerResponse;
          Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            set(v) { prune(v); _ipr = v; },
            get() { return _ipr; },
          });
        } catch (_) { /* property may already be non-configurable */ }

        // Wrap fetch so /youtubei/v1/player responses (issued for every SPA
        // video navigation) get the same treatment. This is the path that
        // catches every video after the first one on a session.
        const _origFetch = window.fetch;
        window.fetch = async function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          const response = await _origFetch.call(this, input, init);
          if (url.includes('/youtubei/v1/player')) {
            try {
              const text = await response.clone().text();
              const json = JSON.parse(text);
              prune(json);
              return new Response(JSON.stringify(json), {
                status: response.status,
                statusText: response.statusText,
                headers: response.headers,
              });
            } catch (_) { return response; }
          }
          return response;
        };

        // ---- 2. Defensive CSS + skip-button click observer ----
        // Runs after DOMContentLoaded so we don't fail when injected at
        // document-start (no document.head yet).
        function setupDom() {
          const style = document.createElement('style');
          style.textContent = `
            .ytp-ad-overlay-container,
            .ytp-ad-player-overlay,
            .ytp-ad-player-overlay-instream-info,
            .ytp-ad-image-overlay,
            .ytp-ad-text-overlay,
            .ytp-ad-module,
            .ytp-ad-action-interstitial,
            .ytp-ad-skip-button-slot,
            ytd-action-companion-ad-renderer,
            ytd-display-ad-renderer,
            ytd-video-masthead-ad-renderer,
            ytd-promoted-sparkles-web-renderer,
            ytd-banner-promo-renderer,
            ytd-ad-slot-renderer,
            yt-mealbar-promo-renderer,
            #masthead-ad,
            #player-ads { display: none !important; }
          `;
          (document.head || document.documentElement).appendChild(style);

          function clickSkip() {
            const btn = document.querySelector(
              '.ytp-skip-ad-button, .ytp-ad-skip-button, ' +
              '.ytp-ad-skip-button-slot button, .ytp-ad-overlay-close-button'
            );
            if (btn) btn.click();
          }

          function attach(player) {
            if (player._ytAdObserverAttached) return;
            player._ytAdObserverAttached = true;
            new MutationObserver((mutations) => {
              for (const m of mutations) {
                if (m.type !== 'childList') continue;
                for (const node of m.addedNodes) {
                  if (node.nodeType !== 1) continue;
                  if (node.matches && node.matches(
                    '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-slot'
                  )) { clickSkip(); return; }
                }
              }
            }).observe(player, { childList: true, subtree: true });
          }

          const existing = document.querySelector('.html5-video-player');
          if (existing) {
            attach(existing);
          } else {
            const bootstrap = new MutationObserver(() => {
              const p = document.querySelector('.html5-video-player');
              if (p) { bootstrap.disconnect(); attach(p); }
            });
            bootstrap.observe(document.documentElement, { childList: true, subtree: true });
          }
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupDom, { once: true });
        } else {
          setupDom();
        }
      })();
    ''';
    (ctrl ?? _controller).runJavaScript(js);
  }

  Future<void> _injectAdBlocker([WebViewController? ctrl]) async {
    const css = '''
      (function() {
        if (window._adBlockerInjected) return;
        window._adBlockerInjected = true;
        const style = document.createElement('style');
        style.textContent = `
          /* Common ad containers */
          ins.adsbygoogle,
          [id*="google_ads"],
          [id*="div-gpt-ad"],
          [class*="adsbygoogle"],
          [class*="ad-banner"],
          [class*="ad-container"],
          [class*="ad-wrapper"],
          [class*="ad-slot"],
          [class*="banner-ad"],
          [class*="sponsored"],
          [data-ad-slot],
          [data-ad-unit],
          iframe[src*="googlesyndication"],
          iframe[src*="doubleclick"],
          iframe[src*="adservice"],
          iframe[src*="amazon-adsystem"],
          iframe[src*="ads."],
          script[src*="pagead2.googlesyndication"],
          /* sticky/floating ad bars */
          [id*="sticky-ad"],
          [class*="sticky-ad"],
          [class*="float-ad"],
          [class*="overlay-ad"],
          [class*="interstitial"],
          /* generic heuristics */
          [class*="pub_300x250"],
          [class*="pub_728x90"],
          [id*="AdDiv"],
          [id*="ad_box"],
          [id*="ad_unit"] {
            display: none !important;
            visibility: hidden !important;
            height: 0 !important;
            min-height: 0 !important;
            overflow: hidden !important;
          }
        `;
        document.head.appendChild(style);

        // Block known ad scripts from running
        const adHosts = [
          'googlesyndication.com', 'doubleclick.net', 'googleadservices.com',
          'adnxs.com', 'advertising.com', 'amazon-adsystem.com',
          'ads.yahoo.com', 'taboola.com', 'outbrain.com', 'moatads.com',
          'adsafeprotected.com', 'scorecardresearch.com', 'pubads.g.doubleclick.net',
        ];
        // Redirect blocked URLs to a harmless data: URL instead of swallowing
        // open()/send(). Swallowing leaves the XHR in an invalid state and the
        // caller waiting forever for onload/onreadystatechange — which hangs the
        // whole WebView when scripts await ad-tracker XHRs synchronously.
        const _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          const target = (typeof url === 'string' && adHosts.some(h => url.includes(h)))
            ? 'data:text/plain,' : url;
          return _open.call(this, method, target, ...rest);
        };
        const _fetch = window.fetch;
        window.fetch = function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          if (adHosts.some(h => url.includes(h))) return Promise.resolve(new Response('', { status: 200 }));
          return _fetch.call(this, input, init);
        };
      })();
    ''';
    (ctrl ?? _controller).runJavaScript(css);
  }

  String _normalizeUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    // Looks like a URL if it has no spaces and contains a dot (e.g. google.com, sub.domain.com/path)
    final looksLikeUrl = !trimmed.contains(' ') && trimmed.contains('.');
    if (looksLikeUrl) {
      return 'https://$trimmed';
    }
    // Otherwise treat as a Google search query
    return 'https://www.google.com/search?q=${Uri.encodeComponent(trimmed)}';
  }

  Future<void> _addBookmark() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _bookmarks.contains(url)) return;
    setState(() => _bookmarks.insert(0, url));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bookmarks', _bookmarks);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Bookmarked'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _removeBookmark(String url) async {
    setState(() {
      _bookmarks.remove(url);
      _bookmarkNames.remove(url);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bookmarks', _bookmarks);
    await prefs.setString('bookmarkNames', jsonEncode(_bookmarkNames));
  }

  Future<void> _renameBookmark(String url, String name) async {
    setState(() {
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        _bookmarkNames.remove(url);
      } else {
        _bookmarkNames[url] = trimmed;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bookmarkNames', jsonEncode(_bookmarkNames));
  }

  Future<void> _showRenameBookmarkDialog(String url) async {
    final controller = TextEditingController(text: _bookmarkNames[url] ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename bookmark'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Name (leave empty to reset)',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await _renameBookmark(url, result);
  }

  void _showToolsDrawer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Text('Tools', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Spacer(),
                    IconButton(
                      icon: Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    SwitchListTile(
                      secondary: Icon(_isEinkMode ? Icons.invert_colors_off : Icons.invert_colors),
                      title: Text('E-ink mode'),
                      subtitle: Text('High-contrast reading'),
                      value: _isEinkMode,
                      onChanged: (val) {
                        setState(() => _isEinkMode = val);
                        _einkModeNotifier.value = val;
                        setModalState(() {});
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.format_size),
                      title: Text('Page font size'),
                      subtitle: Text('${(100 * (1.0 + _pageZoomLevel * 0.15)).round()}%'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.text_decrease),
                            tooltip: 'Decrease',
                            onPressed: () async {
                              await _changePageZoom(-1);
                              setModalState(() {});
                            },
                          ),
                          IconButton(
                            icon: Icon(Icons.text_increase),
                            tooltip: 'Increase',
                            onPressed: () async {
                              await _changePageZoom(1);
                              setModalState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.language),
                      title: Text('Language'),
                      trailing: DropdownButton<String>(
                        value: _selectedLanguage,
                        items: _languages
                            .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            _selectedLanguage = val!;
                            if (dialogController != null) {
                              dialogController?.loadRequest(
                                  Uri.parse(getUrlForLanguage(_selectedLanguage)));
                            }
                          });
                          setModalState(() {});
                        },
                        underline: SizedBox(),
                      ),
                    ),
                    ListTile(
                      leading: Icon(_githubToken != null ? Icons.key : Icons.key_off_outlined),
                      title: Text('GitHub token'),
                      subtitle: Text(_githubToken != null ? 'Token set' : 'Not configured'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showTokenDialog();
                      },
                    ),
                    ListTile(
                      leading: Icon(_isListening ? Icons.mic : Icons.mic_none,
                          color: _isListening ? Colors.red : null),
                      title: Text(_isListening ? 'Stop listening' : 'Voice input'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _toggleVoiceInput();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.code),
                      title: Text('Inject remote snippet'),
                      subtitle: Text('Run remote JavaScript on current page'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _injectRemoteSnippet();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.terminal),
                      title: Text('View snippet logs'),
                      subtitle: Text('${_snippetLogs.length} entries'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showSnippetLogs();
                      },
                    ),
                    if (_currentPdfUrl != null) ...[
                      ListTile(
                        leading: Icon(Icons.text_decrease),
                        title: Text('Zoom out'),
                        onTap: () => _changePdfZoom(-1),
                      ),
                      ListTile(
                        leading: Icon(Icons.text_increase),
                        title: Text('Zoom in'),
                        onTap: () => _changePdfZoom(1),
                      ),
                    ],
                    ListTile(
                      leading: Icon(Icons.security_outlined),
                      title: Text('Ad hosts'),
                      subtitle: Text('Manage blocked ad hosts'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showAdHosts();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.smart_display_outlined),
                      title: Text('YouTube playback'),
                      subtitle: Text(_youtubeFrontend == null
                          ? 'Native YouTube (with ad blocker)'
                          : 'Via ${_youtubeFrontend!}'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showYoutubeFrontendPicker();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showYoutubeFrontendPicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'YouTube playback',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Native uses youtube.com with our JSON-prune ad blocker. Front-ends serve YouTube content with no ads at all but may go offline; pick a fallback if your usual one stops working.',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ),
            RadioListTile<String?>(
              title: Text('Native YouTube'),
              subtitle: Text('Real youtube.com, our ad blocker strips ads'),
              value: null,
              groupValue: _youtubeFrontend,
              onChanged: (v) async {
                Navigator.of(ctx).pop();
                await _setYoutubeFrontend(v);
              },
            ),
            ..._youtubeFrontendInstances.map((host) => RadioListTile<String?>(
                  title: Text(host),
                  value: host,
                  groupValue: _youtubeFrontend,
                  onChanged: (v) async {
                    Navigator.of(ctx).pop();
                    await _setYoutubeFrontend(v);
                  },
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _setYoutubeFrontend(String? value) async {
    setState(() => _youtubeFrontend = value);
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove('youtubeFrontend');
    } else {
      await prefs.setString('youtubeFrontend', value);
    }
  }

  void _showAdHosts() {
    List<String> hosts = [];
    bool loading = true;
    bool initDone = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> loadHosts() async {
            final list = await getAdHosts();
            setModalState(() {
              hosts = list;
              loading = false;
            });
          }

          if (!initDone) {
            initDone = true;
            loadHosts();
          }

          return DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.security_outlined),
                      SizedBox(width: 8),
                      Text('Ad Hosts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Spacer(),
                      Switch(
                        value: _adBlockEnabled,
                        onChanged: (val) async {
                          await setAdBlockEnabled(val);
                          setModalState(() {});
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline),
                        tooltip: 'Add host',
                        onPressed: () {
                          final ctrl = TextEditingController();
                          showDialog(
                            context: ctx,
                            builder: (dlgCtx) => AlertDialog(
                              title: Text('Add ad host'),
                              content: TextField(
                                controller: ctrl,
                                autofocus: true,
                                decoration: InputDecoration(
                                  hintText: 'e.g. ads.example.com',
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (_) async {
                                  final h = ctrl.text.trim().toLowerCase();
                                  if (h.isEmpty) return;
                                  Navigator.of(dlgCtx).pop();
                                  await addAdHost(h);
                                  loadHosts();
                                },
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(dlgCtx).pop(),
                                  child: Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final h = ctrl.text.trim().toLowerCase();
                                    if (h.isEmpty) return;
                                    Navigator.of(dlgCtx).pop();
                                    await addAdHost(h);
                                    loadHosts();
                                  },
                                  child: Text('Add'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: loading
                      ? Center(child: CircularProgressIndicator())
                      : hosts.isEmpty
                          ? Center(child: Text('No ad hosts configured'))
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: hosts.length,
                              itemBuilder: (_, i) {
                                final host = hosts[i];
                                return ListTile(
                                  leading: Icon(Icons.block, size: 20),
                                  title: Text(host,
                                      style: TextStyle(fontFamily: 'monospace', fontSize: 13)),
                                  trailing: IconButton(
                                    icon: Icon(Icons.delete_outline),
                                    tooltip: 'Remove',
                                    onPressed: () async {
                                      await removeAdHost(host);
                                      loadHosts();
                                    },
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showBookmarks() {    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Text('Bookmarks', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Spacer(),
                    IconButton(
                      icon: Icon(Icons.bookmark_add_outlined),
                      tooltip: 'Add current page',
                      onPressed: () async {
                        final url = _urlController.text.trim();
                        if (url.isEmpty || _bookmarks.contains(url)) return;
                        setState(() => _bookmarks.insert(0, url));
                        setModalState(() {});
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setStringList('bookmarks', _bookmarks);
                      },
                    ),
                    if (_bookmarks.isNotEmpty)
                      TextButton(
                        child: Text('Clear all'),
                        onPressed: () async {
                          setState(() {
                            _bookmarks.clear();
                            _bookmarkNames.clear();
                          });
                          setModalState(() {});
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setStringList('bookmarks', []);
                          await prefs.setString('bookmarkNames', jsonEncode({}));
                        },
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _bookmarks.isEmpty
                    ? Center(child: Text('No bookmarks yet'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _bookmarks.length,
                        itemBuilder: (_, i) {
                          final url = _bookmarks[i];
                          final name = _bookmarkNames[url];
                          return ListTile(
                            leading: Icon(Icons.bookmark),
                            title: Text(name ?? url, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: name != null
                                ? Text(url, maxLines: 1, overflow: TextOverflow.ellipsis)
                                : null,
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _urlController.text = url;
                              _loadUrl();
                            },
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.edit_outlined),
                                  tooltip: 'Rename',
                                  onPressed: () async {
                                    await _showRenameBookmarkDialog(url);
                                    setModalState(() {});
                                  },
                                ),
                                IconButton(
                                  icon: Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    await _removeBookmark(url);
                                    setModalState(() {});
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _loadUrl() async {
    final url = _normalizeUrl(_urlController.text);
    final uri = Uri.tryParse(url);
    if (uri != null && uri.isAbsolute) {
      _urlController.text = url;
      _controller.loadRequest(uri);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastUrl', url);
    }
  }

  /// Strip language-specific suffixes to get a stem for wiktionary search.
  String _stemWord(String word, String lang) {
    word = word.toLowerCase().trim();
    List<String> suffixes;
    switch (lang) {
      case 'sv':
        // Swedish: remove common inflectional suffixes (longest first)
        suffixes = ['ighet', 'ande', 'arna', 'erna', 'ning', 'het', 'ade', 'ade', 'ing',
                     'are', 'ast', 'ade', 'ar', 'or', 'er', 'en', 'et', 'na', 'de', 'te',
                     'ad', 'at', 's', 't', 'a', 'e'];
        break;
      case 'es':
        // Spanish
        suffixes = ['iones', 'ción', 'ando', 'endo', 'ados', 'idas', 'ado', 'ido',
                     'aba', 'ían', 'mente', 'es', 'os', 'as', 'an', 'en', 'ó', 's'];
        break;
      default:
        suffixes = ['ing', 'tion', 'ed', 'ly', 'er', 'est', 's'];
    }
    for (final s in suffixes) {
      if (word.endsWith(s) && word.length - s.length >= 2) {
        return word.substring(0, word.length - s.length);
      }
    }
    return word;
  }

  void _openDialog2WithWebview(String url) {
    // Pre-rewrite YouTube URLs to the chosen front-end. Cheap to call when no
    // front-end is configured (returns null).
    url = _rewriteYouTubeUrl(url) ?? url;
    // Create unique dialog ID based on URL and timestamp
    final dialogId = '${Uri.parse(url).host}_${DateTime.now().millisecondsSinceEpoch}';

    final errorNotifier = ValueNotifier<String?>(null);
    bool hasRedirected = false;
    final String dialogIdForBridge = dialogId;
    late final WebViewController dialog2Controller;
    dialog2Controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_userAgent)
      ..addJavaScriptChannel('FilmotBridge', onMessageReceived: (msg) => _handleFilmotMessage(dialogIdForBridge, msg.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (!request.isMainFrame) return NavigationDecision.navigate;
          final rewritten = _rewriteYouTubeUrl(request.url);
          if (rewritten != null) {
            dialog2Controller.loadRequest(Uri.parse(rewritten));
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (_) {
          errorNotifier.value = null;
          _injectYouTubeAdBlocker(dialog2Controller);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) {
            errorNotifier.value = '[${error.errorCode}] ${error.description}\n${error.url ?? ''}';
          }
        },
        onPageFinished: (finishedUrl) {
          _injectAdBlocker(dialog2Controller);
          if (_isFilmotUrl(finishedUrl)) {
            _injectFilmotHelper(dialog2Controller);
          }
          // Detect wiktionary 404: /wiki/{word} page that doesn't exist
          final uri = Uri.tryParse(finishedUrl);
          if (!hasRedirected && uri != null
              && uri.host.endsWith('.wiktionary.org')
              && uri.path.startsWith('/wiki/')) {
            // Check if the page has the "no article" indicator
            dialog2Controller.runJavaScriptReturningResult(
              'document.querySelector(".noarticletext") !== null'
            ).then((result) {
              if (result.toString() == 'true') {
                hasRedirected = true;
                final word = Uri.decodeComponent(uri.path.substring('/wiki/'.length));
                final subdomain = uri.host.split('.').first;
                final stem = _stemWord(word, _selectedLanguage);
                final searchUrl = 'https://$subdomain.wiktionary.org/w/index.php?search=${Uri.encodeComponent(stem)}';
                dialog2Controller.loadRequest(Uri.parse(searchUrl));
              }
            }).catchError((_) {});
          }
        },
      ))
      ..loadRequest(Uri.parse(url));
    _enableThirdPartyCookies(dialog2Controller);

    // Store the new dialog instance
    _dialog2Controllers[dialogId] = dialog2Controller;
    _dialog2ErrorNotifiers[dialogId] = errorNotifier;
    _dialog2Urls[dialogId] = url;
    _minimizedDialog2s.remove(dialogId); // Ensure it's not marked as minimized

    _showDialog2(dialogId);
  }

  void _showDialog2(String dialogId) {
    final controller = _dialog2Controllers[dialogId];
    final errorNotifier = _dialog2ErrorNotifiers[dialogId];
    final url = _dialog2Urls[dialogId];
    if (controller == null || errorNotifier == null || url == null) return;

    _minimizedDialog2s.remove(dialogId); // Mark as not minimized
    _bumpMinimizedVersion();
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // If dialog has been minimized before, tapping outside should minimize, not close
    final hasBeenMinimized = _everMinimizedDialog2s.contains(dialogId);

    showDialog(
      context: context,
      barrierDismissible: !hasBeenMinimized, // Prevent outside tap closing if ever minimized
      builder: (ctx) => hasBeenMinimized
        ? GestureDetector(
            // Custom barrier tap handler - minimizes instead of closing
            onTap: () {
              _minimizedDialog2s.add(dialogId);
              Navigator.of(ctx).pop();
              _bumpMinimizedVersion();
            },
            child: Container(
              color: Colors.transparent,
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // Prevent tap propagation from dialog content
                  child: Dialog(
                    insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
                    child: _buildDialog2Content(ctx, dialogId, url, controller, errorNotifier, screenWidth, screenHeight),
                  ),
                ),
              ),
            ),
          )
        : Dialog(
            insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
            child: _buildDialog2Content(ctx, dialogId, url, controller, errorNotifier, screenWidth, screenHeight),
          ),
    ).then((_) {
      // Dialog closed - but keep controller alive to avoid reloading.
      // Only dispose error notifier if dialog was fully closed (not minimized).
      if (!_minimizedDialog2s.contains(dialogId)) {
        // Stop any media playback and tear down the dialog WebView's JS world.
        // Without this the YouTube player keeps running (audio + the ad-blocker's
        // MutationObserver/setInterval) after the widget is removed, which holds
        // the renderer process busy and freezes the main WebView. Navigating to
        // about:blank discards the document and stops everything in one shot.
        _shutdownDialogWebView(controller);
        errorNotifier.dispose();
        _dialog2Controllers.remove(dialogId);
        _dialog2ErrorNotifiers.remove(dialogId);
        _dialog2Urls.remove(dialogId);
        _everMinimizedDialog2s.remove(dialogId); // Clean up tracking state
        _filmotChannelsSeen.remove(dialogId);
        _chipPositions.remove(dialogId);
      }
      _bumpMinimizedVersion();
    });
  }

  /// Stops any audio/video and unloads the document on a dialog WebView so it
  /// cannot keep working in the background after the dialog is dismissed.
  /// Safe to call even if the platform view has already been detached.
  void _shutdownDialogWebView(WebViewController controller) {
    try {
      controller.runJavaScript(
        r'try{document.querySelectorAll("video,audio").forEach(function(v){try{v.pause();v.removeAttribute("src");v.load();}catch(e){}});}catch(e){}'
      );
    } catch (_) {}
    try {
      controller.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

  Widget _buildDialog2Content(BuildContext ctx, String dialogId, String url,
      WebViewController controller, ValueNotifier<String?> errorNotifier,
      double screenWidth, double screenHeight) {
    return Container(
      width: screenWidth * 0.98,
      height: screenHeight,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: () async {
                    if (await controller.canGoBack()) {
                      await controller.goBack();
                    } else if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No previous page'), duration: Duration(seconds: 1)),
                      );
                    }
                  },
                ),
                // Show dialog title with host name
                Expanded(
                  child: Text(
                    Uri.tryParse(url)?.host ?? 'Dialog',
                    style: TextStyle(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isFilmotUrl(url)) ...[
                  IconButton(
                    tooltip: 'Channel blacklist (tap to edit / temporarily disable)',
                    icon: Icon(Icons.block, size: 20),
                    onPressed: () => _showFilmotChannelsDialog(ctx, dialogId, controller),
                  ),
                  IconButton(
                    tooltip: 'Saved videos',
                    icon: Icon(Icons.bookmark_outline, size: 20),
                    onPressed: () => _showSavedVideosDialog(ctx),
                  ),
                  IconButton(
                    tooltip: 'Save current video URL',
                    icon: Icon(Icons.save_alt, size: 20),
                    onPressed: () => _saveCurrentFilmotVideo(controller),
                  ),
                ],
                TextButton(
                  onPressed: () {
                    _minimizedDialog2s.add(dialogId);
                    _everMinimizedDialog2s.add(dialogId); // Mark as ever minimized
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                  child: Text('Minimize'),
                ),
                TextButton(
                  onPressed: () {
                    // Clear minimized state when manually closing
                    _minimizedDialog2s.remove(dialogId);
                    // Stop media + JS *before* popping while the platform view
                    // is still attached — `.then` cleanup may run after detach.
                    _shutdownDialogWebView(controller);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                  child: Text('Close'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<String?>(
              valueListenable: errorNotifier,
              builder: (_, error, __) => error != null
                  ? _errorView(error, () {
                      errorNotifier.value = null;
                      controller.loadRequest(Uri.parse(url));
                    })
                  : ValueListenableBuilder<bool>(
                      valueListenable: _einkModeNotifier,
                      builder: (_, eink, child) => ColorFiltered(
                        colorFilter: eink ? _einkColorFilter : _identityColorFilter,
                        child: child,
                      ),
                      child: WebViewWidget(controller: controller),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Floating minimized-dialog chips ----------

  /// Inserts the overlay entry on first use; safe to call repeatedly.
  void _ensureFloatingChipsOverlay() {
    if (_floatingChipsEntry != null) return;
    _floatingChipsEntry = OverlayEntry(builder: (_) {
      return ValueListenableBuilder<int>(
        valueListenable: _minimizedVersion,
        builder: (ctx, _, __) {
          final size = MediaQuery.of(ctx).size;
          final chips = <Widget>[];
          var slot = 0;
          if (_dialog1Minimized) {
            chips.add(_buildChip(
              key: '__dialog1__',
              defaultPos: _defaultChipPos(size, slot),
              screenSize: size,
              icon: const Icon(Icons.translate, size: 18, color: Colors.white),
              label: 'Lookup',
              onTap: _showDialog1,
              onClose: () {
                setState(() {
                  _dialog1Minimized = false;
                  _dialog1EverMinimized = false;
                });
                _bumpMinimizedVersion();
              },
            ));
            slot++;
          }
          for (final dialogId in _minimizedDialog2s.toList()) {
            final url = _dialog2Urls[dialogId] ?? '';
            final host = Uri.tryParse(url)?.host ?? 'Dialog';
            final label = host.length > 14 ? host.substring(0, 14) : host;
            chips.add(_buildChip(
              key: dialogId,
              defaultPos: _defaultChipPos(size, slot),
              screenSize: size,
              icon: const Icon(Icons.menu_book, size: 18, color: Colors.white),
              label: label,
              onTap: () => _showDialog2(dialogId),
              onClose: () => _closeMinimizedDialog2(dialogId),
            ));
            slot++;
          }
          return Stack(children: chips);
        },
      );
    });
    final overlay = Overlay.of(context, rootOverlay: true);
    overlay.insert(_floatingChipsEntry!);
  }

  Offset _defaultChipPos(Size size, int slot) {
    return Offset(size.width - 140, size.height - 80 - slot * 56.0);
  }

  Widget _buildChip({
    required String key,
    required Offset defaultPos,
    required Size screenSize,
    required Widget icon,
    required String label,
    required VoidCallback onTap,
    required VoidCallback onClose,
  }) {
    return _FloatingDraggableChip(
      key: ValueKey(key),
      startPosition: _chipPositions[key] ?? defaultPos,
      screenSize: screenSize,
      icon: icon,
      label: label,
      onTap: onTap,
      onClose: onClose,
      onPositionChanged: (p) { _chipPositions[key] = p; },
    );
  }

  void _bumpMinimizedVersion() {
    _ensureFloatingChipsOverlay();
    _minimizedVersion.value++;
  }

  void _closeMinimizedDialog2(String dialogId) {
    final controller = _dialog2Controllers[dialogId];
    if (controller != null) _shutdownDialogWebView(controller);
    _dialog2ErrorNotifiers[dialogId]?.dispose();
    _dialog2Controllers.remove(dialogId);
    _dialog2ErrorNotifiers.remove(dialogId);
    _dialog2Urls.remove(dialogId);
    _minimizedDialog2s.remove(dialogId);
    _everMinimizedDialog2s.remove(dialogId);
    _filmotChannelsSeen.remove(dialogId);
    if (mounted) setState(() {});
    _bumpMinimizedVersion();
  }

  // ---------- Filmot helpers ----------

  bool _isFilmotUrl(String? url) {
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    return host.endsWith('filmot.com');
  }

  Future<void> _saveFilmotBlacklist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('filmotChannelBlacklist', _filmotChannelBlacklist.toList());
  }

  Future<void> _saveSavedVideos() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('savedVideos', jsonEncode(_savedVideos));
  }

  /// Pushes the current blacklist + disabled state + known channel map into
  /// the dialog WebView and re-runs the annotator. Safe to call before the
  /// page has finished loading.
  void _pushFilmotConfig(WebViewController controller) {
    final list = jsonEncode(_filmotChannelBlacklist.toList());
    final disabled = _filmotBlacklistDisabled ? 'true' : 'false';
    final map = jsonEncode(_videoChannelCache);
    controller.runJavaScript(
      'window.__cupitorFilmotBlacklist = $list;'
      'window.__cupitorFilmotBlacklistDisabled = $disabled;'
      'window.__cupitorVideoChannel = Object.assign(window.__cupitorVideoChannel||{}, $map);'
      'if (window.__cupitorFilmotApply) window.__cupitorFilmotApply();'
    );
  }

  Future<void> _saveVideoChannelCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('videoChannelCache', jsonEncode(_videoChannelCache));
  }

  /// Resolves channel names for the given YouTube video IDs by calling the
  /// public oEmbed endpoint (no auth, returns `author_name`). Caches results
  /// in memory + SharedPreferences and pushes the resolved map back into all
  /// open filmot dialogs so their annotators can hide blacklisted rows.
  Future<void> _resolveVideoChannels(List<String> ids) async {
    final pending = ids
        .toSet()
        .where((id) => id.isNotEmpty
            && !_videoChannelCache.containsKey(id)
            && !_videoChannelInflight.contains(id))
        .toList();
    if (pending.isEmpty) return;
    _videoChannelInflight.addAll(pending);
    bool anyResolved = false;
    // Run up to 6 lookups in parallel; chunk through the list.
    const concurrency = 6;
    for (var i = 0; i < pending.length; i += concurrency) {
      final batch = pending.skip(i).take(concurrency).toList();
      await Future.wait(batch.map((id) async {
        try {
          final r = await http
              .get(Uri.parse('https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$id&format=json'))
              .timeout(const Duration(seconds: 8));
          if (r.statusCode == 200) {
            final j = jsonDecode(r.body) as Map<String, dynamic>;
            final author = (j['author_name'] ?? '').toString().trim();
            if (author.isNotEmpty) {
              _videoChannelCache[id] = author;
              anyResolved = true;
            } else {
              _videoChannelCache[id] = ''; // negative cache to avoid retries
            }
          } else if (r.statusCode == 401 || r.statusCode == 404) {
            _videoChannelCache[id] = '';
          }
        } catch (_) { /* leave uncached so we retry later */ }
        _videoChannelInflight.remove(id);
      }));
      // Push partial results so the UI updates progressively.
      if (anyResolved) {
        for (final entry in _dialog2Controllers.entries) {
          if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
        }
      }
    }
    if (anyResolved) await _saveVideoChannelCache();
  }

  /// Injects the Filmot annotator into the dialog WebView. Idempotent — the
  /// script self-guards against re-installation. Handles both layouts:
  /// (a) search results — `<div id="vcard_{ytId}">` blocks with NO channel info
  ///     in the HTML, resolved via Flutter-side oEmbed lookups;
  /// (b) sidebyside detail — a single `a[href*="/channel/"]` whose text is
  ///     the icon, so we read the channel name from the resolved map keyed by
  ///     the video id in the URL.
  void _injectFilmotHelper(WebViewController controller) {
    final list = jsonEncode(_filmotChannelBlacklist.toList());
    final disabled = _filmotBlacklistDisabled ? 'true' : 'false';
    final map = jsonEncode(_videoChannelCache);
    controller.runJavaScript('''
      window.__cupitorFilmotBlacklist = $list;
      window.__cupitorFilmotBlacklistDisabled = $disabled;
      window.__cupitorVideoChannel = Object.assign(window.__cupitorVideoChannel||{}, $map);
      (function(){
        if (window.__cupitorFilmotInstalled) { if (window.__cupitorFilmotApply) window.__cupitorFilmotApply(); return; }
        window.__cupitorFilmotInstalled = true;
        function bridge(msg) { try { FilmotBridge.postMessage(JSON.stringify(msg)); } catch(e) {} }
        function titleFromCard(card) {
          var a = card.querySelector('a[id^="vlink"]');
          if (a) return (a.textContent || '').trim().slice(0, 200);
          var t = card.querySelector('h1,h2,h3,h4,h5,.title,[class*=title]');
          if (t) return (t.textContent || '').trim().slice(0, 200);
          return '';
        }
        // Set a value only if it differs from current, to skip layout thrashing
        // when annotate runs repeatedly with the same data.
        function setStyle(el, prop, val) { if (el.style[prop] !== val) el.style[prop] = val; }
        function setText(el, val) { if (el.textContent !== val) el.textContent = val; }

        // Auto-skip the currently-playing video if its channel is blacklisted.
        // Filmot's prev/next buttons swap the iframe src in place — so the
        // only reliable hook is to watch the iframe and invoke filmot's own
        // navigateToLocalResult/nextVideo. Throttled to keep the skip from
        // racing when several blocked channels are queued in a row.
        var lastAutoSkipAt = 0;
        var lastCheckedSrc = '';
        function blacklistedChannelOf(videoId) {
          if (!videoId) return null;
          var disabled = window.__cupitorFilmotBlacklistDisabled === true;
          if (disabled) return null;
          var bl = window.__cupitorFilmotBlacklist || [];
          if (!bl.length) return null;
          var ch = (window.__cupitorVideoChannel || {})[videoId];
          if (!ch) return null;
          for (var i = 0; i < bl.length; i++) if (bl[i] === ch) return ch;
          return null;
        }
        function currentVideoId() {
          var ifr = document.getElementById('player');
          if (ifr && ifr.src) {
            var m = ifr.src.match(/youtube\\.com\\/embed\\/([A-Za-z0-9_-]{6,})/);
            if (m) return m[1];
          }
          // Fallback to filmot's own global if it's defined.
          if (typeof window.currentVideoID === 'string' && window.currentVideoID) return window.currentVideoID;
          return null;
        }
        // Find the index of the currently-playing video in filmot's local
        // vcard list (`<div class="vcardN ...">`). Needed by playNextVideo().
        function currentVcardIndex() {
          var id = currentVideoId();
          if (!id) return -1;
          var card = document.getElementById('vcard_' + id);
          if (!card) return -1;
          var m = (card.className || '').match(/(?:^|\\s)vcard(\\d+)(?:\\s|\$)/);
          return m ? parseInt(m[1], 10) : -1;
        }
        function autoSkipIfBlacklisted(reason) {
          var id = currentVideoId();
          if (!id) return;
          var ch = (window.__cupitorVideoChannel || {})[id];
          if (ch === undefined) {
            // Not resolved yet — ask Flutter to resolve so a later push can re-check.
            bridge({action:'resolveVideos', ids:[id]});
            return;
          }
          var blocked = blacklistedChannelOf(id);
          if (!blocked) return;
          var now = Date.now();
          if (now - lastAutoSkipAt < 800) return;
          lastAutoSkipAt = now;
          try { if (typeof window.stopDownTimer === 'function') window.stopDownTimer(); } catch(e){}
          // Preferred path: filmot's own next button carries the correct
          // current index in its onclick, and uses playNextVideo() which
          // already skips past `.d-none` cards.
          try {
            var btn = document.getElementById('nextVideoButton');
            if (btn && !btn.classList.contains('d-none')) { btn.click(); return; }
          } catch(e){}
          // Fallback: derive the current index from the highlighted vcard
          // and invoke playNextVideo directly.
          try {
            var idx = currentVcardIndex();
            if (idx >= 0 && typeof window.playNextVideo === 'function') { window.playNextVideo(idx, 1); return; }
          } catch(e){}
          // Last-ditch fallbacks.
          try {
            if (typeof window.nextVideo === 'function') { window.nextVideo(); return; }
            if (typeof window.navigateToLocalResult === 'function') window.navigateToLocalResult(1);
          } catch(e){}
        }

        function annotate() {
          var bl = window.__cupitorFilmotBlacklist || [];
          var disabled = window.__cupitorFilmotBlacklistDisabled === true;
          var map = window.__cupitorVideoChannel || {};
          var blSet = {};
          for (var i = 0; i < bl.length; i++) blSet[bl[i]] = true;

          // --- (a) Search-result cards ---
          var cards = document.querySelectorAll('[id^="vcard_"]');
          var seenChannels = {};
          var unknownIds = [];
          for (var c = 0; c < cards.length; c++) {
            var card = cards[c];
            var id = card.id.replace(/^vcard_/, '');
            if (!id) continue;
            var ch = map[id];
            if (ch === undefined) {
              unknownIds.push(id);
              setStyle(card, 'opacity', '0.6');
            } else {
              setStyle(card, 'opacity', '');
              if (ch) seenChannels[ch] = true;
              // Use Bootstrap's `d-none` instead of inline style so filmot's
              // own playNextVideo()/playNextVideo prev path treats blacklisted
              // cards as "skipped" — they call `card.classList.contains("d-none")`.
              if (!disabled && ch && blSet[ch]) {
                if (!card.classList.contains('d-none')) card.classList.add('d-none');
              } else {
                if (card.classList.contains('d-none')) card.classList.remove('d-none');
              }
            }
            // Annotate once; label refreshed only when its text actually changes.
            if (card.getAttribute('data-cup-ann') !== '1') {
              card.setAttribute('data-cup-ann', '1');
              var bar = document.createElement('div');
              bar.className = '__cup_bar';
              bar.style.cssText = 'display:flex;gap:4px;padding:2px 0;font-size:11px';
              var label = document.createElement('span');
              label.className = '__cup_channel_label';
              label.style.cssText = 'flex:1;color:#555;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
              bar.appendChild(label);
              var bbtn = document.createElement('button');
              bbtn.textContent = '🚫';
              bbtn.title = 'Blacklist this channel';
              bbtn.style.cssText = 'padding:1px 6px;font-size:11px;border:1px solid #888;background:#fee;cursor:pointer;border-radius:3px;line-height:1';
              bbtn.onclick = (function(videoId, lbl){ return function(e){
                e.preventDefault(); e.stopPropagation();
                var channel = (window.__cupitorVideoChannel || {})[videoId];
                if (!channel) { setText(lbl, '(no channel resolved yet)'); return; }
                bridge({action:'blockChannel', channel: channel});
              }; })(id, label);
              bar.appendChild(bbtn);
              var sbtn = document.createElement('button');
              sbtn.textContent = '💾';
              sbtn.title = 'Save video URL';
              sbtn.style.cssText = 'padding:1px 6px;font-size:11px;border:1px solid #888;background:#efe;cursor:pointer;border-radius:3px;line-height:1';
              sbtn.onclick = (function(videoId, btn, cardEl){ return function(e){
                e.preventDefault(); e.stopPropagation();
                var channel = (window.__cupitorVideoChannel || {})[videoId] || '';
                bridge({action:'saveVideo', url:'https://www.youtube.com/watch?v=' + videoId, channel: channel, title: titleFromCard(cardEl)});
                btn.textContent = '✅';
              }; })(id, sbtn, card);
              bar.appendChild(sbtn);
              card.insertBefore(bar, card.firstChild);
            }
            var existingLabel = card.querySelector('.__cup_channel_label');
            if (existingLabel) {
              var lblText = (ch === undefined) ? '(resolving channel…)' : (ch === '' ? '(channel unknown)' : ch);
              setText(existingLabel, lblText);
            }
          }

          // --- (b) Detail-page channel link (no anchor text — read from URL) ---
          var detailLinks = document.querySelectorAll('a[href*="/channel/"], a[href*="youtube.com/@"]');
          var detailId = null;
          var pm = location.pathname.match(/\\/sidebyside\\/([A-Za-z0-9_-]{6,})/);
          if (pm) detailId = pm[1];
          for (var d = 0; d < detailLinks.length; d++) {
            var dl = detailLinks[d];
            if (dl.getAttribute('data-cup-ann') === '1') continue;
            dl.setAttribute('data-cup-ann', '1');
            var lbl2 = document.createElement('span');
            lbl2.className = '__cup_channel_label';
            lbl2.style.cssText = 'margin:0 6px;font-size:12px;color:#444';
            var ch2 = (detailId && map[detailId]) ? map[detailId] : '';
            lbl2.textContent = ch2 || '(resolving channel…)';
            if (ch2) seenChannels[ch2] = true;
            dl.parentNode.insertBefore(lbl2, dl);
            var b2 = document.createElement('button');
            b2.textContent = '🚫';
            b2.title = 'Blacklist this channel';
            b2.style.cssText = 'margin:0 4px;padding:1px 6px;font-size:11px;border:1px solid #888;background:#fee;cursor:pointer;border-radius:3px;line-height:1';
            b2.onclick = (function(vId, lbl){ return function(e){
              e.preventDefault(); e.stopPropagation();
              var ch = vId ? (window.__cupitorVideoChannel || {})[vId] : '';
              if (!ch) { setText(lbl, '(no channel resolved yet)'); return; }
              bridge({action:'blockChannel', channel: ch});
            }; })(detailId, lbl2);
            dl.parentNode.insertBefore(b2, dl.nextSibling);
            if (detailId) {
              unknownIds.push(detailId);
              var s2 = document.createElement('button');
              s2.textContent = '💾';
              s2.title = 'Save video URL';
              s2.style.cssText = 'margin:0 4px;padding:1px 6px;font-size:11px;border:1px solid #888;background:#efe;cursor:pointer;border-radius:3px;line-height:1';
              s2.onclick = (function(vId, btn){ return function(e){
                e.preventDefault(); e.stopPropagation();
                var ch = (window.__cupitorVideoChannel || {})[vId] || '';
                var ttl = document.title || '';
                bridge({action:'saveVideo', url:'https://www.youtube.com/watch?v=' + vId, channel: ch, title: ttl});
                btn.textContent = '✅';
              }; })(detailId, s2);
              dl.parentNode.insertBefore(s2, b2.nextSibling);
            }
          }

          // Keep already-annotated detail-page labels in sync with the map.
          var dLabels = document.querySelectorAll('a[data-cup-ann="1"]');
          for (var dl2 = 0; dl2 < dLabels.length; dl2++) {
            var prev = dLabels[dl2].previousSibling;
            if (prev && prev.classList && prev.classList.contains('__cup_channel_label')) {
              var dch = (detailId && map[detailId]) ? map[detailId] : '';
              var dtxt = dch || ((detailId && map[detailId] === '') ? '(channel unknown)' : '(resolving channel…)');
              setText(prev, dtxt);
              if (dch) seenChannels[dch] = true;
            }
          }

          // Report known channels to Flutter so the dialog UI can list them.
          var seenArr = []; for (var k in seenChannels) seenArr.push(k);
          bridge({action:'channelsSeen', channels: seenArr});
          if (unknownIds.length) {
            var dedup = {}; var uniq = [];
            for (var u = 0; u < unknownIds.length; u++) { if (!dedup[unknownIds[u]]) { dedup[unknownIds[u]] = 1; uniq.push(unknownIds[u]); } }
            bridge({action:'resolveVideos', ids: uniq});
          }
          // If the currently-playing video became blacklisted (new entry, or
          // its channel just resolved), skip to the next one.
          autoSkipIfBlacklisted('annotate');
        }

        // Debounced scheduler — protects the main thread from filmot's
        // own constant DOM updates (subtitle highlights, time ticks, etc.).
        var annotateTimer = null;
        function scheduleAnnotate() {
          if (annotateTimer) return;
          annotateTimer = setTimeout(function(){
            annotateTimer = null;
            try { annotate(); } catch(e) {}
          }, 400);
        }
        window.__cupitorFilmotApply = scheduleAnnotate;

        // Only run annotate when DOM mutations actually involve a vcard or a
        // channel link — ignore subtitle, badge, and player tick updates.
        function relevant(mutations) {
          for (var mi = 0; mi < mutations.length; mi++) {
            var mu = mutations[mi];
            if (mu.type !== 'childList') continue;
            for (var ai = 0; ai < mu.addedNodes.length; ai++) {
              var an = mu.addedNodes[ai];
              if (!an || an.nodeType !== 1) continue;
              if (an.id && an.id.indexOf('vcard_') === 0) return true;
              // Skip the bars we insert ourselves
              if (an.className === '__cup_bar' || an.className === '__cup_channel_label') continue;
              if (an.querySelector && (an.querySelector('[id^="vcard_"]') || an.querySelector('a[href*="/channel/"]') || an.querySelector('a[href*="youtube.com/@"]'))) return true;
            }
            for (var ri = 0; ri < mu.removedNodes.length; ri++) {
              var rn = mu.removedNodes[ri];
              if (!rn || rn.nodeType !== 1) continue;
              if (rn.id && rn.id.indexOf('vcard_') === 0) return true;
            }
          }
          return false;
        }

        annotate();
        var mo = new MutationObserver(function(mutations){
          try { if (relevant(mutations)) scheduleAnnotate(); } catch(e) {}
        });
        mo.observe(document.body || document.documentElement, {childList:true, subtree:true});

        // Watch the player iframe — filmot's Next/Prev buttons swap its src
        // without navigating, so this is the only reliable signal that the
        // currently-playing video has changed.
        function attachIframeWatcher() {
          var ifr = document.getElementById('player');
          if (!ifr || ifr.__cupWatched) return;
          ifr.__cupWatched = true;
          var srcMo = new MutationObserver(function(){
            if (ifr.src === lastCheckedSrc) return;
            lastCheckedSrc = ifr.src;
            autoSkipIfBlacklisted('iframe-src');
          });
          srcMo.observe(ifr, {attributes:true, attributeFilter:['src']});
          lastCheckedSrc = ifr.src || '';
          // Also fire once now in case the initial video is already blocked.
          autoSkipIfBlacklisted('initial');
        }
        attachIframeWatcher();
        // The iframe may not exist yet when we install — keep trying briefly.
        var watcherTries = 0;
        var watcherTimer = setInterval(function(){
          watcherTries++;
          attachIframeWatcher();
          var ifr2 = document.getElementById('player');
          if ((ifr2 && ifr2.__cupWatched) || watcherTries > 20) clearInterval(watcherTimer);
        }, 300);
      })();
    ''');
  }

  void _handleFilmotMessage(String dialogId, String message) {
    Map<String, dynamic> msg;
    try { msg = jsonDecode(message) as Map<String, dynamic>; } catch (_) { return; }
    final action = msg['action']?.toString();
    if (action == 'channelsSeen') {
      final list = (msg['channels'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
      _filmotChannelsSeen[dialogId] = list;
    } else if (action == 'resolveVideos') {
      final ids = (msg['ids'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
      if (ids.isNotEmpty) {
        // Fire-and-forget; _resolveVideoChannels pushes results back via JS.
        _resolveVideoChannels(ids);
      }
    } else if (action == 'blockChannel') {
      final channel = msg['channel']?.toString() ?? '';
      if (channel.isEmpty) return;
      _filmotChannelBlacklist.add(channel);
      _saveFilmotBlacklist();
      // Push updated config back to every active filmot dialog so all open
      // dialogs immediately hide rows from this channel.
      for (final entry in _dialog2Controllers.entries) {
        if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Blacklisted: $channel'), duration: const Duration(seconds: 2)),
        );
      }
    } else if (action == 'saveVideo') {
      final url = msg['url']?.toString() ?? '';
      if (url.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not detect a video URL on this page'), duration: Duration(seconds: 2)),
          );
        }
        return;
      }
      final title = msg['title']?.toString() ?? '';
      if (_savedVideos.any((e) => e['url'] == url)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Already saved: ${title.isNotEmpty ? title : url}'), duration: const Duration(seconds: 2)),
          );
        }
        return;
      }
      _savedVideos.add({
        'url': url,
        'channel': msg['channel']?.toString() ?? '',
        'title': title,
        'savedAt': DateTime.now().toIso8601String(),
      });
      _saveSavedVideos();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved: ${title.isNotEmpty ? title : url} (${_savedVideos.length} total)'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  void _showFilmotChannelsDialog(BuildContext ctx, String dialogId, WebViewController controller) {
    final seen = (_filmotChannelsSeen[dialogId] ?? <String>{}).toList()..sort();
    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) {
          // Union of "seen on this page" plus everything already blacklisted, so
          // users can edit entries even when the relevant row isn't on screen.
          final all = <String>{...seen, ..._filmotChannelBlacklist}.toList()..sort();
          return AlertDialog(
            title: Row(
              children: [
                Expanded(child: Text('Channel blacklist')),
                Tooltip(
                  message: 'Temporarily ignore the blacklist for this session — useful when too few matches show up.',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Disable', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: _filmotBlacklistDisabled,
                        onChanged: (v) {
                          setState(() => _filmotBlacklistDisabled = v);
                          setStateDialog(() {});
                          for (final entry in _dialog2Controllers.entries) {
                            if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: all.isEmpty
                  ? Text('No channels seen yet on this page.')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: all.length,
                      itemBuilder: (_, i) {
                        final name = all[i];
                        final blocked = _filmotChannelBlacklist.contains(name);
                        return CheckboxListTile(
                          dense: true,
                          title: Text(name, overflow: TextOverflow.ellipsis),
                          value: blocked,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _filmotChannelBlacklist.add(name);
                              } else {
                                _filmotChannelBlacklist.remove(name);
                              }
                            });
                            _saveFilmotBlacklist();
                            setStateDialog(() {});
                            for (final entry in _dialog2Controllers.entries) {
                              if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
                            }
                          },
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() => _filmotChannelBlacklist.clear());
                  _saveFilmotBlacklist();
                  setStateDialog(() {});
                  for (final entry in _dialog2Controllers.entries) {
                    if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
                  }
                },
                child: Text('Clear all'),
              ),
              TextButton(onPressed: () => Navigator.of(dctx).pop(), child: Text('Done')),
            ],
          );
        },
      ),
    );
  }

  /// Asks the dialog WebView for the YouTube URL of the focused result on the
  /// current Filmot page, then saves it. "Focused" = the row currently nearest
  /// the viewport center, which works for both the search-results layout (many
  /// rows) and the single-video layout (one row).
  Future<void> _saveCurrentFilmotVideo(WebViewController controller) async {
    // Filmot's search-results page hosts the player at the top and a list of
    // result cards in a sidebar. Clicking "Next video" swaps the iframe `src`
    // and the `#divVideoDetails` content via JS — the page URL does not
    // change. So derive the *currently playing* video id from the live iframe
    // first, then fall back to other signals.
    const js = r'''
      (function(){
        function ytIdFromAny(href) {
          if (!href) return null;
          var pats = [
            /youtube\.com\/embed\/([A-Za-z0-9_-]{6,})/,
            /youtube\.com\/watch\?v=([A-Za-z0-9_-]{6,})/,
            /youtu\.be\/([A-Za-z0-9_-]{6,})/,
            /[?&]v=([A-Za-z0-9_-]{6,})/,
            /\/sidebyside\/([A-Za-z0-9_-]{6,})/,
            /\/(?:video|watch)\/([A-Za-z0-9_-]{6,})/
          ];
          for (var i = 0; i < pats.length; i++) { var m = href.match(pats[i]); if (m) return m[1]; }
          return null;
        }
        function packFor(id, fallbackTitle) {
          var ch = (window.__cupitorVideoChannel || {})[id] || '';
          var tEl = document.querySelector('#divVideoDetails .col-6');
          var t = tEl ? (tEl.textContent || '').trim().split(/\s*[\r\n]+/)[0].slice(0, 200) : '';
          if (!t) t = (fallbackTitle || document.title || '').trim().slice(0, 200);
          return JSON.stringify({ url: 'https://www.youtube.com/watch?v=' + id, channel: ch, title: t });
        }
        // 1. The live iframe is the most reliable signal — it always reflects
        //    the currently playing video, including after a JS-driven "Next".
        var ifr = document.getElementById('player');
        if (ifr && ifr.src) {
          var id1 = ytIdFromAny(ifr.src);
          if (id1) return packFor(id1, '');
        }
        // 2. The "Open on youtube:" / external-link anchor in #divVideoDetails
        //    updates alongside the iframe.
        var detailA = document.querySelector('#divVideoDetails a[href*="watch?v="], #linktoyoutube a[href*="watch?v="]');
        if (detailA) {
          var id2 = ytIdFromAny(detailA.href || detailA.getAttribute('href') || '');
          if (id2) return packFor(id2, detailA.textContent || '');
        }
        // 3. URL-based: only true on the standalone /sidebyside/ detail page.
        var pm = location.pathname.match(/\/sidebyside\/([A-Za-z0-9_-]{6,})/);
        if (pm) return packFor(pm[1], '');
        // 4. Last resort — pick the vcard nearest the viewport center.
        var cards = Array.prototype.slice.call(document.querySelectorAll('[id^="vcard_"]'));
        var center = window.innerHeight / 2;
        var best = null, bestDist = Infinity;
        for (var i = 0; i < cards.length; i++) {
          var c = cards[i];
          var r = c.getBoundingClientRect();
          if (r.bottom < 0 || r.top > window.innerHeight) continue;
          var d = Math.abs((r.top + r.bottom) / 2 - center);
          if (d < bestDist) { bestDist = d; best = c; }
        }
        if (!best) return JSON.stringify({});
        var id4 = best.id.replace(/^vcard_/, '');
        var titleA = best.querySelector('a[id^="vlink"]');
        return packFor(id4, titleA ? titleA.textContent || '' : '');
      })();
    ''';
    try {
      final raw = await controller.runJavaScriptReturningResult(js);
      // Returned as a JSON string (double-encoded on some platforms).
      var s = raw.toString();
      if (s.startsWith('"') && s.endsWith('"')) {
        s = jsonDecode(s) as String;
      }
      final data = jsonDecode(s) as Map<String, dynamic>;
      final url = data['url']?.toString() ?? '';
      if (url.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No video URL found on screen'), duration: const Duration(seconds: 2)),
          );
        }
        return;
      }
      _handleFilmotMessage('__manual__', jsonEncode({
        'action': 'saveVideo',
        'url': url,
        'channel': data['channel']?.toString() ?? '',
        'title': data['title']?.toString() ?? '',
      }));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  void _showSavedVideosDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) => AlertDialog(
          title: Text('Saved videos (${_savedVideos.length})'),
          content: SizedBox(
            width: double.maxFinite,
            child: _savedVideos.isEmpty
                ? Text('Nothing saved yet.')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _savedVideos.length,
                    itemBuilder: (_, i) {
                      final v = _savedVideos[i];
                      final title = v['title']?.isNotEmpty == true ? v['title']! : v['url']!;
                      final subtitle = [v['channel'], v['url']].where((s) => s != null && s.isNotEmpty).join(' · ');
                      return ListTile(
                        dense: true,
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11)),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, size: 20),
                          onPressed: () {
                            setState(() => _savedVideos.removeAt(i));
                            _saveSavedVideos();
                            setStateDialog(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: _savedVideos.isEmpty ? null : () {
                final urls = _savedVideos.map((v) => v['url']).whereType<String>().join('\n');
                Clipboard.setData(ClipboardData(text: urls));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Copied ${_savedVideos.length} URLs'), duration: const Duration(seconds: 2)),
                );
              },
              child: Text('Copy URLs'),
            ),
            TextButton(
              onPressed: _savedVideos.isEmpty ? null : () {
                final lines = _savedVideos.map((v) {
                  return [v['title'] ?? '', v['channel'] ?? '', v['url'] ?? '', v['savedAt'] ?? '']
                      .map((s) => s.replaceAll('"', '""'))
                      .map((s) => '"$s"')
                      .join(',');
                }).join('\n');
                final header = '"title","channel","url","savedAt"\n';
                Clipboard.setData(ClipboardData(text: header + lines));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Copied CSV'), duration: const Duration(seconds: 2)),
                );
              },
              child: Text('Copy CSV'),
            ),
            TextButton(
              onPressed: _savedVideos.isEmpty ? null : () {
                showDialog(
                  context: dctx,
                  builder: (cctx) => AlertDialog(
                    title: Text('Clear all saved videos?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(cctx).pop(), child: Text('Cancel')),
                      TextButton(
                        onPressed: () {
                          setState(() => _savedVideos.clear());
                          _saveSavedVideos();
                          setStateDialog(() {});
                          Navigator.of(cctx).pop();
                        },
                        child: Text('Clear'),
                      ),
                    ],
                  ),
                );
              },
              child: Text('Clear'),
            ),
            TextButton(onPressed: () => Navigator.of(dctx).pop(), child: Text('Close')),
          ],
        ),
      ),
    );
  }

  // ---------- end Filmot helpers ----------

  String getUrlForLanguage(String lang) {
    return _dialogUrl + '?lang=' + (_languageParams[lang] ?? lang);
  }

  /// Handles a GitHub API proxy request from the JS channel.
  /// The message is JSON: { id, method, path, body? }
  /// Flutter adds the Authorization header, makes the call, and posts the
  /// response back via JS so the token is never exposed to the page.
  Future<void> _handleGitHubProxyRequest(JavaScriptMessage msg) async {
    Map<String, dynamic> req;
    try {
      req = jsonDecode(msg.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final id = req['id'] as String? ?? '';
    final method = (req['method'] as String? ?? 'GET').toUpperCase();
    final path = req['path'] as String? ?? '';
    final bodyStr = req['body'] as String?;
    final url = 'https://api.github.com$path';
    final token = _githubToken ?? '';

    String responseBody;
    int statusCode;
    try {
      final uri = Uri.parse(url);
      final headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (bodyStr != null) 'Content-Type': 'application/json',
      };
      http.Response response;
      switch (method) {
        case 'PUT':
          response = await http.put(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        case 'POST':
          response = await http.post(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        default:
          response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
      }
      responseBody = response.body;
      statusCode = response.statusCode;
    } catch (e) {
      responseBody = jsonEncode({'message': e.toString()});
      statusCode = 0;
    }

    // Escape the response to embed safely in a JS string template
    final escaped = jsonEncode(responseBody); // produces a quoted, escaped JSON string
    final js = '''
      (function() {
        const handler = window._ghProxyHandlers && window._ghProxyHandlers['$id'];
        if (handler) {
          delete window._ghProxyHandlers['$id'];
          handler($statusCode, $escaped);
        }
      })();
    ''';
    dialogController?.runJavaScript(js);
  }

  void _openDialogWithWebview(String text) {
    _currentDialogText = text;
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
    if (dialogController != null) {
      dialogController?.runJavaScript(jsCodeToFilterData(text));
    } else {
      dialogController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(_userAgent)
        ..addJavaScriptChannel('GitHubProxy', onMessageReceived: _handleGitHubProxyRequest)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (url) {
              _dialogErrorNotifier.value = null;
              _injectYouTubeAdBlocker(dialogController);
            },
            onWebResourceError: (error) {
              if (error.isForMainFrame == true) {
                _dialogErrorNotifier.value = '[${error.errorCode}] ${error.description}\n${error.url ?? ''}';
              }
            },
            onNavigationRequest: (request) {
              if (!request.isMainFrame) return NavigationDecision.navigate;
              final rewritten = _rewriteYouTubeUrl(request.url);
              if (rewritten != null) {
                // YouTube link clicked inside the lookup dialog — open it on
                // the chosen front-end in dialog2 (different host from
                // _dialogUrl so it falls through to the dialog2 branch below).
                _openDialog2WithWebview(rewritten);
                return NavigationDecision.prevent;
              }
              final reqHost = Uri.tryParse(request.url)?.host;
              final dialogHost = Uri.tryParse(_dialogUrl)?.host;
              if (reqHost != dialogHost) {
                _openDialog2WithWebview(request.url);
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onPageFinished: (url) {
              _injectAdBlocker(dialogController);
              dialogController?.runJavaScript(jsCodeToFilterData(_currentDialogText));
            },
          ),
        )
        ..loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
      _enableThirdPartyCookies(dialogController!);
    }

    // Always show the dialog (it may have been dismissed previously)
    _showDialog1();
  }

  void _showDialog1() {
    if (dialogController == null) return;
    // Already on screen — nothing to push. The caller's content update via
    // dialogController.runJavaScript will reach the live WebView regardless.
    if (_dialog1Visible) {
      if (_dialog1Minimized) setState(() => _dialog1Minimized = false);
      return;
    }
    setState(() => _dialog1Minimized = false);
    _bumpMinimizedVersion();
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // If dialog has been minimized before, tapping outside should minimize, not close
    final hasBeenMinimized = _dialog1EverMinimized;
    _dialog1Visible = true;

    showDialog(
      context: context,
      barrierDismissible: !hasBeenMinimized, // Prevent outside tap closing if ever minimized
      builder: (ctx) => hasBeenMinimized
        ? GestureDetector(
            // Custom barrier tap handler - minimizes instead of closing
            onTap: () {
              setState(() => _dialog1Minimized = true);
              Navigator.of(ctx).pop();
              _bumpMinimizedVersion();
            },
            child: Container(
              color: Colors.transparent,
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // Prevent tap propagation from dialog content
                  child: Dialog(
                    insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
                    child: _buildDialog1Content(ctx, screenWidth, screenHeight),
                  ),
                ),
              ),
            ),
          )
        : Dialog(
            insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
            child: _buildDialog1Content(ctx, screenWidth, screenHeight),
          ),
    ).then((_) {
      // Dialog closed - but keep controller alive to avoid reloading.
      // Controller will be cleaned up only when app is disposed or language changes.
      // This prevents unnecessary reloads when reopening the dialog.
      _dialog1Visible = false;
    });
  }

  Widget _buildDialog1Content(BuildContext ctx, double screenWidth, double screenHeight) {
    return Container(
      width: screenWidth,
      height: screenHeight,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ValueListenableBuilder<bool>(
                  // The mic state changes async inside _speech callbacks, so
                  // the outer State's setState() doesn't repaint the dialog
                  // route — listen to the mirrored notifier instead.
                  valueListenable: _isListeningNotifier,
                  builder: (_, listening, __) => IconButton(
                    tooltip: listening ? 'Stop listening' : 'Voice input',
                    icon: Icon(
                      listening ? Icons.mic : Icons.mic_none,
                      color: listening ? Colors.red : null,
                    ),
                    onPressed: _toggleVoiceInput,
                  ),
                ),
                IconButton(
                  tooltip: 'Reload (use if dialog appears stuck)',
                  icon: Icon(Icons.refresh),
                  onPressed: () {
                    // Force-recreate the dialog WebView. We keep dialogController
                    // alive across closes for fast re-opens, but if the shared
                    // WebView renderer process gets wedged (e.g. by a heavy page
                    // loaded in dialog2), this controller's view becomes stuck
                    // and reopening shows the same wedge. This button is the
                    // escape hatch.
                    final old = dialogController;
                    dialogController = null;
                    if (old != null) _shutdownDialogWebView(old);
                    setState(() => _dialog1Minimized = false);
                    Navigator.of(ctx).pop();
                    _openDialogWithWebview(_currentDialogText);
                  },
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _dialog1Minimized = true;
                      _dialog1EverMinimized = true; // Mark as ever minimized
                    });
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                  child: Text('Minimize'),
                ),
                TextButton(
                  onPressed: () {
                    // Clear minimized state when manually closing
                    setState(() => _dialog1Minimized = false);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                  child: Text('Close'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<String?>(
              valueListenable: _dialogErrorNotifier,
              builder: (_, error, __) => error != null
                  ? _errorView(error, () {
                      _dialogErrorNotifier.value = null;
                      dialogController?.loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
                    })
                  : ValueListenableBuilder<bool>(
                      valueListenable: _einkModeNotifier,
                      builder: (_, eink, child) => ColorFiltered(
                        colorFilter: eink ? _einkColorFilter : _identityColorFilter,
                        child: child,
                      ),
                      child: WebViewWidget(controller: dialogController!),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _speechLocale() {
    switch (_selectedLanguage) {
      case 'sv': return 'sv-SE';
      case 'es': return 'es-ES';
      default: return 'en-US';
    }
  }

  Future<void> _toggleVoiceInput() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
            _isListeningNotifier.value = false;
      // Resume normal app bar timer behavior when voice input stops
      if (_showAppBar && Platform.isAndroid) {
        _showAppBarWithTimer();
      }
      return;
    }
    // Show app bar when starting voice input
    _showAppBarWithTimer();
    try {
      String lastWords = '';
      final available = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted && _isListening) {
              setState(() => _isListening = false);
            _isListeningNotifier.value = false;
              // Resume normal timer behavior when voice input stops
              if (_showAppBar && Platform.isAndroid) {
                _showAppBarWithTimer();
              }
              if (lastWords.isNotEmpty) {
                _openDialogWithWebview(lastWords);
                lastWords = '';
              }
            }
          }
        },
        onError: (error) {
          debugPrint('Speech error: $error');
          if (mounted) {
            setState(() => _isListening = false);
            _isListeningNotifier.value = false;
            // Resume normal timer behavior on error
            if (_showAppBar && Platform.isAndroid) {
              _showAppBarWithTimer();
            }
            // Fallback to text input if speech fails
            _showVoiceInputFallback();
          }
        },
      );
      if (!available) {
        _showVoiceInputFallback();
        return;
      }
      setState(() => _isListening = true);
      _isListeningNotifier.value = true;
      await _speech.listen(
        localeId: _speechLocale(),
        onResult: (result) {
          lastWords = result.recognizedWords;
          if (result.finalResult && lastWords.isNotEmpty) {
            _speech.stop();
            setState(() => _isListening = false);
            _isListeningNotifier.value = false;
            // Resume normal timer behavior when voice input completes
            if (_showAppBar && Platform.isAndroid) {
              _showAppBarWithTimer();
            }
            if (mounted) {
              _openDialogWithWebview(lastWords);
              lastWords = '';  // prevent double dispatch from onStatus
            }
          }
        },
        listenFor: const Duration(seconds: 10),
      );
    } catch (e) {
      debugPrint('Speech init error: $e');
      if (mounted) {
        setState(() => _isListening = false);
            _isListeningNotifier.value = false;
        // Resume normal timer behavior on error
        if (_showAppBar && Platform.isAndroid) {
          _showAppBarWithTimer();
        }
      }
    }
  }

  void _showVoiceInputFallback() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Enter word'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: 'Type a word...', border: OutlineInputBorder()),
          onSubmitted: (text) {
            Navigator.of(ctx).pop();
            if (text.trim().isNotEmpty) _openDialogWithWebview(text.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (ctrl.text.trim().isNotEmpty) _openDialogWithWebview(ctrl.text.trim());
            },
            child: Text('Look up'),
          ),
        ],
      ),
    );
  }

  String jsCodeToFilterData(String text) {
    final escaped = text.replaceAll("'", "\\'");
    // Token is intentionally NOT passed here — GitHub API calls are proxied
    // through the GitHubProxy JavaScriptChannel so the token stays in Flutter.
    return "window.dispatchEvent(new CustomEvent('filterData', { detail: { text: '$escaped' } }));";
  }

  Widget _errorView(String message, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red),
            SizedBox(height: 12),
            Text('Failed to load page', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                message,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.red.shade800),
              ),
            ),
            SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh),
              label: Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Timer? _appBarTimer;
  DateTime? _lastTapTime;
  // Long-press tracking — fires a top-bar toggle if the pointer stays down
  // for ~500ms without significant movement. We must NOT consume the touch
  // (the WebView still needs it for native text selection), so this lives
  // inside the existing translucent Listener.
  Timer? _longPressTimer;
  Offset? _pointerDownPos;
  static const double _kLongPressMoveSlop = 12.0;
  static const Duration _kLongPressDuration = Duration(milliseconds: 500);

  void _handleDoubleTapDetection() {
    final now = DateTime.now();
    if (_lastTapTime != null && now.difference(_lastTapTime!) < const Duration(milliseconds: 400)) {
      _lastTapTime = null;
      _toggleAppBar();
    } else {
      _lastTapTime = now;
    }
  }

  void _toggleAppBar() {
    if (_showAppBar) {
      _appBarTimer?.cancel();
      setState(() => _showAppBar = false);
    } else {
      _showAppBarWithTimer();
    }
  }

  void _onPagePointerDown(PointerDownEvent e) {
    _handleDoubleTapDetection();
    _pointerDownPos = e.position;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kLongPressDuration, () {
      _longPressTimer = null;
      _toggleAppBar();
    });
  }

  void _onPagePointerMove(PointerMoveEvent e) {
    if (_longPressTimer == null || _pointerDownPos == null) return;
    if ((e.position - _pointerDownPos!).distance > _kLongPressMoveSlop) {
      _longPressTimer?.cancel();
      _longPressTimer = null;
    }
  }

  void _onPagePointerUp(PointerUpEvent _) {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _pointerDownPos = null;
  }

  void _showAppBarWithTimer() {
    setState(() => _showAppBar = true);
    _appBarTimer?.cancel();
    // Don't auto-hide app bar when voice input is active
    if (Platform.isAndroid && !_isListening) {
      _appBarTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _showAppBar = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isControllerReady) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final appBar = AppBar(
      title: Focus(
        onFocusChange: (focused) {
          if (Platform.isAndroid) setState(() => _urlBarFocused = focused);
          if (focused) { _appBarTimer?.cancel(); }
        },
        child: TextField(
          controller: _urlController,
          decoration: InputDecoration(
            hintText: 'Enter URL',
            border: InputBorder.none,
            suffixIcon: IconButton(icon: Icon(Icons.arrow_forward), onPressed: () {
              _loadUrl();
              FocusManager.instance.primaryFocus?.unfocus();
            }),
          ),
          keyboardType: TextInputType.url,
          onTap: () => _urlController.selection = TextSelection(baseOffset: 0, extentOffset: _urlController.text.length),
          onSubmitted: (_) {
            _loadUrl();
            FocusManager.instance.primaryFocus?.unfocus();
          },
        ),
      ),
      actions: _urlBarFocused ? null : [
        IconButton(
          icon: Icon(Icons.tune_outlined),
          tooltip: 'Tools',
          onPressed: _showToolsDrawer,
        ),
        if (_currentPdfUrl != null) ...([
          _isExtractingPdf
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              )
            : IconButton(
                icon: Icon(_isTextView ? Icons.picture_as_pdf : Icons.text_snippet_outlined),
                tooltip: _isTextView ? 'Switch to PDF view' : 'Switch to text view',
                onPressed: _togglePdfTextView,
              ),
        ]),
        IconButton(
          icon: Icon(_showFindBar ? Icons.search_off : Icons.search),
          tooltip: _showFindBar ? 'Close find' : 'Find in page',
          onPressed: () {
            setState(() {
              _showFindBar = !_showFindBar;
              if (!_showFindBar) {
                _findController.clear();
                _clearFindHighlights();
              }
            });
          },
        ),
        IconButton(
          icon: Icon(Icons.bookmarks_outlined),
          onPressed: _showBookmarks,
          tooltip: 'Bookmarks',
        ),
        IconButton(
          icon: Icon(Icons.open_in_new),
          onPressed: () async {
            String text = '';
            if (_currentPdfUrl != null && !_isTextView
                && _pdfSelectedText.isNotEmpty) {
              text = _pdfSelectedText;
            } else {
              const js = '''
                (function getSelFromWindow(w) {
                  try {
                    const s = w.getSelection().toString().trim();
                    if (s) return s;
                    for (let i = 0; i < w.frames.length; i++) {
                      const found = getSelFromWindow(w.frames[i]);
                      if (found) return found;
                    }
                  } catch(e) {}
                  return '';
                })(window);
              ''';
              // Timeout the JS call: if the main WebView's renderer is wedged
              // (e.g. after a heavy page in a dialog jammed the shared renderer
              // process), runJavaScriptReturningResult never resolves and the
              // await blocks here forever — meaning open_in_new appears to do
              // nothing. Falling back to empty text lets the dialog still open
              // so the user can use the Reload button to recover.
              try {
                final result = await _controller
                    .runJavaScriptReturningResult(js)
                    .timeout(const Duration(seconds: 2));
                text = result.toString().replaceAll('"', '');
              } catch (_) {}
            }
            _openDialogWithWebview(text);
          },
        ),
      ],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_currentPdfUrl != null) {
          // Dismiss PDF overlay — the WebView still holds the previous page
          // since PDF navigation was prevented (NavigationDecision.prevent).
          setState(() {
            _currentPdfUrl = null;
            _extractedPdfHtml = null;
            _isTextView = false;
            _isShowingOurHtml = false;
          });
          return;
        }
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            // Main content — fills entire screen
            ColorFiltered(
              colorFilter: _isEinkMode ? _einkColorFilter : _identityColorFilter,
              child: Stack(
                children: [
                  WebViewWidget(controller: _controller),
                  if (_currentPdfUrl != null && !_isTextView)
                    Positioned.fill(
                      child: PdfViewer.uri(
                        Uri.parse(_currentPdfUrl!),
                        controller: _pdfViewerController ??= PdfViewerController(),
                        params: PdfViewerParams(
                          enableTextSelection: true,
                          onTextSelectionChange: (selections) {
                            final text = selections
                                .map((s) => s.ranges.map((r) =>
                                  s.pageText.fullText.substring(r.start, r.end)
                                ).join())
                                .join(' ')
                                .trim();
                            _pdfSelectedText = text;
                            if (text.isNotEmpty) _showAppBarWithTimer();
                          },
                          backgroundColor: Colors.white,
                          calculateInitialZoom: (doc, ctrl, fitZoom, coverZoom) {
                            _pdfFitZoom = fitZoom;
                            if (_currentPdfUrl != null) {
                              final saved = _scrollPositions[_currentPdfUrl!.split('#').first];
                              if (saved != null && saved > 1) {
                                Future.delayed(const Duration(milliseconds: 100), () {
                                  _pdfViewerController?.goToPage(pageNumber: saved.round());
                                });
                              }
                            }
                            return fitZoom * (1.0 + _pdfZoomLevel * 0.25).clamp(0.25, 4.0);
                          },
                          onViewSizeChanged: (viewSize, oldSize, ctrl) {
                            if (_pdfFitZoom > 0) {
                              WidgetsBinding.instance.addPostFrameCallback(
                                  (_) { if (mounted) _applyPdfZoom(); });
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Double-tap + long-press detector (Android only — macOS keeps the
            // app bar always visible). Listener doesn't consume events, so the
            // WebView still gets the touches for native text selection.
            if (Platform.isAndroid)
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onPagePointerDown,
                  onPointerMove: _onPagePointerMove,
                  onPointerUp: _onPagePointerUp,
                  onPointerCancel: (_) { _longPressTimer?.cancel(); _longPressTimer = null; _pointerDownPos = null; },
                ),
              ),
            // Transparent overlay to unfocus URL bar when tapping the page
            if (_urlBarFocused)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                ),
              ),
            // App bar overlay — always visible on macOS, toggled on Android
            if (_showAppBar || !Platform.isAndroid)
              Positioned(
                top: 0, left: 0, right: 0,
                child: SafeArea(
                  bottom: false,
                  child: appBar,
                ),
              ),
            // Find-in-page bar
            if (_showFindBar)
              Positioned(
                top: _showAppBar ? kToolbarHeight + MediaQuery.of(context).padding.top : 0,
                left: 0, right: 0,
                child: Material(
                  elevation: 4,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _findController,
                            autofocus: true,
                            decoration: const InputDecoration(
                              hintText: 'Find in page...',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (q) => _findInPage(q),
                            textInputAction: TextInputAction.search,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                          tooltip: 'Previous',
                          onPressed: () => _findInPage(_findController.text, forward: false),
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                          tooltip: 'Next',
                          onPressed: () => _findInPage(_findController.text),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          tooltip: 'Close',
                          onPressed: () {
                            setState(() {
                              _showFindBar = false;
                              _findController.clear();
                              _clearFindHighlights();
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Minimized-dialog chips live on the root overlay (see
            // _ensureFloatingChipsOverlay) so they stay on top of any open
            // dialog and can be dragged freely.
          ],
        ),
      ),
    );
  }
}

/// A small draggable chip shown on the root overlay to represent a minimized
/// dialog. Tap to restore; the trailing "×" closes the dialog entirely.
class _FloatingDraggableChip extends StatefulWidget {
  final Offset startPosition;
  final Size screenSize;
  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<Offset>? onPositionChanged;
  const _FloatingDraggableChip({
    super.key,
    required this.startPosition,
    required this.screenSize,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.onClose,
    this.onPositionChanged,
  });
  @override
  State<_FloatingDraggableChip> createState() => _FloatingDraggableChipState();
}

class _FloatingDraggableChipState extends State<_FloatingDraggableChip> {
  late Offset _pos = widget.startPosition;
  bool _dragging = false;
  static const double _kEstimatedWidth = 140;
  static const double _kEstimatedHeight = 44;

  @override
  void didUpdateWidget(_FloatingDraggableChip old) {
    super.didUpdateWidget(old);
    // Re-clamp if the screen rotated and the chip would be off-screen.
    final maxX = widget.screenSize.width - _kEstimatedWidth;
    final maxY = widget.screenSize.height - _kEstimatedHeight;
    if (_pos.dx > maxX || _pos.dy > maxY) {
      _pos = Offset(_pos.dx.clamp(0.0, maxX), _pos.dy.clamp(0.0, maxY));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _dragging = true),
        onPanUpdate: (d) {
          setState(() {
            final nx = (_pos.dx + d.delta.dx).clamp(0.0, widget.screenSize.width - _kEstimatedWidth);
            final ny = (_pos.dy + d.delta.dy).clamp(0.0, widget.screenSize.height - _kEstimatedHeight);
            _pos = Offset(nx, ny);
          });
          widget.onPositionChanged?.call(_pos);
        },
        onPanEnd: (_) => setState(() => _dragging = false),
        // Treat a simple press as restore — onTap, not onPanEnd-without-movement,
        // because GestureDetector resolves them independently.
        onTap: widget.onTap,
        child: Material(
          elevation: _dragging ? 12 : 6,
          color: Theme.of(context).primaryColor,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.icon,
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 90),
                  child: Text(
                    widget.label,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: widget.onClose,
                  customBorder: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, color: Colors.white70, size: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
