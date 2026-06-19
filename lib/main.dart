import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform, File, Directory;
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:google_mlkit_translation/google_mlkit_translation.dart' as mlkit;
import 'package:flutter_tts/flutter_tts.dart';
import 'yt_dlp_service.dart';
import 'epub_reader.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hide both system bars for maximum reading area, but rely on
  // `immersiveSticky` so the user can swipe from any edge to transiently
  // reveal them (status bar top, back / home / recents bottom). They
  // auto-hide again after a few seconds. This is the standard Android
  // immersive UX — no custom in-app gesture needed.
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
  // ---- Wiktionary "collect words" feature ----
  // When ON: clicks on the Wiktionary page are intercepted — links don't
  // navigate, and the clicked word is appended to _wiktCollectedWords (joined
  // by '|' when copied out). Global so a single list spans multiple open
  // Wiktionary dialogs, persisted to SharedPreferences across sessions.
  final ValueNotifier<bool> _wiktCollectMode = ValueNotifier(false);
  final ValueNotifier<List<String>> _wiktCollectedWords = ValueNotifier(<String>[]);
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
  // Platforms whose top app bar auto-hides on a timer and toggles via
  // double-tap / long-press. Mac mirrors Android so both feel identical.
  bool get _autoHideAppBar => Platform.isAndroid || Platform.isMacOS;
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
  // Long-press-to-dictate mode: keeps the speech recognizer alive (auto-
  // restarting across the package's per-utterance windows), accumulating
  // transcript until the user taps again to stop.
  bool _continuousVoiceActive = false;
  final StringBuffer _continuousTranscript = StringBuffer();
  String _continuousPartial = '';
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
  // Fullscreen toggle for dialog1. Notifier (not bare field) so the showDialog
  // route — which lives outside the outer State's setState scope — rebuilds.
  final ValueNotifier<bool> _dialog1FullscreenNotifier = ValueNotifier(false);
  // Web Speech Synthesis bridge for dialog1. The Android WebView does not
  // implement window.speechSynthesis, so the dictionary page's TTS calls go
  // through a JS-side polyfill that posts here. We speak one utterance at a
  // time via flutter_tts and fire start/end JS events back into the page so
  // utterance.onstart / .onend work as the page expects.
  FlutterTts? _dialog1Tts;
  final List<Map<String, dynamic>> _dialog1TtsQueue = [];
  int? _dialog1TtsActiveJsId;
  bool _dialog1TtsBusy = false;
  static const _adBlockChannel = MethodChannel('cupitor/adblock');
  // Headset / Bluetooth media-key bridge. Native (MediaSessionCompat) sends
  // play/pause/next/prev events here; we forward each as a `cupitorMediaKey`
  // CustomEvent into dialog1's WebView so the language page can run custom
  // playback behavior (replay previous video, etc.). The page can also push
  // its current playing state back via the `MediaState` JS channel so the
  // lockscreen and Bluetooth car UI show the right title.
  static const _mediaKeysChannel = MethodChannel('cupitor/mediakeys');
  // Runtime-permissions bridge. Android's `RECORD_AUDIO` is a *dangerous*
  // permission — manifest-declared but not auto-granted; the user has to
  // accept the OS prompt. WebView's per-resource grant in
  // `_configureAndroidWebView` is meaningless without this, so any path
  // that needs the mic goes through `_ensureMicPermission` first.
  static const _permsChannel = MethodChannel('cupitor/perms');
  bool _mediaSessionActive = false;
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
  // Per-dialog2 ScaffoldMessenger keys. Dialog2 routes are near-fullscreen
  // and sit above the root Scaffold, so a SnackBar shown via the root
  // ScaffoldMessenger renders behind them and the user never sees it. Each
  // open dialog2 owns its own ScaffoldMessenger via the key below, so
  // feedback (save-confirm, "already saved", etc.) lands inside the dialog.
  final Map<String, GlobalKey<ScaffoldMessengerState>> _dialog2ScaffoldKeys = {};
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
    _mediaKeysChannel.setMethodCallHandler(null);
    if (_mediaSessionActive) {
      // Best-effort deactivation; ignore failures during teardown.
      _mediaKeysChannel.invokeMethod<void>('setActive', {'active': false});
      _mediaSessionActive = false;
    }
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
    _dialog1FullscreenNotifier.dispose();
    _dialog1Tts?.stop();
    _dialog1Tts = null;
    // Close any open ML Kit translators in the snippet-bridge pool.
    for (final t in _translatorPool.values) {
      try { t.close(); } catch (_) {}
    }
    _translatorPool.clear();
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
    // Kick the 10s auto-hide timer so the app bar fades on its own after
    // launch (otherwise it only starts on user-driven triggers like
    // selection/voice, and a fresh window would stay open indefinitely).
    if (_autoHideAppBar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAppBarWithTimer();
      });
    }
    // Listen for auto-detected ad hosts coming from the native layer
    if (Platform.isAndroid) {
      _adBlockChannel.setMethodCallHandler((call) async {
        if (call.method == 'onHostDetected') {
          final host = call.arguments['host'] as String?;
          if (host != null && mounted) _showDetectedAdHostBanner(host);
        }
      });
      _mediaKeysChannel.setMethodCallHandler((call) async {
        if (call.method == 'onKey') {
          final key = (call.arguments as Map?)?['key']?.toString();
          if (key != null) _dispatchMediaKeyToDialog1(key);
        }
      });
    }
    // Warm the remote-snippet cache in parallel with prefs/init so the very
    // first navigation can already inject hooks at onPageStarted (instead of
    // waiting for onPageFinished). Critical for the Netflix manifest case —
    // autoplay fires before onPageFinished otherwise.
    _warmRemoteSnippetCache();
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
      // Wiktionary collect-words list. Persisted across sessions; toggle state
      // is intentionally NOT persisted (default off on each launch so a stale
      // "collect mode" doesn't silently swallow real clicks).
      _wiktCollectedWords.value = prefs.getStringList('wiktCollectedWords') ?? <String>[];
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(_userAgent)
        ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) => _openDialogWithWebview(msg.message.toString().replaceAll('"', '')))
        ..addJavaScriptChannel('PdfIframeDetector', onMessageReceived: (msg) => _handlePdfIframe(msg.message))
        ..addJavaScriptChannel('SpaNavigationDetector', onMessageReceived: (msg) => _onSpaNavigation(msg.message))
        ..addJavaScriptChannel('AdHostDetector', onMessageReceived: (msg) => _onJsAdHostDetected(msg.message))
        ..addJavaScriptChannel('SelectionChannel', onMessageReceived: (_) {
          if (_autoHideAppBar && !_showAppBar) _showAppBarWithTimer();
        })
        // Page-side fallback for app-bar gestures. On macOS the WKWebView is
        // a native NSView that swallows pointer events before Flutter's
        // Listener can see them, so the Flutter-level double-tap / long-press
        // never fires. The injected JS posts here instead.
        ..addJavaScriptChannel('AppBarToggleChannel', onMessageReceived: (_) {
          if (_autoHideAppBar) _toggleAppBar();
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
        ..addJavaScriptChannel('TranslateRequest', onMessageReceived: _handleTranslateRequest)
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
              // .epub link clicked anywhere in the main WebView: download
              // through the EPUB reader's helper (so it lands in the
              // app's cache with a stable name) and push the reader.
              // Intercepts on all platforms — the WebView would otherwise
              // either download or show a "this format can't be displayed"
              // error.
              if (_looksLikeEpubUrl(url)) {
                _downloadAndOpenEpub(url);
                return NavigationDecision.prevent;
              }
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
              // Inject the cached remote snippet here too — onPageFinished is
              // too late for hooks that need to be in place before the page's
              // own scripts run (e.g. Netflix XHR/fetch override on the
              // manifest endpoint). The snippet self-guards against duplicate
              // installs, so re-running on every navigation is safe.
              _injectRemoteSnippetEarly();
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
              if (Platform.isMacOS) _injectAppBarGestureDetector();
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

  /// Page-side double-click + long-press detector used to toggle the app bar
  /// on macOS, where the native WKWebView swallows pointer events before
  /// Flutter's Listener can see them. Posts to `AppBarToggleChannel` which
  /// drives the same `_toggleAppBar()` Android uses, so behavior matches.
  void _injectAppBarGestureDetector() {
    _controller.runJavaScript(r'''
      (function(){
        if (window.__cupAppBarGestures) return;
        window.__cupAppBarGestures = true;
        var lpTimer = null;
        var downX = 0, downY = 0;
        var SLOP = 12;
        var LP_MS = 500;
        function cancelLp(){ if (lpTimer){ clearTimeout(lpTimer); lpTimer = null; } }
        document.addEventListener('dblclick', function(){
          try { AppBarToggleChannel.postMessage('dbl'); } catch(e) {}
        }, true);
        document.addEventListener('mousedown', function(e){
          downX = e.clientX; downY = e.clientY;
          cancelLp();
          lpTimer = setTimeout(function(){
            lpTimer = null;
            try { AppBarToggleChannel.postMessage('lp'); } catch(e) {}
          }, LP_MS);
        }, true);
        document.addEventListener('mousemove', function(e){
          if (!lpTimer) return;
          if (Math.abs(e.clientX - downX) > SLOP || Math.abs(e.clientY - downY) > SLOP) cancelLp();
        }, true);
        document.addEventListener('mouseup', cancelLp, true);
        document.addEventListener('mouseleave', cancelLp, true);
        window.addEventListener('blur', cancelLp);
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

  /// Inject the cached snippet at onPageStarted — i.e. before the page's
  /// own scripts run. This is what lets hooks like the Netflix XHR / fetch
  /// override land in time to catch the first manifest request (Netflix
  /// autoplays as soon as the SPA shell is ready, so onPageFinished is too
  /// late for that first call). No network — if the cache is empty (first
  /// run after install), this no-ops and onPageFinished does the full fetch.
  /// The snippet self-guards against double-install via __cup* flags.
  void _injectRemoteSnippetEarly() {
    final cached = _cachedRemoteSnippet;
    if (cached == null) return;
    try { _controller.runJavaScript(_wrapSnippetWithLogShim(cached)); } catch (_) {}
  }

  /// Fire-and-forget cache warm so the first navigation after launch can
  /// still inject early. Runs in parallel with everything else in initState.
  void _warmRemoteSnippetCache() {
    if (_cachedRemoteSnippet != null) return;
    http.get(
      Uri.parse('https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/refs/heads/gh-pages/db/js/snippet.js'),
    ).timeout(const Duration(seconds: 8)).then((response) {
      if (response.statusCode == 200) _cachedRemoteSnippet = response.body;
    }).catchError((_) { /* offline / down — handled by the runtime fetch */ });
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
    _configureAndroidWebView(controller);
  }

  /// Extra Android-only WebView configuration required by sites like Spotify
  /// that need (a) autoplay without a synthetic user gesture, and (b) Widevine
  /// DRM (which Android exposes via the `PROTECTED_MEDIA_ID` permission). Also
  /// blanket-grants common media permissions (mic / camera / midi) when a page
  /// requests them, since the user already had to trust the URL to load it.
  void _configureAndroidWebView(WebViewController controller) {
    if (!Platform.isAndroid) return;
    try {
      final platform = controller.platform;
      if (platform is! AndroidWebViewController) return;
      // Spotify, YouTube embeds, and most modern streaming sites refuse to
      // start audio if the WebView's `mediaPlaybackRequiresUserGesture` is
      // left at its default `true` — they treat the missing gesture as an
      // autoplay-blocked signal and don't even attempt playback.
      platform.setMediaPlaybackRequiresUserGesture(false);
      // Grant requested resource permissions. `protectedMediaId` is needed
      // for Widevine DRM (Spotify Web Player); `microphone` is needed for
      // the manual-entry audio recorder. For mic specifically we ALSO have
      // to make sure Android's runtime `RECORD_AUDIO` is granted to the
      // host app — granting the WebView resource without the OS-level
      // permission still results in `getUserMedia` rejecting silently.
      platform.setOnPlatformPermissionRequest((request) {
        final needsMic = request.types.contains(WebViewPermissionResourceType.microphone);
        if (needsMic) {
          // Fire-and-forget — grant() / deny() are themselves async.
          () async {
            final ok = await _ensureMicPermission();
            try {
              if (ok) await request.grant();
              else    await request.deny();
            } catch (_) {}
          }();
        } else {
          try { request.grant(); } catch (_) {}
        }
      });
    } catch (_) { /* best-effort */ }
  }

  /// Ensure Android's `RECORD_AUDIO` runtime permission is granted to the
  /// host app, prompting the user if needed. Returns true on grant, false
  /// on denial / any error. iOS/macOS are no-ops (mic permission there is
  /// handled at the OS level when WKWebView calls into AVCaptureSession,
  /// and prompted via the app's Info.plist usage descriptions).
  Future<bool> _ensureMicPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _permsChannel.invokeMethod<bool>('requestMicrophone');
      return ok ?? false;
    } catch (e) {
      debugPrint('mic permission request failed: $e');
      return false;
    }
  }

  /// Release the mic from `speech_to_text` so a subsequent
  /// `getUserMedia({audio:true})` inside dialog1's WebView can open it.
  /// AudioRecord can only be held by one consumer at a time on Android,
  /// and if continuous voice capture is still active (or even just settling
  /// after a one-shot listen), getUserMedia rejects with NotReadableError.
  ///
  /// Always issue stop+cancel — we've seen cases where `_continuousVoiceActive`
  /// is false but `_speech` still holds the SpeechRecognizer (e.g. a partial
  /// onError that never updated our flag). stop+cancel are no-ops when STT
  /// isn't running, so the unconditional call is safe.
  Future<void> _releaseMicFromSpeechToText() async {
    _continuousVoiceActive = false;
    try { await _speech.stop(); } catch (_) {}
    try { await _speech.cancel(); } catch (_) {}
    if (mounted && _isListening) setState(() => _isListening = false);
    _isListeningNotifier.value = false;
    // The underlying AudioRecord teardown is async at the OS layer — give
    // it a beat to actually let go before the WebView tries to claim it.
    // 500 ms covers SpeechRecognizer's own settle time on slower devices;
    // below that getUserMedia can still race with NotReadableError.
    await Future<void>.delayed(const Duration(milliseconds: 500));
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
                      leading: Icon(Icons.bookmarks_outlined),
                      title: Text('Bookmarks'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showBookmarks();
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
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: const Text('Open EPUB'),
                      subtitle: const Text('From device storage or a URL'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showEpubSourcePicker();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.history_edu_outlined),
                      title: const Text('EPUB library'),
                      subtitle: const Text('Resume a recent book'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showEpubLibrary();
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

  // ─── EPUB reader integration ────────────────────────────────────────────
  // The reader lives in [lib/epub_reader.dart]. We pull EPUB files from
  // three sources (device storage, an HTTP/HTTPS URL, a link in the main
  // WebView that ends in .epub), cache them under <docs>/epubs/, and push
  // the reader screen. Word-tap and selection callbacks from the reader
  // route into the existing dictionary flow via [_openDialogWithWebview],
  // so the EPUB inherits all of Cupitor's lookup machinery for free.

  EpubLibrary? _epubLibrary;

  Future<EpubLibrary> _ensureEpubLibrary() async {
    return _epubLibrary ??= await EpubLibrary.load();
  }

  Future<void> _launchEpubReader(File file) async {
    final lib = await _ensureEpubLibrary();
    if (!mounted) return;
    await openEpubReader(
      context,
      file: file,
      library: lib,
      onLookup: (word, _) {
        // Send the looked-up word into the existing lookup flow. The
        // surrounding context is discarded for now — dialog1 only takes
        // a query string. Could be threaded through later if we want to
        // pre-fill a "context" field.
        _openDialogWithWebview(word);
      },
    );
  }

  void _showEpubSourcePicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Open EPUB',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('From device storage'),
              subtitle: const Text('Pick a .epub file'),
              onTap: () async {
                Navigator.of(ctx).pop();
                try {
                  final f = await pickEpubFromDevice();
                  if (f != null) await _launchEpubReader(f);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not pick file: $e')),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('From URL'),
              subtitle: const Text('Download and open'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _promptEpubUrlAndOpen();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptEpubUrlAndOpen() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open EPUB from URL'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/book.epub',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _downloadAndOpenEpub(url);
  }

  Future<void> _downloadAndOpenEpub(String url) async {
    // Show an indeterminate progress dialog while the file downloads. It's
    // dismissed in `finally` so a network error doesn't leave it stuck.
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(width: 16),
              Text('Downloading EPUB…'),
            ],
          ),
        ),
      ),
    );
    try {
      final f = await downloadEpubFromUrl(url);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      if (f != null) await _launchEpubReader(f);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not download EPUB: $e')),
      );
    }
  }

  Future<void> _showEpubLibrary() async {
    final lib = await _ensureEpubLibrary();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: const [
                    Text('EPUB library',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: lib.entries.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No books yet. Use Open EPUB to add one.'),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: lib.entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final e = lib.entries[i];
                          return ListTile(
                            leading: SizedBox(
                              width: 40,
                              height: 56,
                              child: _epubCoverThumbnail(e),
                            ),
                            title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(e.author ?? e.path,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Remove from library',
                              onPressed: () async {
                                await lib.remove(e.key);
                                setSheet(() {});
                              },
                            ),
                            onTap: () async {
                              Navigator.of(ctx).pop();
                              final f = File(e.path);
                              if (!await f.exists()) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('File missing: ${e.path}')),
                                );
                                return;
                              }
                              await _launchEpubReader(f);
                            },
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

  /// Library-row thumbnail — book cover if present, fallback icon otherwise.
  /// Wrapped in a small frame so the row layout is stable even when the
  /// cover file is missing (e.g. an old library entry from before covers
  /// were stored).
  Widget _epubCoverThumbnail(EpubLibraryEntry e) {
    final p = e.coverPath;
    if (p != null) {
      final f = File(p);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.file(
            f,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _epubCoverPlaceholder(),
          ),
        );
      }
    }
    return _epubCoverPlaceholder();
  }

  Widget _epubCoverPlaceholder() => Container(
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(3),
        ),
        child: const Icon(Icons.menu_book_outlined, size: 22, color: Colors.grey),
      );

  // True if a URL likely points to an EPUB. Cheap path-extension check —
  // mirrors `_looksLikePdfUrl` so the navigation delegate can short-circuit
  // before WebView opens the file as a download.
  bool _looksLikeEpubUrl(String url) {
    final lower = url.toLowerCase();
    final qPos = lower.indexOf('?');
    final path = qPos >= 0 ? lower.substring(0, qPos) : lower;
    return path.endsWith('.epub');
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
    // Every fresh Wiktionary dialog starts with collect mode OFF — a stale
    // toggle from a previous dialog would silently swallow normal clicks here.
    // Also reset the captured-words list so a new lookup session starts with
    // a clean slate; the user explicitly opted into capture for the previous
    // session, and silently mixing those words into a new one would surprise
    // them. Persist immediately so the empty state survives an app restart.
    if (_isWiktionaryUrl(url)) {
      if (_wiktCollectMode.value) _wiktCollectMode.value = false;
      if (_wiktCollectedWords.value.isNotEmpty) {
        _wiktCollectedWords.value = <String>[];
        _persistWiktCollectedWords();
      }
    }
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
      ..addJavaScriptChannel('WiktCollect', onMessageReceived: (msg) => _handleWiktCollectMessage(msg.message))
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
          if (_isWiktionaryUrl(finishedUrl)) {
            // Install (idempotent) the click interceptor, then sync the
            // current toggle state — flipping the toggle later only needs
            // _pushWiktCollectMode(); no re-injection.
            dialog2Controller.runJavaScript(_wiktCollectJs);
            _pushWiktCollectMode(dialog2Controller);
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
        _dialog2ScaffoldKeys.remove(dialogId);
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
    final messengerKey = _dialog2ScaffoldKeys.putIfAbsent(
      dialogId,
      () => GlobalKey<ScaffoldMessengerState>(),
    );
    return ScaffoldMessenger(
      key: messengerKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
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
                if (_isWiktionaryUrl(url)) ...[
                  // Toggle: collect-clicked-words mode. When ON, the injected
                  // JS preventDefault()s link clicks and ships clicked words
                  // to Dart over the WiktCollect channel.
                  ValueListenableBuilder<bool>(
                    valueListenable: _wiktCollectMode,
                    builder: (_, on, __) => IconButton(
                      tooltip: on
                          ? 'Collect mode ON — links disabled; clicks append words'
                          : 'Collect mode OFF',
                      icon: Icon(
                        on ? Icons.touch_app : Icons.touch_app_outlined,
                        size: 20,
                        color: on ? Colors.amber : null,
                      ),
                      onPressed: () {
                        _wiktCollectMode.value = !on;
                        // Push the new flag into every open dialog2 (the
                        // listener reads it at click time, so this is enough
                        // — no re-injection needed).
                        for (final e in _dialog2Controllers.entries) {
                          if (_isWiktionaryUrl(_dialog2Urls[e.key])) {
                            _pushWiktCollectMode(e.value);
                          }
                        }
                      },
                    ),
                  ),
                  ValueListenableBuilder<List<String>>(
                    valueListenable: _wiktCollectedWords,
                    builder: (_, words, __) => Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          tooltip: 'Review collected words (${words.length})',
                          icon: const Icon(Icons.list_alt, size: 20),
                          onPressed: () => _showWiktCollectedDialog(ctx),
                        ),
                        if (words.isNotEmpty)
                          Positioned(
                            right: 4,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                              child: Text(
                                words.length > 99 ? '99+' : '${words.length}',
                                style: const TextStyle(color: Colors.white, fontSize: 9, height: 1),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (_isFilmotUrl(url)) ...[
                  IconButton(
                    tooltip: 'Capture subtitle (with context, translate, send to lookup)',
                    icon: Icon(Icons.subtitles, size: 20),
                    onPressed: () => _captureFilmotSubtitle(ctx, controller),
                  ),
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
                    onPressed: () => _saveCurrentFilmotVideo(dialogId, controller),
                  ),
                ],
                IconButton(
                  tooltip: 'Minimize',
                  icon: const Icon(Icons.minimize, size: 20),
                  onPressed: () {
                    _minimizedDialog2s.add(dialogId);
                    _everMinimizedDialog2s.add(dialogId); // Mark as ever minimized
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    // Clear minimized state when manually closing
                    _minimizedDialog2s.remove(dialogId);
                    // Stop media + JS *before* popping while the platform view
                    // is still attached — `.then` cleanup may run after detach.
                    _shutdownDialogWebView(controller);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
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
        ),
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
    _dialog2ScaffoldKeys.remove(dialogId);
    if (mounted) setState(() {});
    _bumpMinimizedVersion();
  }

  /// Shows a SnackBar inside `dialogId`'s ScaffoldMessenger if one is alive,
  /// otherwise falls back to the root messenger. Necessary because dialog2
  /// routes cover the underlying Scaffold — root SnackBars render behind the
  /// dialog and the user never sees them.
  void _showDialog2SnackBar(String? dialogId, String message,
      {Duration duration = const Duration(seconds: 2)}) {
    final state = (dialogId != null)
        ? _dialog2ScaffoldKeys[dialogId]?.currentState
        : null;
    final snack = SnackBar(content: Text(message), duration: duration);
    if (state != null) {
      state.showSnackBar(snack);
    } else if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(snack);
    }
  }

  // ---------- Filmot helpers ----------

  bool _isFilmotUrl(String? url) {
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    return host.endsWith('filmot.com');
  }

  bool _isWiktionaryUrl(String? url) {
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    return host.endsWith('.wiktionary.org') || host == 'wiktionary.org';
  }

  /// JS the WebView runs on every Wiktionary page load. Defines a single
  /// document-level click listener (capture phase) that reads the global
  /// `__cupWiktCollectActive` flag at click time — so flipping the toggle
  /// takes effect without re-injecting. Sends the clicked word to Dart via
  /// the `WiktCollect` channel, and preventDefault()s link navigation.
  static const String _wiktCollectJs = r'''
(function () {
  if (window.__cupWiktInstalled) return;
  window.__cupWiktInstalled = true;
  window.__cupWiktCollectActive = window.__cupWiktCollectActive || false;

  function wordAt(target, x, y) {
    // Prefer an explicit selection if the user double-tapped to select.
    try {
      var sel = window.getSelection && window.getSelection();
      if (sel && sel.toString && sel.toString().trim()) {
        return sel.toString().trim().split(/\s+/)[0];
      }
    } catch (e) {}
    // Otherwise use the caret position at the click point to extract one word.
    var node = null, offset = 0;
    if (document.caretRangeFromPoint) {
      var r = document.caretRangeFromPoint(x, y);
      if (r) { node = r.startContainer; offset = r.startOffset; }
    } else if (document.caretPositionFromPoint) {
      var p = document.caretPositionFromPoint(x, y);
      if (p) { node = p.offsetNode; offset = p.offset; }
    }
    if (node && node.nodeType === 3) {
      var t = node.textContent || '';
      var s = offset, e = offset;
      var re = /[\p{L}\p{N}\-']/u;
      while (s > 0 && re.test(t[s - 1])) s--;
      while (e < t.length && re.test(t[e])) e++;
      var w = t.substring(s, e).trim();
      if (w) return w;
    }
    // Last resort: the clicked element's text (single word only).
    var txt = (target && (target.innerText || target.textContent) || '').trim();
    return txt.split(/\s+/)[0] || '';
  }

  document.addEventListener('click', function (ev) {
    if (!window.__cupWiktCollectActive) return;
    // Block link navigation + any other default click handling.
    ev.preventDefault();
    ev.stopPropagation();
    ev.stopImmediatePropagation();
    var w = wordAt(ev.target, ev.clientX, ev.clientY);
    if (w && window.WiktCollect && window.WiktCollect.postMessage) {
      try { window.WiktCollect.postMessage(w); } catch (e) {}
    }
  }, true);

  // Visual cue: a tiny banner so the user knows clicks are being captured.
  function syncBanner() {
    var id = '__cup-wikt-banner';
    var el = document.getElementById(id);
    if (window.__cupWiktCollectActive) {
      if (!el) {
        el = document.createElement('div');
        el.id = id;
        el.style.cssText =
          'position:fixed;top:0;left:0;right:0;z-index:2147483647;'
          + 'background:#f59e0b;color:#000;font:600 12px/1.6 system-ui;'
          + 'text-align:center;padding:2px 8px;pointer-events:none;';
        el.textContent = 'Collect mode — links disabled, clicks add to word list';
        (document.body || document.documentElement).appendChild(el);
      }
    } else if (el) {
      el.remove();
    }
  }
  // Poll-light: keep the banner in sync if the flag is flipped while the
  // page is loaded. Cheap (every 500 ms, no DOM work when state matches).
  setInterval(syncBanner, 500);
  syncBanner();
})();
''';

  void _pushWiktCollectMode(WebViewController c) {
    final on = _wiktCollectMode.value;
    try {
      c.runJavaScript('window.__cupWiktCollectActive = $on;');
    } catch (_) {}
  }

  void _handleWiktCollectMessage(String word) {
    final cleaned = word.trim();
    if (cleaned.isEmpty) return;
    final list = List<String>.from(_wiktCollectedWords.value);
    // Append even if duplicate — the user can dedup in the review dialog.
    // (Most language-study notes want each occurrence recorded.)
    list.add(cleaned);
    _wiktCollectedWords.value = list;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('wiktCollectedWords', list);
    });
    // Mirror the running list onto the system clipboard after every capture
    // so the user can paste the latest accumulated list anywhere without
    // opening the review dialog first. Pipe-separated to match the review
    // dialog's "Copy" button format (`words.join('|')`).
    Clipboard.setData(ClipboardData(text: list.join('|')));
  }

  void _persistWiktCollectedWords() {
    final snapshot = List<String>.from(_wiktCollectedWords.value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('wiktCollectedWords', snapshot);
    });
  }

  void _showWiktCollectedDialog(BuildContext rootCtx) {
    showDialog(
      context: rootCtx,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ValueListenableBuilder<List<String>>(
            valueListenable: _wiktCollectedWords,
            builder: (_, words, __) {
              final joined = words.join('|');
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Collected words (${words.length})',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                  ),
                  // Joined-output preview (the actual thing the user wants to
                  // copy). Read-only TextField so they can also long-press to
                  // select a subset.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: TextEditingController(text: joined),
                      readOnly: true,
                      maxLines: 3,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        labelText: 'Joined output ( | separated )',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // The list itself — each word has a remove button.
                  Flexible(
                    child: words.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('No words collected yet. Turn on collect mode and tap words.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: words.length,
                            itemBuilder: (_, i) => ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: SizedBox(
                                width: 28,
                                child: Text('${i + 1}.', textAlign: TextAlign.right),
                              ),
                              title: Text(words[i]),
                              trailing: IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  final next = List<String>.from(words)..removeAt(i);
                                  _wiktCollectedWords.value = next;
                                  _persistWiktCollectedWords();
                                },
                              ),
                            ),
                          ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.delete_sweep, size: 18),
                          label: const Text('Clear all'),
                          onPressed: words.isEmpty
                              ? null
                              : () async {
                                  final confirm = await showDialog<bool>(
                                    context: ctx,
                                    builder: (c) => AlertDialog(
                                      content: Text('Clear all ${words.length} collected words?'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    _wiktCollectedWords.value = <String>[];
                                    _persistWiktCollectedWords();
                                  }
                                },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Dedup'),
                          onPressed: words.isEmpty
                              ? null
                              : () {
                                  final seen = <String>{};
                                  final next = <String>[];
                                  for (final w in words) {
                                    if (seen.add(w)) next.add(w);
                                  }
                                  _wiktCollectedWords.value = next;
                                  _persistWiktCollectedWords();
                                },
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                          onPressed: words.isEmpty
                              ? null
                              : () async {
                                  await Clipboard.setData(ClipboardData(text: joined));
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(content: Text('Copied ${words.length} words'), duration: const Duration(seconds: 1)),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
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

          // --- (c) Currently-playing video bar ---
          // Insert a block+save bar above the player. Filmot wraps #player
          // (an iframe) in #playerTop, which uses Bootstrap's
          // embed-responsive-16by9 — that gives the iframe `position:absolute`
          // inside its parent, so inserting a sibling there makes the bar
          // invisible. We anchor on #playerTop instead (or fall back to
          // #playerparrent's first child) and insert in the normal flow.
          var playerEl = document.getElementById('player');
          if (playerEl) {
            var anchor = document.getElementById('playerTop') || playerEl.parentNode;
            var anchorParent = anchor && anchor.parentNode;
            var prev = anchor && anchor.previousElementSibling;
            var pBar = (prev && prev.classList && prev.classList.contains('__cup_player_bar')) ? prev : null;
            if (!pBar && anchorParent) {
              pBar = document.createElement('div');
              pBar.className = '__cup_player_bar';
              pBar.style.cssText = 'display:flex;gap:6px;align-items:center;padding:6px 8px;font-size:13px;background:#fffbe6;border:1px solid #e0c060;border-radius:4px;margin:6px 0';
              var pLabel = document.createElement('span');
              pLabel.className = '__cup_player_channel_label';
              pLabel.style.cssText = 'flex:1;color:#444;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
              pBar.appendChild(pLabel);
              var pBlock = document.createElement('button');
              pBlock.textContent = '🚫 Block channel';
              pBlock.title = 'Blacklist this channel';
              pBlock.style.cssText = 'padding:2px 8px;font-size:11px;border:1px solid #888;background:#fee;cursor:pointer;border-radius:3px;line-height:1.2';
              pBlock.onclick = function(e) {
                e.preventDefault(); e.stopPropagation();
                var vid = currentVideoId();
                var ch = vid ? (window.__cupitorVideoChannel || {})[vid] : '';
                if (!ch) { setText(pLabel, '(no channel resolved yet)'); return; }
                bridge({action:'blockChannel', channel: ch});
              };
              pBar.appendChild(pBlock);
              var pSave = document.createElement('button');
              pSave.textContent = '💾 Save';
              pSave.title = 'Save video URL';
              pSave.style.cssText = 'padding:2px 8px;font-size:11px;border:1px solid #888;background:#efe;cursor:pointer;border-radius:3px;line-height:1.2';
              pSave.onclick = function(e) {
                e.preventDefault(); e.stopPropagation();
                var vid = currentVideoId();
                if (!vid) return;
                var ch = (window.__cupitorVideoChannel || {})[vid] || '';
                bridge({action:'saveVideo', url:'https://www.youtube.com/watch?v=' + vid, channel: ch, title: document.title || ''});
                pSave.textContent = '✅ Saved';
                setTimeout(function(){ pSave.textContent = '💾 Save'; }, 1500);
              };
              pBar.appendChild(pSave);
              anchorParent.insertBefore(pBar, anchor);
            }
            // Refresh label / record channel-seen for the player's current video.
            var pVid = currentVideoId();
            var pLbl = pBar && pBar.querySelector('.__cup_player_channel_label');
            if (pLbl) {
              if (!pVid) {
                setText(pLbl, '(no video)');
              } else {
                var pCh = map[pVid];
                if (pCh === undefined) {
                  setText(pLbl, '(resolving channel…)');
                  unknownIds.push(pVid);
                } else if (pCh === '') {
                  setText(pLbl, '(channel unknown)');
                } else {
                  setText(pLbl, pCh);
                  seenChannels[pCh] = true;
                }
              }
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
              if (an.id === 'player') return true;
              // Skip the bars we insert ourselves
              if (an.className === '__cup_bar' || an.className === '__cup_player_bar' || an.className === '__cup_channel_label') continue;
              if (an.querySelector && (an.querySelector('[id^="vcard_"]') || an.querySelector('#player') || an.querySelector('a[href*="/channel/"]') || an.querySelector('a[href*="youtube.com/@"]'))) return true;
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
          // Annotate now that the iframe is in the DOM — this is what makes
          // the player-bar (block / save buttons) actually appear when the
          // iframe was added after the page's initial parse.
          scheduleAnnotate();
          var srcMo = new MutationObserver(function(){
            if (ifr.src === lastCheckedSrc) return;
            lastCheckedSrc = ifr.src;
            autoSkipIfBlacklisted('iframe-src');
            // Refresh the player-bar channel label for the new video.
            scheduleAnnotate();
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
      _showDialog2SnackBar(dialogId, 'Blacklisted: $channel');
    } else if (action == 'saveVideo') {
      final url = msg['url']?.toString() ?? '';
      if (url.isEmpty) {
        _showDialog2SnackBar(dialogId, 'Could not detect a video URL on this page');
        return;
      }
      final title = msg['title']?.toString() ?? '';
      if (_savedVideos.any((e) => e['url'] == url)) {
        _showDialog2SnackBar(dialogId, 'Already saved: ${title.isNotEmpty ? title : url}');
        return;
      }
      _savedVideos.add({
        'url': url,
        'channel': msg['channel']?.toString() ?? '',
        'title': title,
        'savedAt': DateTime.now().toIso8601String(),
      });
      _saveSavedVideos();
      _showDialog2SnackBar(dialogId,
          'Saved: ${title.isNotEmpty ? title : url} (${_savedVideos.length} total)');
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
  // Long-lived translator pool keyed by "src-tgt" so the snippet bridge
  // doesn't pay the open/close + model-check cost per cue. Closed in dispose.
  final Map<String, mlkit.OnDeviceTranslator> _translatorPool = {};

  Future<mlkit.OnDeviceTranslator?> _getOrOpenTranslator(String src, String tgt) async {
    final key = '$src-$tgt';
    final cached = _translatorPool[key];
    if (cached != null) return cached;
    final sl = _toMlKitLang(src);
    final tl = _toMlKitLang(tgt);
    if (sl == null || tl == null) return null;
    final mm = mlkit.OnDeviceTranslatorModelManager();
    if (!await mm.isModelDownloaded(sl.bcpCode)) await mm.downloadModel(sl.bcpCode);
    if (!await mm.isModelDownloaded(tl.bcpCode)) await mm.downloadModel(tl.bcpCode);
    final t = mlkit.OnDeviceTranslator(sourceLanguage: sl, targetLanguage: tl);
    _translatorPool[key] = t;
    return t;
  }

  /// Page → Dart translation bridge for snippet.js. Payload:
  ///   { id: <int>, text: <string>, source: <ISO>, target: <ISO> }
  /// Tries the Google translate endpoint first (sentence-level quality,
  /// works without per-language model downloads). On network / HTTP error,
  /// falls back to on-device ML Kit (offline, slower first-use because of
  /// the ~30 MB per-language model download). Result is delivered to the
  /// page via window.__cupTranslated(id, result).
  Future<void> _handleTranslateRequest(JavaScriptMessage msg) async {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; } catch (_) { return; }
    final id = req['id'];
    final text = (req['text'] as String? ?? '').trim();
    final src = (req['source'] as String? ?? 'sv').trim();
    final tgt = (req['target'] as String? ?? 'en').trim();
    if (id == null || text.isEmpty) return;

    String? result;
    String? errMsg;
    // Path 1: Google translate API (free, public).
    try {
      result = await _translateText(text, src, tgt);
    } catch (e) {
      errMsg = 'api: $e';
    }
    // Path 2: ML Kit fallback (on-device).
    if (result == null) {
      try {
        final tr = await _getOrOpenTranslator(src, tgt);
        if (tr != null) result = await tr.translateText(text);
        else errMsg = (errMsg ?? '') + '; mlkit: language unsupported';
      } catch (e) {
        errMsg = (errMsg ?? '') + '; mlkit: $e';
      }
    }
    final js = result != null
        ? 'window.__cupTranslated && window.__cupTranslated($id, ${jsonEncode(result)});'
        : 'window.__cupTranslated && window.__cupTranslated($id, null, ${jsonEncode(errMsg ?? 'translate failed')});';
    try { _controller.runJavaScript(js); } catch (_) {}
  }

  // Maps our ISO-639-1 codes to ML Kit's TranslateLanguage enum. Returns null
  // if the language isn't supported on-device.
  mlkit.TranslateLanguage? _toMlKitLang(String code) {
    switch (code.toLowerCase()) {
      case 'sv': return mlkit.TranslateLanguage.swedish;
      case 'es': return mlkit.TranslateLanguage.spanish;
      case 'en': return mlkit.TranslateLanguage.english;
      case 'de': return mlkit.TranslateLanguage.german;
      case 'fr': return mlkit.TranslateLanguage.french;
      case 'it': return mlkit.TranslateLanguage.italian;
      case 'pt': return mlkit.TranslateLanguage.portuguese;
      case 'nl': return mlkit.TranslateLanguage.dutch;
      case 'no': return mlkit.TranslateLanguage.norwegian;
      case 'da': return mlkit.TranslateLanguage.danish;
      case 'fi': return mlkit.TranslateLanguage.finnish;
      case 'pl': return mlkit.TranslateLanguage.polish;
      case 'ru': return mlkit.TranslateLanguage.russian;
      case 'ja': return mlkit.TranslateLanguage.japanese;
      case 'zh': return mlkit.TranslateLanguage.chinese;
      case 'ko': return mlkit.TranslateLanguage.korean;
      case 'ar': return mlkit.TranslateLanguage.arabic;
      case 'hi': return mlkit.TranslateLanguage.hindi;
      case 'tr': return mlkit.TranslateLanguage.turkish;
      default: return null;
    }
  }

  /// Translates `text` using Android/iOS ML Kit on-device. Downloads the
  /// required language models on first use (one-time, ~30MB per language).
  /// Works offline once the models are present.
  Future<String> _translateOnDevice(String text, String sourceLang, String targetLang) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw 'On-device translation requires Android or iOS';
    }
    final sl = _toMlKitLang(sourceLang);
    final tl = _toMlKitLang(targetLang);
    if (sl == null || tl == null) {
      throw 'Unsupported language for ML Kit: $sourceLang→$targetLang';
    }
    final mm = mlkit.OnDeviceTranslatorModelManager();
    if (!await mm.isModelDownloaded(sl.bcpCode)) {
      await mm.downloadModel(sl.bcpCode);
    }
    if (!await mm.isModelDownloaded(tl.bcpCode)) {
      await mm.downloadModel(tl.bcpCode);
    }
    final translator = mlkit.OnDeviceTranslator(sourceLanguage: sl, targetLanguage: tl);
    try {
      return await translator.translateText(text);
    } finally {
      await translator.close();
    }
  }

  /// Translates a list of lines into the target language, preserving the list
  /// order and length. Uses Google if `preferOnDevice` is false (auto-falls
  /// back to on-device on failure); uses ML Kit directly when true. Empty
  /// input lines come back as empty strings.
  Future<List<String>> _translateLines(
    List<String> lines,
    String sourceLang,
    String targetLang, {
    required bool preferOnDevice,
  }) async {
    final out = List<String>.filled(lines.length, '');
    if (lines.isEmpty) return out;
    if (preferOnDevice) {
      // Open one translator and reuse it for the whole batch.
      final sl = _toMlKitLang(sourceLang);
      final tl = _toMlKitLang(targetLang);
      if (sl == null || tl == null) throw 'Unsupported language for ML Kit: $sourceLang→$targetLang';
      final mm = mlkit.OnDeviceTranslatorModelManager();
      if (!await mm.isModelDownloaded(sl.bcpCode)) await mm.downloadModel(sl.bcpCode);
      if (!await mm.isModelDownloaded(tl.bcpCode)) await mm.downloadModel(tl.bcpCode);
      final translator = mlkit.OnDeviceTranslator(sourceLanguage: sl, targetLanguage: tl);
      try {
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trim().isEmpty) continue;
          out[i] = await translator.translateText(lines[i]);
        }
        return out;
      } finally {
        await translator.close();
      }
    }
    // Google path — N parallel HTTP calls in batches of 6. On any individual
    // failure, fall back to on-device for that line (and the rest).
    const concurrency = 6;
    Object? googleErr;
    for (var i = 0; i < lines.length; i += concurrency) {
      final end = (i + concurrency < lines.length) ? i + concurrency : lines.length;
      final futures = <Future<void>>[];
      for (var j = i; j < end; j++) {
        final idx = j;
        if (lines[idx].trim().isEmpty) continue;
        futures.add(() async {
          try {
            out[idx] = await _translateText(lines[idx], sourceLang, targetLang);
          } catch (e) {
            googleErr = e;
          }
        }());
      }
      await Future.wait(futures);
      if (googleErr != null) break;
    }
    if (googleErr != null) {
      // One or more failed via Google — finish the rest on-device.
      final pending = <int>[];
      for (var k = 0; k < lines.length; k++) {
        if (out[k].isEmpty && lines[k].trim().isNotEmpty) pending.add(k);
      }
      if (pending.isNotEmpty) {
        final fallback = await _translateLines(
          pending.map((i) => lines[i]).toList(),
          sourceLang, targetLang,
          preferOnDevice: true,
        );
        for (var k = 0; k < pending.length; k++) {
          out[pending[k]] = fallback[k];
        }
      }
    }
    return out;
  }

  /// Translates `text` via Google's public unauthenticated endpoint. Returns
  /// the translation as a single string (segments rejoined). Throws on error.
  Future<String> _translateText(String text, String sourceLang, String targetLang) async {
    final uri = Uri.parse(
      'https://translate.googleapis.com/translate_a/single'
      '?client=gtx&sl=$sourceLang&tl=$targetLang&dt=t'
      '&q=${Uri.encodeQueryComponent(text)}'
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw 'HTTP ${resp.statusCode}';
    }
    final body = jsonDecode(resp.body) as List;
    final segments = body[0] as List;
    final out = StringBuffer();
    for (final seg in segments) {
      if (seg is List && seg.isNotEmpty && seg[0] != null) {
        out.write(seg[0].toString());
      }
    }
    return out.toString();
  }

  // ---------- YouTube subtitle download ----------

  /// Pulls a YouTube video id out of any of the URL forms we support
  /// (`/watch?v=…`, `/shorts/…`, `/embed/…`, `/live/…`, `youtu.be/…`). Returns
  /// null if the input doesn't look like a YouTube URL/id at all.
  String? _extractYouTubeVideoId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    // Bare 11-char id (what users sometimes paste from the share menu).
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(trimmed)) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') {
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(seg)) return seg;
    }
    if (host.endsWith('youtube.com') || host.endsWith('youtube-nocookie.com')) {
      final v = uri.queryParameters['v'];
      if (v != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(v)) return v;
      // /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>
      for (final pat in const ['shorts', 'embed', 'live', 'v']) {
        final idx = uri.pathSegments.indexOf(pat);
        if (idx >= 0 && idx + 1 < uri.pathSegments.length) {
          final cand = uri.pathSegments[idx + 1];
          if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(cand)) return cand;
        }
      }
    }
    return null;
  }

  // ---------- YouTube subtitle download ----------

  /// Lists available caption tracks via `youtubedl-android` (Android) or a
  /// `yt-dlp` subprocess (macOS). yt-dlp handles the PO-token wall on its
  /// side, so we don't see the 0-byte responses we got from every in-app
  /// HTTP/WebView attempt.
  Future<Map<String, dynamic>> _fetchYouTubeCaptionTracks(String videoId) async {
    if (!await YtDlpService.isAvailable()) {
      throw YtDlpService.installHint();
    }
    final result = await YtDlpService.listTracks(
      'https://www.youtube.com/watch?v=$videoId',
    );
    return {
      'title': result.title,
      'tracks': result.tracks.map((t) => t.toMap()).toList(),
    };
  }

  /// Downloads the chosen caption track via yt-dlp and parses it.
  /// `baseUrl` is unused (only kept for signature compatibility with the
  /// old WebView path); yt-dlp constructs whatever URL it needs internally.
  Future<List<Map<String, dynamic>>> _fetchCaptionsJson3({
    required String baseUrl,
    required String videoId,
    required String languageCode,
    required String kind,
  }) async {
    final sub = await YtDlpService.downloadSubtitle(
      videoUrl: 'https://www.youtube.com/watch?v=$videoId',
      languageCode: languageCode,
      kind: kind,
    );
    if (sub.body.isEmpty) {
      throw 'yt-dlp returned an empty body for $languageCode'
          '${kind == 'asr' ? ' (auto)' : ''}';
    }
    final List<Map<String, dynamic>> lines = switch (sub.format) {
      'json3' => await compute(_parseYtJson3Captions, sub.body),
      'vtt'   => await compute(_parseVttCaptions, sub.body),
      _       => await compute(_parseYtJson3Captions, sub.body),
    };
    if (lines.isEmpty) {
      throw 'yt-dlp returned ${sub.body.length}B (${sub.format}) but parsed 0 lines';
    }
    return lines;
  }

  /// Picks the default caption track to highlight in the picker. Preference
  /// order: manual track for current `_selectedLanguage` → any manual track
  /// → auto-generated track for current `_selectedLanguage` → first track.
  int _defaultCaptionTrackIndex(List<Map<String, dynamic>> tracks) {
    bool isManual(Map<String, dynamic> t) => (t['kind'] as String? ?? '') != 'asr';
    bool matchesLang(Map<String, dynamic> t) =>
        (t['languageCode'] as String? ?? '').toLowerCase() == _selectedLanguage.toLowerCase();
    for (var i = 0; i < tracks.length; i++) {
      if (isManual(tracks[i]) && matchesLang(tracks[i])) return i;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (isManual(tracks[i])) return i;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (matchesLang(tracks[i])) return i;
    }
    return 0;
  }

  /// Modal busy overlay used while awaiting an HTTP/parse step. The progress
  /// indicator is shown alongside `message`; the dialog isn't dismissible so
  /// the caller can `pop()` it from a known root navigator after the future
  /// resolves.
  void _showBusyOverlay(BuildContext ctx, String message) {
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 16),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }

  void _dismissBusyOverlay(BuildContext ctx) {
    if (!mounted) return;
    Navigator.of(ctx, rootNavigator: true).pop();
  }

  /// Entry point wired to the closed-captions icon in dialog1's header.
  /// Prompts for a URL → fetches caption tracks → picker → downloads + parses
  /// the chosen track → opens the full-file dialog. Every long step shows a
  /// dismissible busy overlay so the rest of the app remains interactive
  /// (HTTP + parse are awaited, so the UI thread is never blocked).
  Future<void> _startYouTubeSubtitleDownload(BuildContext ctx) async {
    // Pre-fill from clipboard if it looks like a YouTube URL — common case
    // is the user just copied the link from the YouTube share sheet.
    String initial = '';
    try {
      final clip = await Clipboard.getData('text/plain');
      final t = (clip?.text ?? '').trim();
      if (_extractYouTubeVideoId(t) != null) initial = t;
    } catch (_) {}
    if (!mounted) return;

    final urlCtrl = TextEditingController(text: initial);
    final urlInput = await showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('YouTube subtitles'),
        content: TextField(
          controller: urlCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://www.youtube.com/watch?v=…  or  video id',
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (v) => Navigator.of(dctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(urlCtrl.text.trim()),
            child: const Text('Fetch'),
          ),
        ],
      ),
    );
    urlCtrl.dispose();
    if (urlInput == null || urlInput.isEmpty) return;
    final videoId = _extractYouTubeVideoId(urlInput);
    if (videoId == null) {
      _showCaptureError('Not a YouTube URL',
          'Couldn\'t recognize a YouTube video id in:\n\n$urlInput');
      return;
    }
    if (!mounted) return;

    _showBusyOverlay(ctx, 'Loading caption list…');
    Map<String, dynamic> meta;
    try {
      meta = await _fetchYouTubeCaptionTracks(videoId);
    } catch (e) {
      _dismissBusyOverlay(ctx);
      _showCaptureError('Could not load captions', '$e');
      return;
    }
    _dismissBusyOverlay(ctx);

    final tracks = (meta['tracks'] as List).cast<Map<String, dynamic>>();
    if (tracks.isEmpty) {
      _showCaptureError('No captions',
          'This video has no caption tracks (neither manual nor auto-generated).');
      return;
    }
    if (!mounted) return;

    final pickedIdx = await _pickCaptionTrack(ctx, tracks);
    if (pickedIdx == null) return;
    final picked = tracks[pickedIdx];
    if (!mounted) return;

    _showBusyOverlay(ctx, 'Downloading captions…');
    List<Map<String, dynamic>> lines;
    try {
      lines = await _fetchCaptionsJson3(
        // `baseUrl` is only set on the legacy macOS WebView path; the Android
        // yt-dlp path never populates it (and `_fetchCaptionsJson3` doesn't
        // read it). Default to empty so a missing field doesn't crash.
        baseUrl: (picked['baseUrl'] as String?) ?? '',
        videoId: videoId,
        languageCode: (picked['languageCode'] as String?) ?? '',
        kind: (picked['kind'] as String?) ?? '',
      );
    } catch (e) {
      _dismissBusyOverlay(ctx);
      _showCaptureError('Could not download captions', '$e');
      return;
    }
    _dismissBusyOverlay(ctx);

    if (lines.isEmpty) {
      _showCaptureError('Empty captions',
          'The selected track returned no lines.');
      return;
    }
    if (!mounted) return;

    _showFullSubtitleDialog(
      ctx,
      lines: lines,
      sourceLang: (picked['languageCode'] as String?) ?? _selectedLanguage,
      videoUrl: 'https://www.youtube.com/watch?v=$videoId',
      videoId: videoId,
      videoTitle: (meta['title'] as String?) ?? '',
    );
  }

  /// Caption-track picker. Default-selects the track returned by
  /// `_defaultCaptionTrackIndex`. Auto-generated tracks are labeled inline so
  /// the user can spot them without expanding the row.
  Future<int?> _pickCaptionTrack(
      BuildContext ctx, List<Map<String, dynamic>> tracks) async {
    int selected = _defaultCaptionTrackIndex(tracks);
    return showDialog<int>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) => AlertDialog(
          title: const Text('Pick caption track'),
          content: SizedBox(
            width: 360,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: tracks.length,
                itemBuilder: (_, i) {
                  final t = tracks[i];
                  final isAsr = (t['kind'] as String? ?? '') == 'asr';
                  final name = (t['name'] as String? ?? '').trim();
                  final lang = (t['languageCode'] as String? ?? '').trim();
                  final label = [
                    if (name.isNotEmpty) name,
                    if (lang.isNotEmpty) '[$lang]',
                    if (isAsr) '(auto-generated)',
                  ].join(' ');
                  return RadioListTile<int>(
                    value: i,
                    groupValue: selected,
                    onChanged: (v) { if (v != null) setStateDialog(() => selected = v); },
                    title: Text(label.isEmpty ? lang : label),
                    dense: true,
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(selected),
              child: const Text('Download'),
            ),
          ],
        ),
      ),
    );
  }

  /// Full-file capture dialog: shows the entire cue list (virtualized) with
  /// a Translate-all action and Send-to-lookup. Translation is batched
  /// (~30 cues per request) so a typical episode finishes in seconds rather
  /// than minutes, with a progress counter + Cancel.
  void _showFullSubtitleDialog(
    BuildContext ctx, {
    required List<Map<String, dynamic>> lines,
    required String sourceLang,
    required String videoUrl,
    required String videoId,
    required String videoTitle,
  }) {
    final originals = lines.map((l) => (l['text'] as String)).toList();
    List<String> translation = List<String>.filled(lines.length, '');
    bool translating = false;
    bool translated = false;
    bool cancelRequested = false;
    int progressDone = 0;
    int progressTotal = lines.length;
    String? translateError;

    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) {
          final screenW = MediaQuery.of(dctx2).size.width;
          final dialogW = (screenW - 32).clamp(320.0, 1100.0);
          Future<void> startTranslate() async {
            setStateDialog(() {
              translating = true;
              cancelRequested = false;
              translateError = null;
              progressDone = 0;
              progressTotal = originals.length;
            });
            try {
              final result = await _translateLinesBatched(
                originals,
                sourceLang,
                'en',
                onProgress: (done, total) {
                  if (!mounted) return;
                  setStateDialog(() {
                    progressDone = done;
                    progressTotal = total;
                  });
                },
                isCancelled: () => cancelRequested,
              );
              if (!mounted) return;
              setStateDialog(() {
                translation = result;
                translating = false;
                translated = !cancelRequested;
              });
            } catch (e) {
              if (!mounted) return;
              setStateDialog(() {
                translateError = '$e';
                translating = false;
              });
            }
          }

          String tsFmt(double s) {
            final m = (s ~/ 60).toString().padLeft(2, '0');
            final sec = (s % 60).floor().toString().padLeft(2, '0');
            return '$m:$sec';
          }

          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        videoTitle.isNotEmpty ? videoTitle : 'YouTube subtitles',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${originals.length} lines  ·  $sourceLang → en',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    cancelRequested = true;
                    Navigator.of(dctx).pop();
                  },
                ),
              ],
            ),
            content: SizedBox(
              width: dialogW,
              height: MediaQuery.of(dctx2).size.height * 0.6,
              child: Column(
                children: [
                  if (translating)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 12),
                          Expanded(child: Text(
                            'Translating $progressDone / $progressTotal…',
                            style: const TextStyle(fontSize: 12),
                          )),
                          TextButton(
                            onPressed: () => setStateDialog(() => cancelRequested = true),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ),
                  if (translateError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('Translation failed: $translateError',
                          style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                    ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ListView.builder(
                        itemCount: originals.length,
                        itemBuilder: (_, i) {
                          final tr = i < translation.length ? translation[i] : '';
                          final showTr = translated && tr.isNotEmpty;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    tsFmt((lines[i]['start'] as num).toDouble()),
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Text(originals[i], style: const TextStyle(fontSize: 13)),
                                      if (showTr)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text(tr,
                                              style: TextStyle(
                                                  fontSize: 12, color: Colors.blue.shade800)),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: translating ? null : startTranslate,
                child: Text(translated ? 'Re-translate' : 'Translate'),
              ),
              TextButton(
                onPressed: translating ? null : () {
                  // Build the same payload shape `_jsCodeForCapturedSubtitle`
                  // expects: parallel `lines` + `translation` arrays keyed by
                  // index/start/end.
                  final outLines = <Map<String, dynamic>>[];
                  final outTr = <Map<String, dynamic>>[];
                  for (var i = 0; i < lines.length; i++) {
                    outLines.add({
                      'index': i,
                      'start': lines[i]['start'],
                      'end': lines[i]['end'],
                      'text': originals[i],
                    });
                    outTr.add({
                      'index': i,
                      'start': lines[i]['start'],
                      'end': lines[i]['end'],
                      'text': i < translation.length ? translation[i] : '',
                    });
                  }
                  Navigator.of(dctx).pop();
                  _sendCapturedSubtitleToDialog1(<String, dynamic>{
                    'query': '',
                    'sourceLang': sourceLang,
                    'targetLang': 'en',
                    'matchIndex': 0,
                    'lines': outLines,
                    'translation': outTr,
                    'videoUrl': videoUrl,
                    'videoId': videoId,
                    'videoTitle': videoTitle,
                  });
                },
                child: const Text('Send to lookup'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Translates a full-file cue list by joining cues into batches separated
  /// by newlines (cheap, terminator that Google's translator preserves in
  /// practice), translating each batch in one round trip, and splitting the
  /// response back. Falls back to per-line translation for any batch whose
  /// line count comes back wrong. 4-way concurrent across batches.
  ///
  /// Yields cooperatively after every batch completes so a long-running
  /// translation never starves the event loop / UI thread.
  Future<List<String>> _translateLinesBatched(
    List<String> lines,
    String sourceLang,
    String targetLang, {
    required void Function(int done, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final out = List<String>.filled(lines.length, '');
    if (lines.isEmpty) return out;

    // Pack indices into batches by character budget — Google's `gtx` accepts
    // ~5 KB per `q=` once URL-encoded, so cap at ~3500 raw chars to leave
    // headroom for multi-byte characters.
    const maxChars = 3500;
    const batchSep = '\n';
    final batches = <List<int>>[];
    var current = <int>[];
    var currentChars = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      final cost = lines[i].length + batchSep.length;
      if (current.isNotEmpty && currentChars + cost > maxChars) {
        batches.add(current);
        current = [];
        currentChars = 0;
      }
      current.add(i);
      currentChars += cost;
    }
    if (current.isNotEmpty) batches.add(current);

    Future<void> translateBatch(List<int> batch) async {
      final joined = batch.map((i) => lines[i]).join(batchSep);
      try {
        final translated = await _translateText(joined, sourceLang, targetLang);
        final parts = translated.split(batchSep);
        if (parts.length == batch.length) {
          for (var k = 0; k < batch.length; k++) {
            out[batch[k]] = parts[k];
          }
          return;
        }
        // Line-count drift — Google occasionally merges/splits cues. Fall
        // back to per-line for this batch only so the rest of the file
        // still benefits from batching.
      } catch (_) {}
      for (final i in batch) {
        if (isCancelled()) return;
        try {
          out[i] = await _translateText(lines[i], sourceLang, targetLang);
        } catch (_) {
          out[i] = '';
        }
      }
    }

    var done = 0;
    const concurrency = 4;
    for (var bi = 0; bi < batches.length; bi += concurrency) {
      if (isCancelled()) break;
      final group = batches.sublist(
        bi,
        (bi + concurrency).clamp(0, batches.length),
      );
      await Future.wait(group.map(translateBatch));
      done += group.fold<int>(0, (a, b) => a + b.length);
      onProgress(done, lines.length);
      // Yield to the event loop between batch groups so the UI stays smooth.
      await Future<void>.delayed(Duration.zero);
    }
    return out;
  }

  /// Surfaces capture-time errors above the open Filmot dialog2 via a small
  /// AlertDialog — the root ScaffoldMessenger's snackbars sit *behind* the
  /// dialog and look like "nothing happened" to the user.
  void _showCaptureError(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360, maxWidth: 520),
          child: SingleChildScrollView(
            child: SelectableText(
              message,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () { Clipboard.setData(ClipboardData(text: message)); },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Scrapes the open Filmot detail page's subtitle list (`#subtitlesIn`),
  /// finds the line that matches the URL's search query, and opens a dialog
  /// where the user can adjust before/after context, translate, and hand
  /// the result to dialog1 for word-level lookup.
  Future<void> _captureFilmotSubtitle(BuildContext ctx, WebViewController controller) async {
    const js = r'''
      (function(){
        var query = '';
        try {
          // Filmot search URL: /search/%22word%22/N → first segment after
          // /search/ is the (URI-encoded) quoted query.
          var m = location.pathname.match(/\/search\/([^/]+)/);
          if (m) {
            var raw = decodeURIComponent(m[1]);
            // decodeURIComponent already converts %22 → ", so this strips
            // the literal surrounding quotes left from the filmot syntax.
            raw = raw.replace(/^["']+|["']+$/g, '');
            query = raw;
          }
        } catch(e){}
        // Identify the currently-playing video. iframe.src is the most
        // reliable signal because filmot's Next/Prev swaps the src in place.
        function ytId(href) {
          if (!href) return null;
          var pats = [
            /youtube\.com\/embed\/([A-Za-z0-9_-]{6,})/,
            /youtube\.com\/watch\?v=([A-Za-z0-9_-]{6,})/,
            /youtu\.be\/([A-Za-z0-9_-]{6,})/,
            /[?&]v=([A-Za-z0-9_-]{6,})/,
            /\/sidebyside\/([A-Za-z0-9_-]{6,})/
          ];
          for (var p = 0; p < pats.length; p++) { var mmId = href.match(pats[p]); if (mmId) return mmId[1]; }
          return null;
        }
        var videoId = null;
        var ifr = document.getElementById('player');
        if (ifr && ifr.src) videoId = ytId(ifr.src);
        if (!videoId) {
          var ax = document.querySelector('#divVideoDetails a[href*="watch?v="], #linktoyoutube a[href*="watch?v="]');
          if (ax) videoId = ytId(ax.href || ax.getAttribute('href') || '');
        }
        if (!videoId) {
          var pmSb = location.pathname.match(/\/sidebyside\/([A-Za-z0-9_-]{6,})/);
          if (pmSb) videoId = pmSb[1];
        }
        var videoTitle = '';
        var titleEl = document.querySelector('#divVideoDetails .col-6');
        if (titleEl) videoTitle = (titleEl.textContent || '').trim().split(/\s*[\r\n]+/)[0].slice(0, 200);
        if (!videoTitle) videoTitle = (document.title || '').trim();
        var divs = document.querySelectorAll('#subtitlesIn > div[id^="s"]');
        var lines = [];
        for (var i = 0; i < divs.length; i++) {
          var div = divs[i];
          var a = div.querySelector('a[href*="jtt("]');
          var ts = 0;
          if (a) {
            var mm = a.getAttribute('href').match(/jtt\((\d+),([\d.]+)\)/);
            if (mm) ts = parseFloat(mm[2]);
          }
          var clone = div.cloneNode(true);
          var anc = clone.querySelector('a');
          if (anc) anc.parentNode.removeChild(anc);
          var text = (clone.textContent || '').replace(/ /g, ' ').replace(/\s+/g, ' ').trim();
          var idM = div.id.match(/^s(\d+)/);
          lines.push({ i: idM ? parseInt(idM[1], 10) : i, ts: ts, t: text });
        }
        // --- Robust match resolution ---
        // Filmot does fuzzy/stemmed search across word forms (esp. in highly
        // inflected languages like Swedish), so an exact substring lookup on
        // the query word often misses. Try a cascade of strategies and remember
        // which one fired so the UI can flag fallbacks.
        function stripDiacritics(s) {
          try { return s.normalize('NFD').replace(/[̀-ͯ]/g, ''); }
          catch(e) { return s; }
        }
        function findMatch(lines, query) {
          if (!query) return { idx: -1, reason: 'no-query' };
          var q = query.toLowerCase();
          // 1) Exact substring.
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].t.toLowerCase().indexOf(q) !== -1) return { idx: i, reason: 'exact' };
          }
          // 2) Diacritic-insensitive substring (e.g. "atgang" matches "åtgång").
          var qs = stripDiacritics(q);
          if (qs !== q) {
            for (var i2 = 0; i2 < lines.length; i2++) {
              if (stripDiacritics(lines[i2].t.toLowerCase()).indexOf(qs) !== -1) return { idx: i2, reason: 'normalized' };
            }
          }
          // 3) Stemmed prefix — drop trailing chars to catch inflections
          // ("vakna" should match "vaknade", "vaknar", "vaknat", "vakn-up", ...).
          for (var trim = 1; trim <= 4 && q.length - trim >= 3; trim++) {
            var qt = stripDiacritics(q.substring(0, q.length - trim));
            for (var i3 = 0; i3 < lines.length; i3++) {
              if (stripDiacritics(lines[i3].t.toLowerCase()).indexOf(qt) !== -1) return { idx: i3, reason: 'stem(-' + trim + ')' };
            }
          }
          // 4) Word-overlap — for multi-word queries, find the line containing
          // the largest number of query tokens.
          var tokens = q.split(/\s+/).filter(function(w){ return w.length > 1; });
          if (tokens.length > 1) {
            var best = -1, bestN = 0;
            for (var i4 = 0; i4 < lines.length; i4++) {
              var lt = stripDiacritics(lines[i4].t.toLowerCase());
              var n = 0;
              for (var t = 0; t < tokens.length; t++) {
                if (lt.indexOf(stripDiacritics(tokens[t])) !== -1) n++;
              }
              if (n > bestN) { bestN = n; best = i4; }
            }
            if (best >= 0 && bestN >= Math.max(1, Math.ceil(tokens.length / 2))) {
              return { idx: best, reason: 'tokens(' + bestN + '/' + tokens.length + ')' };
            }
          }
          return { idx: -1, reason: 'no-match' };
        }
        var resolved = findMatch(lines, query);
        var matchIdx = resolved.idx;
        var matchReason = resolved.reason;
        // 5) Time-based fallback — anchor at whatever subtitle is playing right now.
        if (matchIdx < 0 && lines.length) {
          try {
            var ct = null;
            if (window.player && typeof window.player.getCurrentTime === 'function') {
              ct = window.player.getCurrentTime();
            }
            if (typeof ct === 'number' && ct >= 0) {
              for (var ti = 0; ti < lines.length; ti++) {
                var nxt = (ti + 1 < lines.length) ? lines[ti + 1].ts : (lines[ti].ts + 3);
                if (ct >= lines[ti].ts && ct < nxt) { matchIdx = ti; matchReason = 'currentTime'; break; }
              }
              if (matchIdx < 0) { matchIdx = lines.length - 1; matchReason = 'currentTime'; }
            }
          } catch(e) {}
        }
        // 6) Last resort: first non-empty line.
        if (matchIdx < 0) {
          for (var fi = 0; fi < lines.length; fi++) {
            if ((lines[fi].t || '').trim().length) { matchIdx = fi; matchReason = 'firstNonEmpty'; break; }
          }
        }
        return JSON.stringify({
          query: query,
          lines: lines,
          matchIdx: matchIdx,
          matchReason: matchReason,
          videoId: videoId || '',
          videoUrl: videoId ? ('https://www.youtube.com/watch?v=' + videoId) : '',
          videoTitle: videoTitle
        });
      })();
    ''';
    // Retry the scrape a few times — when filmot navigates Next/Prev it
    // does a full page load and its own subtitle population may finish
    // slightly after onPageFinished. Without a retry the user often gets
    // an empty result on the first tap right after navigation.
    Map<String, dynamic>? data;
    Object? lastErr;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final raw = await controller.runJavaScriptReturningResult(js);
        var s = raw.toString();
        if (s.startsWith('"') && s.endsWith('"')) s = jsonDecode(s) as String;
        final d = jsonDecode(s) as Map<String, dynamic>;
        final lines = (d['lines'] as List?) ?? const [];
        if (lines.isNotEmpty) { data = d; break; }
        // Empty page DOM — keep the last seen `d` in case all retries miss.
        data = d;
      } catch (e) {
        lastErr = e;
      }
      if (attempt < 3) await Future.delayed(const Duration(milliseconds: 500));
    }
    if (data == null) {
      _showCaptureError('Capture failed', 'Could not read the subtitle list.\n\n$lastErr');
      return;
    }
    final linesRaw = (data['lines'] as List?) ?? const [];
    final query = (data['query'] ?? '').toString();
    var matchIdx = (data['matchIdx'] as num?)?.toInt() ?? -1;
    final matchReason = (data['matchReason'] ?? '').toString();
    final videoUrl = (data['videoUrl'] ?? '').toString();
    final videoId = (data['videoId'] ?? '').toString();
    final videoTitle = (data['videoTitle'] ?? '').toString();
    if (linesRaw.isEmpty) {
      _showCaptureError(
        'No subtitle lines',
        'Filmot has not loaded any subtitle lines on this page yet '
        '(or this video has no captions). Wait a moment for the page '
        'to settle and try again — if the player works, the captions '
        'usually appear shortly after.',
      );
      return;
    }
    // The JS-side cascade should always have set matchIdx to something
    // sensible when lines exist. If not (all-empty subtitle text, etc.),
    // anchor on the first line so the user can still adjust manually.
    if (matchIdx < 0) matchIdx = 0;
    // Build structured {index, start, end, text} for every line in the page.
    // End-time = next line's start (within the captured range we'll slice).
    // For the absolute last line we add a 3s tail.
    final allLines = <Map<String, dynamic>>[];
    for (var i = 0; i < linesRaw.length; i++) {
      final l = linesRaw[i] as Map<String, dynamic>;
      allLines.add({
        'index': (l['i'] as num?)?.toInt() ?? i,
        'start': (l['ts'] as num?)?.toDouble() ?? 0.0,
        'text': (l['t'] ?? '').toString(),
        'end': 0.0,
      });
    }
    for (var i = 0; i < allLines.length; i++) {
      if (i + 1 < allLines.length) {
        allLines[i]['end'] = allLines[i + 1]['start'];
      } else {
        allLines[i]['end'] = (allLines[i]['start'] as double) + 3.0;
      }
    }
    if (!mounted) return;
    _showSubtitleCaptureDialog(
      ctx,
      query: query,
      allLines: allLines,
      matchIdx: matchIdx,
      matchReason: matchReason,
      videoUrl: videoUrl,
      videoId: videoId,
      videoTitle: videoTitle,
    );
  }

  void _showSubtitleCaptureDialog(BuildContext ctx, {
    required String query,
    required List<Map<String, dynamic>> allLines,
    required int matchIdx,
    required String matchReason,
    required String videoUrl,
    required String videoId,
    required String videoTitle,
  }) {
    // matchIdx is mutable — the user can change the anchor line manually
    // via the picker below.
    int currentMatchIdx = matchIdx;
    String currentMatchReason = matchReason;
    int before = 2;
    int after = 2;
    // Parallel to the captured-range slice. Empty list = not translated yet.
    List<String> translation = const [];
    String? translationSource; // 'google' | 'on-device'
    bool translating = false;
    bool preferOnDevice = false;
    String? translateError;
    // Memo key — if before/after changes after a translation, invalidate it.
    String? translatedFor;
    // Per-line editable text. Keyed by `allLines` index so original edits
    // survive slider changes (the underlying `allLines` entry persists).
    // Translation controllers are keyed the same way but rebuilt whenever
    // the range changes (translation itself is range-scoped and invalidates).
    final Map<int, TextEditingController> origCtrls = {};
    final Map<int, TextEditingController> trCtrls = {};
    void disposeTrCtrls() { for (final c in trCtrls.values) { c.dispose(); } trCtrls.clear(); }
    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) {
          final start = (currentMatchIdx - before).clamp(0, allLines.length - 1);
          final end = (currentMatchIdx + after).clamp(0, allLines.length - 1);
          final captured = allLines.sublist(start, end + 1);
          final capturedKey = '$start-$end';
          if (translatedFor != null && translatedFor != capturedKey) {
            // Range changed — stale translation; clear it.
            translation = const [];
            translatedFor = null;
            translationSource = null;
            disposeTrCtrls();
          }
          // Ensure an original-text controller for each currently-visible line.
          // Stable key = allLines index, so a controller (and its edited text)
          // is retained when the slider expands/contracts the visible range.
          for (final line in captured) {
            final idx = line['index'] as int;
            origCtrls.putIfAbsent(idx, () => TextEditingController(text: (line['text'] as String)));
          }
          // After a translate(), build a parallel set of translation controllers
          // (one per visible line). Done once per fresh translation.
          if (translation.length == captured.length && translatedFor == capturedKey && trCtrls.isEmpty) {
            for (var i = 0; i < captured.length; i++) {
              final idx = captured[i]['index'] as int;
              trCtrls[idx] = TextEditingController(text: translation[i]);
            }
          }
          final matchTs = (allLines[currentMatchIdx]['start'] as num?)?.toDouble() ?? 0;
          final mmss = '${(matchTs ~/ 60).toString().padLeft(2,'0')}:${(matchTs % 60).floor().toString().padLeft(2,'0')}';
          final screenW = MediaQuery.of(dctx2).size.width;
          final dialogW = (screenW - 32).clamp(320.0, 1100.0);
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        query.isEmpty ? mmss : '"$query"  ·  $mmss',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (videoTitle.isNotEmpty || videoUrl.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            videoTitle.isNotEmpty ? videoTitle : videoUrl,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontWeight: FontWeight.normal),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(dctx).pop(),
                ),
              ],
            ),
            content: SizedBox(
              width: dialogW,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 60, child: Text('Anchor')),
                        Expanded(
                          child: Text(
                            '${(allLines[currentMatchIdx]['start'] as num).toStringAsFixed(1)}s  ·  '
                            '${(allLines[currentMatchIdx]['text'] as String)}',
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.list, size: 16),
                          label: const Text('Change'),
                          onPressed: () => _pickAnchorLine(
                            dctx2,
                            allLines: allLines,
                            current: currentMatchIdx,
                            onPicked: (i) => setStateDialog(() {
                              currentMatchIdx = i;
                              currentMatchReason = 'manual';
                            }),
                          ),
                        ),
                      ],
                    ),
                    if (currentMatchReason.isNotEmpty && currentMatchReason != 'exact' && currentMatchReason != 'normalized')
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(
                          query.isEmpty
                              ? 'Anchored via ${currentMatchReason} (no /search/ query in URL — pick manually if needed)'
                              : 'No exact match for "$query" — anchored via ${currentMatchReason}. Pick manually if this isn\'t right.',
                          style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(children: [
                      const SizedBox(width: 110, child: Text('Lines Before')),
                      _lineCountPicker(value: before, onChanged: (v) => setStateDialog(() => before = v)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      const SizedBox(width: 110, child: Text('Lines After')),
                      _lineCountPicker(value: after, onChanged: (v) => setStateDialog(() => after = v)),
                    ]),
                    const Divider(),
                    Text('Captured (${end - start + 1} lines)', style: Theme.of(dctx2).textTheme.titleSmall),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 220),
                      width: double.infinity,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(4)),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: List.generate(captured.length, (i) {
                            final line = captured[i];
                            final idx = line['index'] as int;
                            final ctrl = origCtrls[idx]!;
                            return _editableLineRow(
                              ts: (line['start'] as num).toDouble(),
                              controller: ctrl,
                              onChanged: (v) { line['text'] = v; },
                            );
                          }),
                        ),
                      ),
                    ),
                    if (translateError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(translateError!, style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                      ),
                    Row(
                      children: [
                        Checkbox(
                          value: preferOnDevice,
                          onChanged: (v) => setStateDialog(() => preferOnDevice = v ?? false),
                        ),
                        const Expanded(child: Text('Use on-device translation (ML Kit, offline)', style: TextStyle(fontSize: 12))),
                      ],
                    ),
                    if (translation.isNotEmpty) ...[
                      Text(
                        'Translation ($_selectedLanguage → en)${translationSource != null ? "  ·  via $translationSource" : ""}',
                        style: Theme.of(dctx2).textTheme.titleSmall,
                      ),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 220),
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(border: Border.all(color: Colors.blue), borderRadius: BorderRadius.circular(4)),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(captured.length, (i) {
                              final line = captured[i];
                              final idx = line['index'] as int;
                              final ctrl = trCtrls[idx];
                              if (ctrl == null) return const SizedBox.shrink();
                              return _editableLineRow(
                                ts: (line['start'] as num).toDouble(),
                                controller: ctrl,
                                onChanged: (v) {
                                  if (i < translation.length) translation[i] = v;
                                },
                              );
                            }),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: translating || captured.isEmpty ? null : () async {
                  setStateDialog(() { translating = true; translateError = null; });
                  try {
                    final perLine = await _translateLines(
                      captured.map((l) => (l['text'] as String)).toList(),
                      _selectedLanguage,
                      'en',
                      preferOnDevice: preferOnDevice,
                    );
                    setStateDialog(() {
                      translation = perLine;
                      translatedFor = capturedKey;
                      translationSource = preferOnDevice ? 'on-device (ML Kit)' : 'google (with on-device fallback)';
                      translating = false;
                    });
                  } catch (e) {
                    setStateDialog(() {
                      translateError = 'Translation failed: $e';
                      translating = false;
                    });
                  }
                },
                child: Text(translating ? 'Translating…' : (preferOnDevice ? 'Translate (on-device)' : 'Translate')),
              ),
              TextButton(
                onPressed: captured.isEmpty ? null : () {
                  Navigator.of(dctx).pop();
                  // Build a translation array parallel to `captured` so the
                  // page can zip them positionally — empty strings preserve
                  // the alignment when a line wasn't translatable.
                  final translationArr = <Map<String, dynamic>>[];
                  for (var i = 0; i < captured.length; i++) {
                    translationArr.add({
                      'index': captured[i]['index'],
                      'start': captured[i]['start'],
                      'end': captured[i]['end'],
                      'text': i < translation.length ? translation[i] : '',
                    });
                  }
                  _sendCapturedSubtitleToDialog1(<String, dynamic>{
                    'query': query,
                    'sourceLang': _selectedLanguage,
                    'targetLang': 'en',
                    'matchIndex': currentMatchIdx - start,
                    'lines': captured,
                    'translation': translationArr,
                    'videoUrl': videoUrl,
                    'videoId': videoId,
                    'videoTitle': videoTitle,
                  });
                },
                child: const Text('Send to lookup'),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      for (final c in origCtrls.values) { c.dispose(); }
      for (final c in trCtrls.values) { c.dispose(); }
      origCtrls.clear();
      trCtrls.clear();
    });
  }

  /// Opens a list of all subtitle lines on the page and lets the user pick
  /// one as the anchor for the captured range. Used when the auto-matcher's
  /// pick is wrong (fuzzy match landed on the wrong line, no /search/ query
  /// in URL, etc.). Supports a quick text filter.
  void _pickAnchorLine(BuildContext ctx, {
    required List<Map<String, dynamic>> allLines,
    required int current,
    required ValueChanged<int> onPicked,
  }) {
    String filter = '';
    showDialog(
      context: ctx,
      builder: (pctx) => StatefulBuilder(
        builder: (pctx2, setSt) {
          final f = filter.trim().toLowerCase();
          final visible = <int>[];
          for (var i = 0; i < allLines.length; i++) {
            final t = (allLines[i]['text'] as String).trim();
            if (t.isEmpty) continue;
            if (f.isEmpty || t.toLowerCase().contains(f)) visible.add(i);
          }
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            title: const Text('Pick anchor line'),
            content: SizedBox(
              width: 560,
              height: 480,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Filter…',
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                    ),
                    onChanged: (v) => setSt(() => filter = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, vi) {
                        final i = visible[vi];
                        final l = allLines[i];
                        final ts = (l['start'] as num).toDouble();
                        return ListTile(
                          dense: true,
                          selected: i == current,
                          leading: SizedBox(
                            width: 44,
                            child: Text(
                              '${ts.toStringAsFixed(1)}s',
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            ),
                          ),
                          title: Text(l['text'] as String, style: const TextStyle(fontSize: 12)),
                          onTap: () {
                            Navigator.of(pctx).pop();
                            onPicked(i);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(pctx).pop(), child: const Text('Cancel')),
            ],
          );
        },
      ),
    );
  }

  /// One editable row: a timestamp label and a borderless TextField that
  /// fills the rest of the width. The line and its timestamp stay 1:1 so
  /// edits don't break SRT mapping.
  Widget _editableLineRow({
    required double ts,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 4),
            child: Text(
              '${ts.toStringAsFixed(1)}s',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(fontSize: 13),
            maxLines: null,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            ),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  /// A compact dropdown that lets the user pick a number in 0..15. Used in
  /// the capture dialog instead of sliders so the value is selectable.
  Widget _lineCountPicker({required int value, required ValueChanged<int> onChanged}) {
    return DropdownButton<int>(
      value: value.clamp(0, 15),
      isDense: true,
      items: List.generate(16, (i) => DropdownMenuItem<int>(value: i, child: Text('$i'))),
      onChanged: (v) { if (v != null) onChanged(v); },
    );
  }

  Future<void> _saveCurrentFilmotVideo(String dialogId, WebViewController controller) async {
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
        _showDialog2SnackBar(dialogId, 'No video URL found on screen');
        return;
      }
      _handleFilmotMessage(dialogId, jsonEncode({
        'action': 'saveVideo',
        'url': url,
        'channel': data['channel']?.toString() ?? '',
        'title': data['title']?.toString() ?? '',
      }));
    } catch (e) {
      _showDialog2SnackBar(dialogId, 'Save failed: $e');
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
        case 'GET':
          response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
          break;
        case 'PUT':
          response = await http.put(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        case 'POST':
          response = await http.post(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        case 'PATCH':
          response = await http.patch(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        case 'DELETE':
          response = await http.delete(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        default:
          // Previously fell through to GET, which silently turned PATCH /
          // DELETE writes into reads — proxy returned 200 with the
          // current resource and the actual write never happened.
          throw Exception('GitHubProxy: unsupported HTTP method "$method"');
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
        ..addJavaScriptChannel('TtsBridge', onMessageReceived: _handleTtsBridge)
        ..addJavaScriptChannel('MediaState', onMessageReceived: _handleMediaStateBridge)
        ..addJavaScriptChannel('AudioBridge', onMessageReceived: _handleAudioBridge)
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
              // Polyfill window.speechSynthesis before the page tries to use
              // it. Safe to inject every page-finished — re-entry is gated.
              dialogController?.runJavaScript(_ttsPolyfillJs);
              // Media-key shim: forwards headset events to YT IFrame API and
              // reports YT player state back to native MediaSession.
              dialogController?.runJavaScript(_mediaKeysShimJs);
              // Activate the MediaSession while we're on our language page
              // (where the YT iframe lives). Other hosts deactivate so we
              // don't steal media keys from other apps in the background.
              final onLanguagePage = url.startsWith(_dialogUrl);
              _setMediaSessionActive(onLanguagePage);
              dialogController?.runJavaScript(jsCodeToFilterData(_currentDialogText));
              final pending = _pendingCapturedSubtitle;
              if (pending != null) {
                _pendingCapturedSubtitle = null;
                dialogController?.runJavaScript(_jsCodeForCapturedSubtitle(pending));
              }
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
      // Allow the dialog to extend behind the status / nav bars so it
      // covers the full screen height; otherwise the system insets clip
      // about ~50 px off the top + bottom on Android.
      useSafeArea: false,
      builder: (ctx) => ValueListenableBuilder<bool>(
        // Fullscreen toggle lives outside the outer State's setState scope
        // (this is a separate Navigator route), so we drive it from a notifier.
        valueListenable: _dialog1FullscreenNotifier,
        builder: (_, fullscreen, __) {
          final dialog = Dialog(
            // vertical: 0 in both modes — the user wants the dialog edge
            // to reach the top and bottom of the device. The non-
            // fullscreen mode keeps a tiny 1 % horizontal inset so the
            // close/minimize chrome sits inside the rounded corners.
            insetPadding: fullscreen
                ? EdgeInsets.zero
                : EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
            shape: fullscreen
                ? const RoundedRectangleBorder(borderRadius: BorderRadius.zero)
                : null,
            child: _buildDialog1Content(ctx, screenWidth, screenHeight),
          );
          if (!hasBeenMinimized) return dialog;
          // Custom barrier tap handler — minimizes instead of closing.
          return GestureDetector(
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
                  child: dialog,
                ),
              ),
            ),
          );
        },
      ),
    ).then((_) {
      // Dialog closed - but keep controller alive to avoid reloading.
      // Controller will be cleaned up only when app is disposed or language changes.
      // This prevents unnecessary reloads when reopening the dialog.
      _dialog1Visible = false;
      _dialog1FullscreenNotifier.value = false;
      // Notify the page running inside dialog1 that the dialog just
      // closed — useful for the language page to pause TTS, stop a
      // running clip, or persist state before the user comes back.
      // Dispatched as a CustomEvent on `window`; pages listen with
      //   window.addEventListener('cupitorDialog1Closed', ...)
      // The controller stays alive across opens, so a fresh listener
      // isn't required after every show.
      try {
        dialogController?.runJavaScript(
          "window.dispatchEvent(new CustomEvent('cupitorDialog1Closed'));",
        );
      } catch (_) { /* page may not have finished loading — ignore */ }
    });
  }

  Widget _buildDialog1Content(BuildContext ctx, double screenWidth, double screenHeight) {
    return Container(
      width: screenWidth,
      height: screenHeight,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Theme(
              // Compact the icon row so the title bar takes less vertical space.
              // Default IconButton is 48×48 (tap target) — drop padding + use
              // shrinkWrap to land around ~32×32 per button.
              data: Theme.of(ctx).copyWith(
                iconButtonTheme: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    padding: const EdgeInsets.all(4),
                    minimumSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    setState(() => _dialog1Minimized = false);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
                const Spacer(),  
                IconButton(
                  tooltip: 'Download YouTube subtitles (translate, send to lookup)',
                  icon: const Icon(Icons.closed_caption_outlined, size: 20),
                  onPressed: () => _startYouTubeSubtitleDownload(ctx),
                ),
                GestureDetector(
                  // Long-press = enter continuous-listen mode (until next tap
                  // to stop). Tap = original one-shot voice input. Mirrors the
                  // main app bar's mic at the bottom of this file.
                  //
                  // Android-only: the inner IconButton must NOT set tooltip:
                  // Flutter's Tooltip claims the touch long-press to show
                  // itself and, being the inner gesture detector, wins the
                  // arena over this outer onLongPress.
                  onLongPress: () {
                    if (Platform.isAndroid && !_isListening) {
                      HapticFeedback.mediumImpact();
                    }
                    _startContinuousVoiceCapture();
                  },
                  child: ValueListenableBuilder<bool>(
                    // The mic state changes async inside _speech callbacks, so
                    // the outer State's setState() doesn't repaint the dialog
                    // route — listen to the mirrored notifier instead.
                    valueListenable: _isListeningNotifier,
                    builder: (_, listening, __) => IconButton(
                      tooltip: Platform.isAndroid
                          ? null
                          : (listening
                              ? (_continuousVoiceActive ? 'Stop continuous capture' : 'Stop listening')
                              : 'Voice input (long-press for continuous)'),
                      icon: Icon(
                        listening ? Icons.mic : Icons.mic_none,
                        color: listening
                            ? (_continuousVoiceActive ? Colors.red : Colors.redAccent)
                            : null,
                      ),
                      onPressed: () {
                        if (_continuousVoiceActive) {
                          _stopContinuousVoiceCapture();
                        } else {
                          _toggleVoiceInput();
                        }
                      },
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload page (bypass cache)',
                  icon: Icon(Icons.refresh),
                  onPressed: () async {
                    // Clear HTTP cache so we actually pick up server changes —
                    // bare reload() honours cache headers and was returning
                    // stale pages. We stay on the same dialog route (no pop)
                    // and just rerun loadRequest against the current language URL.
                    final ctrl = dialogController;
                    if (ctrl == null) return;
                    try { await ctrl.clearCache(); } catch (_) {}
                    await ctrl.loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
                  },
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _dialog1FullscreenNotifier,
                  builder: (_, fullscreen, __) => IconButton(
                    tooltip: fullscreen ? 'Exit fullscreen' : 'Enter fullscreen',
                    icon: Icon(
                      fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      size: 20,
                    ),
                    onPressed: () => _dialog1FullscreenNotifier.value = !fullscreen,
                  ),
                ),
                IconButton(
                  tooltip: 'Minimize',
                  icon: const Icon(Icons.minimize, size: 20),
                  onPressed: () {
                    setState(() {
                      _dialog1Minimized = true;
                      _dialog1EverMinimized = true; // Mark as ever minimized
                    });
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    // Clear minimized state when manually closing
                    setState(() => _dialog1Minimized = false);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
              ],
              ),
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
      if (_showAppBar && _autoHideAppBar) {
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
              if (_showAppBar && _autoHideAppBar) {
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
            if (_showAppBar && _autoHideAppBar) {
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
            if (_showAppBar && _autoHideAppBar) {
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
        if (_showAppBar && _autoHideAppBar) {
          _showAppBarWithTimer();
        }
      }
    }
  }

  /// Starts the long-press dictation mode. Accumulates partial+final results
  /// into `_continuousTranscript` and auto-restarts the recognizer each time
  /// the underlying engine ends an utterance, until the user taps the mic to
  /// stop (or 5 minutes elapse as a safety net).
  Future<void> _startContinuousVoiceCapture() async {
    if (_continuousVoiceActive) return;
    // If a normal (one-shot) listen is in progress, cancel it first.
    if (_isListening) {
      try { await _speech.stop(); } catch (_) {}
    }
    _continuousTranscript.clear();
    _continuousPartial = '';
    _continuousVoiceActive = true;
    setState(() => _isListening = true);
    _isListeningNotifier.value = true;
    _showAppBarWithTimer();
    final started = await _initContinuousListen();
    if (!started) {
      _continuousVoiceActive = false;
      setState(() => _isListening = false);
      _isListeningNotifier.value = false;
      _showVoiceInputFallback();
    }
  }

  Future<bool> _initContinuousListen() async {
    try {
      final ok = await _speech.initialize(
        onStatus: (status) {
          // The speech_to_text plugin ends each utterance on its own; in
          // continuous mode we just restart listening as long as the user
          // still wants us listening.
          if (status == 'done' || status == 'notListening') {
            if (_continuousVoiceActive && mounted) {
              _restartContinuousListen();
            }
          }
        },
        onError: (e) {
          debugPrint('Continuous speech error: $e');
          if (_continuousVoiceActive && mounted) {
            _restartContinuousListen();
          }
        },
      );
      if (!ok) return false;
      await _speech.listen(
        localeId: _speechLocale(),
        partialResults: true,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 30),
        onResult: (result) {
          final words = result.recognizedWords;
          if (result.finalResult) {
            if (words.trim().isNotEmpty) {
              if (_continuousTranscript.isNotEmpty) _continuousTranscript.write(' ');
              _continuousTranscript.write(words.trim());
            }
            _continuousPartial = '';
          } else {
            _continuousPartial = words;
          }
        },
      );
      return true;
    } catch (e) {
      debugPrint('Continuous speech init failed: $e');
      return false;
    }
  }

  void _restartContinuousListen() {
    if (!_continuousVoiceActive) return;
    // Tiny delay so the plugin's previous session is fully torn down before
    // we kick off a new one. Without it, listen() occasionally throws.
    Future.delayed(const Duration(milliseconds: 200), () async {
      if (!_continuousVoiceActive) return;
      try {
        await _speech.listen(
          localeId: _speechLocale(),
          partialResults: true,
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 30),
          onResult: (result) {
            final words = result.recognizedWords;
            if (result.finalResult) {
              if (words.trim().isNotEmpty) {
                if (_continuousTranscript.isNotEmpty) _continuousTranscript.write(' ');
                _continuousTranscript.write(words.trim());
              }
              _continuousPartial = '';
            } else {
              _continuousPartial = words;
            }
          },
        );
      } catch (e) {
        debugPrint('Continuous restart failed: $e');
      }
    });
  }

  Future<void> _stopContinuousVoiceCapture() async {
    if (!_continuousVoiceActive) return;
    _continuousVoiceActive = false;
    try { await _speech.stop(); } catch (_) {}
    if (mounted) setState(() => _isListening = false);
    _isListeningNotifier.value = false;
    // Append any trailing partial that hadn't promoted to a final result yet.
    if (_continuousPartial.trim().isNotEmpty) {
      if (_continuousTranscript.isNotEmpty) _continuousTranscript.write(' ');
      _continuousTranscript.write(_continuousPartial.trim());
    }
    final transcript = _continuousTranscript.toString().trim();
    _continuousPartial = '';
    _continuousTranscript.clear();
    if (!mounted) return;
    if (transcript.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No speech captured'), duration: Duration(seconds: 2)),
      );
      return;
    }
    _showTranscriptDialog(transcript);
  }

  /// Opens a dialog that hosts the captured text in a WebView, with the
  /// same `clickable-word` wrapping (and CaptionHandler bridge) the main
  /// page uses — so tapping a word triggers the usual lookup flow.
  Future<void> _showTranscriptDialog(String transcript) async {
    final escaped = _htmlEscape(transcript);
    final utilsJs = await rootBundle.loadString('assets/js/utils.js');
    final html = '''
<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body { font-family: -apple-system, system-ui, sans-serif; font-size: 17px;
         line-height: 1.6; padding: 16px; color: #222; }
  .clickable-word { cursor: pointer; border-bottom: 1px dotted #888; }
  .clickable-word:active { background: #ffe082; }
</style>
</head><body><div id="transcript">$escaped</div>
<script>$utilsJs</script>
</body></html>
''';
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dctx) {
        late final WebViewController ctrl;
        ctrl = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setUserAgent(_userAgent)
          ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) {
            // Tap a word → main lookup flow.
            _openDialogWithWebview(msg.message.toString().replaceAll('"', ''));
          })
          ..loadHtmlString(html);
        final screenW = MediaQuery.of(dctx).size.width;
        final screenH = MediaQuery.of(dctx).size.height;
        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: screenW * 0.02, vertical: 24),
          child: SizedBox(
            width: screenW * 0.96,
            height: screenH * 0.85,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                  child: Row(
                    children: [
                      const Icon(Icons.mic, size: 18, color: Colors.red),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Captured speech', style: TextStyle(fontWeight: FontWeight.w600))),
                      IconButton(
                        tooltip: 'Copy text',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: transcript));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(dctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: WebViewWidget(controller: ctrl)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Minimal HTML escape — only needs to cover the characters that can
  /// terminate or escape attribute / element context.
  String _htmlEscape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
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

  // -------------------------------------------------------------------------
  // Headset / Bluetooth media-key bridge for dialog1
  //
  // Native MainActivity owns a MediaSessionCompat that, while active, claims
  // headset play/pause/next/prev. Each press is forwarded here over a
  // MethodChannel; we synthesise a `cupitorMediaKey` CustomEvent and inject it
  // into dialog1's WebView. The language page can listen for it directly to
  // run custom behavior — replay current item, jump to previous video in the
  // record queue, etc. Default behaviors (forward to YT IFrame API) are wired
  // by the small shim injected on every page load.
  // -------------------------------------------------------------------------
  void _setMediaSessionActive(bool active) {
    if (!Platform.isAndroid) return;
    if (active == _mediaSessionActive) return;
    _mediaSessionActive = active;
    _mediaKeysChannel.invokeMethod<void>('setActive', {'active': active});
  }

  void _setMediaSessionState({required bool playing, String? title, String? artist}) {
    if (!Platform.isAndroid) return;
    _mediaKeysChannel.invokeMethod<void>('setState', {
      'playing': playing,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
    });
  }

  void _dispatchMediaKeyToDialog1(String key) {
    final ctrl = dialogController;
    if (ctrl == null) return;
    final escaped = jsonEncode(key);
    ctrl.runJavaScript(
      "window.dispatchEvent(new CustomEvent('cupitorMediaKey', { detail: { key: $escaped } }));"
    );
  }

  /// Page → Dart: page reports its playback state so we can keep the system
  /// MediaSession (and therefore lockscreen / car / BT) in sync with what's
  /// actually playing.
  void _handleMediaStateBridge(JavaScriptMessage msg) {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; }
    catch (_) { return; }
    final playing = req['playing'] as bool? ?? false;
    final title = req['title'] as String?;
    final artist = req['artist'] as String?;
    _setMediaSessionState(playing: playing, title: title, artist: artist);
  }

  // ---- AudioBridge: persist manual-entry recordings on disk ----
  //
  // The dialog1 WebView can't write to the device file system itself, so the
  // editor's recorder pipes audio bytes (base64 data URL) through this bridge.
  // We save to <app_documents>/manual_audio/<id>.<ext> and hand back a
  // `file://...` URL. The reverse — loading audio for playback — returns the
  // bytes as a base64 data URL so JS can play them via `new Audio(...)` or
  // `URL.createObjectURL(blob)` without needing direct file:// access (which
  // Android WebView blocks for security).
  //
  // Wire format (JS → Flutter), JSON envelope:
  //   {op:'save',   rid, id, dataUrl}            → __cupAudio('save',   rid, fileUrl|null, err|null)
  //   {op:'load',   rid, url}                    → __cupAudio('load',   rid, dataUrl|null, err|null)
  //   {op:'delete', rid, url}                    → __cupAudio('delete', rid, true|false,   err|null)
  //
  // `rid` is a JS-supplied request id used only to resolve the corresponding
  // Promise on the JS side — the Dart side echoes it back unchanged.
  Future<Directory> _manualAudioDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/manual_audio');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeFileId(String id) {
    // Restrict to filename-safe characters; collapses anything weird from JS.
    return id.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  }

  String _extFromDataUrl(String dataUrl) {
    // data:audio/webm;codecs=opus;base64,XXXX → 'webm'.
    final m = RegExp(r'^data:audio/([a-zA-Z0-9.+-]+)').firstMatch(dataUrl);
    final raw = (m?.group(1) ?? 'webm').toLowerCase();
    // Strip codec descriptors after a `+` if any, keep core type.
    return raw.split('+').first;
  }

  /// Build the `file://...` URL we hand back to JS. We use a `cupitor-file://`
  /// prefix in addition to `file://` callers, but the canonical form is plain
  /// `file://<absolute path>`, since the user asked for "url like file://...".
  String _fileUrlForPath(String path) => 'file://$path';

  /// Map a `file://...` URL the WebView gave us back to an on-disk path,
  /// confined to our manual_audio directory (defensive — refuse paths outside
  /// it so a malicious page can't read random files).
  Future<File?> _resolveAudioUrl(String url) async {
    if (!url.startsWith('file://')) return null;
    final path = url.substring('file://'.length);
    final dir = await _manualAudioDir();
    final canonicalDir = dir.path.endsWith('/') ? dir.path : '${dir.path}/';
    if (!path.startsWith(canonicalDir)) return null;
    return File(path);
  }

  void _audioReply(String op, String rid, String? result, String? err) {
    // Stringify safely. result/err are short strings or JSON-encodable.
    final payload = jsonEncode({
      'op': op, 'rid': rid,
      if (result != null) 'result': result,
      if (err != null) 'error': err,
    });
    try {
      dialogController?.runJavaScript(
        'window.__cupAudio && window.__cupAudio($payload);',
      );
    } catch (_) {}
  }

  Future<void> _handleAudioBridge(JavaScriptMessage msg) async {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; }
    catch (_) { return; }
    final op = (req['op'] as String?) ?? '';
    final rid = (req['rid'] as String?) ?? '';
    try {
      if (op == 'save') {
        final id = _safeFileId((req['id'] as String?) ?? '');
        final dataUrl = (req['dataUrl'] as String?) ?? '';
        final comma = dataUrl.indexOf(',');
        if (id.isEmpty || !dataUrl.startsWith('data:') || comma < 0) {
          _audioReply('save', rid, null, 'bad-payload');
          return;
        }
        final ext = _extFromDataUrl(dataUrl);
        final bytes = base64Decode(dataUrl.substring(comma + 1));
        final dir = await _manualAudioDir();
        final f = File('${dir.path}/$id.$ext');
        await f.writeAsBytes(bytes, flush: true);
        _audioReply('save', rid, _fileUrlForPath(f.path), null);
      } else if (op == 'load') {
        final url = (req['url'] as String?) ?? '';
        final f = await _resolveAudioUrl(url);
        if (f == null || !await f.exists()) {
          _audioReply('load', rid, null, 'not-found');
          return;
        }
        final bytes = await f.readAsBytes();
        final ext = f.path.split('.').last.toLowerCase();
        final mime = ext == 'mp4' ? 'audio/mp4'
                   : ext == 'm4a' ? 'audio/mp4'
                   : ext == 'ogg' ? 'audio/ogg'
                   : ext == 'wav' ? 'audio/wav'
                   : ext == 'mp3' ? 'audio/mpeg'
                   : 'audio/webm';
        final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
        _audioReply('load', rid, dataUrl, null);
      } else if (op == 'delete') {
        final url = (req['url'] as String?) ?? '';
        final f = await _resolveAudioUrl(url);
        if (f != null && await f.exists()) await f.delete();
        _audioReply('delete', rid, 'ok', null);
      } else if (op == 'ensureMicPerm') {
        // Pre-flight for JS — let it know whether the Android `RECORD_AUDIO`
        // grant is in place (asking the user if not) BEFORE it calls
        // `navigator.mediaDevices.getUserMedia`. Without this, the first
        // tap-Record after install hits getUserMedia → silent rejection →
        // confusing "permission denied" alert, with no OS prompt ever
        // shown.
        //
        // ALSO release the mic from `speech_to_text` here. STT and the
        // WebView's `getUserMedia` both want to open `AudioRecord`; only
        // one can hold the source at a time. If STT is running (long-press
        // continuous capture left active) getUserMedia rejects with
        // `NotReadableError: Could not start audio source` until STT lets
        // go. Stopping it here is the right time — JS is about to record.
        await _releaseMicFromSpeechToText();
        final ok = await _ensureMicPermission();
        _audioReply('ensureMicPerm', rid, ok ? 'granted' : 'denied', null);
      } else if (op == 'recordStart') {
        // Native recording path: JS hands us an id, we open MediaRecorder
        // and write to <docs>/manual_audio/<id>.m4a directly. Bypasses the
        // WebView's getUserMedia entirely — same AudioRecord plumbing used
        // by speech_to_text and any native voice recorder. Released by
        // `recordStop` (keep the file) or `recordCancel` (delete it).
        final id = _safeFileId((req['id'] as String?) ?? '');
        if (id.isEmpty) { _audioReply('recordStart', rid, null, 'bad-id'); return; }
        await _releaseMicFromSpeechToText();
        final permOk = await _ensureMicPermission();
        if (!permOk) { _audioReply('recordStart', rid, null, 'permission-denied'); return; }
        final dir = await _manualAudioDir();
        final path = '${dir.path}/$id.m4a';
        try {
          final ok = await _permsChannel.invokeMethod<bool>(
            'startNativeRecording', {'path': path},
          );
          if (ok == true) {
            _audioReply('recordStart', rid, _fileUrlForPath(path), null);
          } else {
            _audioReply('recordStart', rid, null, 'start-failed');
          }
        } on PlatformException catch (e) {
          _audioReply('recordStart', rid, null, '${e.code}: ${e.message ?? ''}');
        }
      } else if (op == 'recordStop') {
        try {
          final path = await _permsChannel.invokeMethod<String>('stopNativeRecording');
          if (path == null) {
            _audioReply('recordStop', rid, null, 'no-recording');
          } else {
            _audioReply('recordStop', rid, _fileUrlForPath(path), null);
          }
        } on PlatformException catch (e) {
          _audioReply('recordStop', rid, null, '${e.code}: ${e.message ?? ''}');
        }
      } else if (op == 'recordCancel') {
        try {
          await _permsChannel.invokeMethod<void>('cancelNativeRecording');
          _audioReply('recordCancel', rid, 'ok', null);
        } on PlatformException catch (e) {
          _audioReply('recordCancel', rid, null, '${e.code}: ${e.message ?? ''}');
        }
      } else {
        _audioReply(op, rid, null, 'unknown-op');
      }
    } catch (e) {
      _audioReply(op, rid, null, e.toString());
    }
  }

  /// Default handlers + state pump injected on every dialog1 page load.
  /// - Forwards play/pause/next/previous/fast_forward/rewind to YouTube's
  ///   IFrame API (`window.ytPlayer`) when the page doesn't preventDefault.
  /// - Reflects YT player state changes to native MediaSessionCompat via the
  ///   `MediaState` channel so the lockscreen + Bluetooth display stay synced.
  static const String _mediaKeysShimJs = r'''
(function() {
  if (window.__cupitorMediaKeysInstalled) return;
  window.__cupitorMediaKeysInstalled = true;
  var bridge = window.MediaState;
  function postState() {
    if (!bridge || typeof bridge.postMessage !== 'function') return;
    var p = window.ytPlayer;
    var playing = !!window.ytPlaying;
    var title = '';
    try {
      if (p && typeof p.getVideoData === 'function') {
        var d = p.getVideoData();
        title = (d && d.title) || '';
      }
    } catch (e) {}
    if (!title) title = document.title || 'Cupitor';
    try { bridge.postMessage(JSON.stringify({ playing: playing, title: title })); } catch (e) {}
  }
  // Wrap onPlayerStateChange so we don't replace the page's handler. Any
  // future PLAYING / non-PLAYING transition pushes state.
  var origStateCb = window.onPlayerStateChange;
  window.onPlayerStateChange = function(ev) {
    try { if (typeof origStateCb === 'function') origStateCb(ev); } catch (e) {}
    setTimeout(postState, 0);
  };
  // Also poll briefly after install in case the player became ready earlier.
  var pollN = 0;
  var poll = setInterval(function() {
    pollN++;
    postState();
    if (pollN > 10) clearInterval(poll);
  }, 1000);

  // Default media-key behavior — fires only if the page didn't preventDefault.
  // The page may install its own listener via:
  //   window.addEventListener('cupitorMediaKey', function(e) { e.preventDefault(); … });
  window.addEventListener('cupitorMediaKey', function(ev) {
    if (ev.defaultPrevented) return;
    var key = ev.detail && ev.detail.key;
    var p = window.ytPlayer;
    if (!p) return;
    try {
      switch (key) {
        case 'play': p.playVideo(); break;
        case 'pause': p.pauseVideo(); break;
        case 'play_pause':
          if (window.ytPlaying) p.pauseVideo(); else p.playVideo();
          break;
        case 'fast_forward':
          if (typeof p.getCurrentTime === 'function')
            p.seekTo((p.getCurrentTime() || 0) + 10, true);
          break;
        case 'rewind':
          if (typeof p.getCurrentTime === 'function')
            p.seekTo(Math.max(0, (p.getCurrentTime() || 0) - 10), true);
          break;
        // next / previous have no sensible default for a single video —
        // leave them for the page to handle (record-queue navigation).
      }
    } catch (e) {}
    setTimeout(postState, 100);
  });
})();
''';

  // -------------------------------------------------------------------------
  // window.speechSynthesis bridge for dialog1
  //
  // Android WebView ships without the Web Speech Synthesis API — pages that
  // call `new SpeechSynthesisUtterance(...)` + `speechSynthesis.speak(...)`
  // silently no-op. macOS WKWebView has it natively, but we install the same
  // shim everywhere so utterance.onstart / .onend semantics are identical.
  //
  // The shim replaces `window.speechSynthesis` (and the Utterance constructor)
  // with objects that post a JSON envelope to the `TtsBridge` channel. Flutter
  // drives a queue against flutter_tts and pokes start/end/error callbacks
  // back into the page via runJavaScript on globals it exposed itself.
  // -------------------------------------------------------------------------
  static const String _ttsPolyfillJs = r'''
(function() {
  if (window.__cupitorTtsInstalled) return;
  window.__cupitorTtsInstalled = true;
  var bridge = window.TtsBridge;
  if (!bridge || typeof bridge.postMessage !== 'function') return;

  var pending = new Map();
  var nextId = 1;

  function post(obj) {
    try { bridge.postMessage(JSON.stringify(obj)); } catch (_) {}
  }

  function Utterance(text) {
    this.text = text == null ? '' : String(text);
    this.lang = document.documentElement.lang || '';
    this.voice = null;
    this.volume = 1.0;
    this.rate = 1.0;
    this.pitch = 1.0;
    this.onstart = null;
    this.onend = null;
    this.onerror = null;
    this.onpause = null;
    this.onresume = null;
    this.onmark = null;
    this.onboundary = null;
    var listeners = {};
    this.addEventListener = function(t, fn) { (listeners[t] = listeners[t] || []).push(fn); };
    this.removeEventListener = function(t, fn) {
      var arr = listeners[t]; if (!arr) return;
      var i = arr.indexOf(fn); if (i >= 0) arr.splice(i, 1);
    };
    this.dispatchEvent = function(ev) {
      var arr = listeners[ev.type]; if (!arr) return true;
      for (var i = 0; i < arr.length; i++) {
        try { arr[i].call(this, ev); } catch (_) {}
      }
      return true;
    };
  }
  window.SpeechSynthesisUtterance = Utterance;

  function fire(u, name, extra) {
    var handler = u['on' + name];
    if (typeof handler === 'function') {
      try { handler.call(u, Object.assign({ type: name, utterance: u }, extra || {})); } catch (_) {}
    }
    try {
      var ev = new Event(name);
      Object.assign(ev, extra || {});
      u.dispatchEvent(ev);
    } catch (_) {}
  }

  var synth = {
    paused: false,
    pending: false,
    speaking: false,
    onvoiceschanged: null,
    speak: function(u) {
      if (!u) return;
      var id = nextId++;
      pending.set(id, u);
      synth.speaking = true;
      synth.pending = pending.size > 1;
      post({
        type: 'speak',
        id: id,
        text: String(u.text || ''),
        lang: String(u.lang || ''),
        rate: Number(u.rate) || 1,
        pitch: Number(u.pitch) || 1,
        volume: Number(u.volume) || 1,
      });
    },
    cancel: function() {
      // Snapshot the utterances BEFORE clearing pending — Flutter has already
      // been told to stop, but the host's setCancelHandler only fires for the
      // active one. Without these synthetic `end` events the page's promise
      // chains (e.g. _speakWordBrowser.onend) wait the full safety timeout.
      var utterances = Array.from(pending.values());
      pending.clear();
      synth.speaking = false;
      synth.paused = false;
      synth.pending = false;
      post({ type: 'cancel' });
      utterances.forEach(function(u) {
        try { fire(u, 'end'); } catch (_) {}
      });
    },
    pause: function() { synth.paused = true; post({ type: 'pause' }); },
    resume: function() { synth.paused = false; post({ type: 'resume' }); },
    getVoices: function() { return []; },
    addEventListener: function() {},
    removeEventListener: function() {},
    dispatchEvent: function() { return true; },
  };

  window.__cupitorTtsStart = function(id) {
    var u = pending.get(id); if (!u) return;
    synth.speaking = true;
    fire(u, 'start');
  };
  window.__cupitorTtsEnd = function(id) {
    var u = pending.get(id); pending.delete(id);
    synth.pending = pending.size > 0;
    if (pending.size === 0) synth.speaking = false;
    if (!u) return;
    fire(u, 'end');
  };
  window.__cupitorTtsError = function(id, msg) {
    var u = pending.get(id); pending.delete(id);
    synth.pending = pending.size > 0;
    if (pending.size === 0) synth.speaking = false;
    if (!u) return;
    fire(u, 'error', { error: msg || 'tts-error' });
  };

  try {
    Object.defineProperty(window, 'speechSynthesis', {
      value: synth, writable: false, configurable: false,
    });
  } catch (_) {
    window.speechSynthesis = synth;
  }
})();
''';

  Future<void> _ensureDialog1Tts() async {
    if (_dialog1Tts != null) return;
    final tts = FlutterTts();
    _dialog1Tts = tts;
    try {
      // Speak/stop one utterance at a time and rely on these callbacks to
      // advance the queue. awaitSpeakCompletion would also work but blocks
      // the speak call — handlers keep us reactive to cancel().
      tts.setStartHandler(() {
        final id = _dialog1TtsActiveJsId;
        if (id != null) {
          dialogController?.runJavaScript('window.__cupitorTtsStart && window.__cupitorTtsStart($id);');
        }
      });
      tts.setCompletionHandler(() {
        _ttsFinishCurrent(error: null);
      });
      tts.setCancelHandler(() {
        // System cancelled (e.g. another app took audio focus). Treat as end.
        _ttsFinishCurrent(error: null);
      });
      tts.setErrorHandler((msg) {
        _ttsFinishCurrent(error: msg?.toString() ?? 'tts-error');
      });
    } catch (_) { /* best-effort */ }
  }

  void _ttsFinishCurrent({String? error}) {
    final id = _dialog1TtsActiveJsId;
    _dialog1TtsActiveJsId = null;
    _dialog1TtsBusy = false;
    if (id != null) {
      if (error == null) {
        dialogController?.runJavaScript('window.__cupitorTtsEnd && window.__cupitorTtsEnd($id);');
      } else {
        final esc = jsonEncode(error);
        dialogController?.runJavaScript('window.__cupitorTtsError && window.__cupitorTtsError($id, $esc);');
      }
    }
    _ttsPumpQueue();
  }

  Future<void> _ttsPumpQueue() async {
    if (_dialog1TtsBusy) return;
    if (_dialog1TtsQueue.isEmpty) return;
    final next = _dialog1TtsQueue.removeAt(0);
    _dialog1TtsBusy = true;
    _dialog1TtsActiveJsId = next['id'] as int;
    final tts = _dialog1Tts;
    if (tts == null) { _ttsFinishCurrent(error: 'tts-unavailable'); return; }
    try {
      final lang = (next['lang'] as String?)?.trim();
      if (lang != null && lang.isNotEmpty) {
        try { await tts.setLanguage(lang); } catch (_) {}
      }
      // Web rate is 0.1–10 with 1.0 = normal. flutter_tts rate on Android maps
      // 0.0–1.0 with ~0.5 being normal; iOS/macOS uses 0.0–1.0 with ~0.5
      // normal too. Halving keeps "normal" at "normal" and clamps to [0.1, 1.0].
      final webRate = (next['rate'] as num?)?.toDouble() ?? 1.0;
      final ttsRate = (webRate / 2.0).clamp(0.1, 1.0);
      try { await tts.setSpeechRate(ttsRate); } catch (_) {}
      final pitch = ((next['pitch'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
      try { await tts.setPitch(pitch); } catch (_) {}
      final volume = ((next['volume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
      try { await tts.setVolume(volume); } catch (_) {}
      await tts.speak((next['text'] as String?) ?? '');
    } catch (e) {
      _ttsFinishCurrent(error: e.toString());
    }
  }

  void _handleTtsBridge(JavaScriptMessage msg) {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; }
    catch (_) { return; }
    final type = req['type'] as String?;
    if (type == null) return;
    _ensureDialog1Tts();
    switch (type) {
      case 'speak':
        _dialog1TtsQueue.add(req);
        _ttsPumpQueue();
        break;
      case 'cancel':
        _dialog1TtsQueue.clear();
        _dialog1Tts?.stop();
        _ttsFinishCurrent(error: null);
        break;
      case 'pause':
        _dialog1Tts?.pause();
        break;
      case 'resume':
        // flutter_tts has no resume on Android — best-effort no-op.
        break;
    }
  }

  String jsCodeToFilterData(String text) {
    final escaped = text.replaceAll("'", "\\'");
    // Token is intentionally NOT passed here — GitHub API calls are proxied
    // through the GitHubProxy JavaScriptChannel so the token stays in Flutter.
    return "window.dispatchEvent(new CustomEvent('filterData', { detail: { text: '$escaped' } }));";
  }

  /// Builds the JS that fires a `capturedSubtitle` CustomEvent on the dialog1
  /// page. The page listens for this to handle multi-line subtitle captures
  /// distinctly from single-word lookups (`filterData`).
  ///
  /// Detail shape (SRT-reconstructable):
  /// ```
  /// {
  ///   query:       "<the matched search word>",
  ///   sourceLang:  "sv" | "es" | ...,
  ///   targetLang:  "en",
  ///   matchIndex:  <int — index into `lines` of the matched line>,
  ///   lines:       [ { index, start, end, text }, ... ],
  ///   translation: [ { index, start, end, text }, ... ]   // same length, parallel
  /// }
  /// ```
  /// `start` and `end` are seconds (doubles). The page can format them to
  /// SRT timestamps (`HH:MM:SS,mmm`) by itself.
  String _jsCodeForCapturedSubtitle(Map<String, dynamic> payload) {
    final detail = jsonEncode(payload);
    return "window.dispatchEvent(new CustomEvent('capturedSubtitle', { detail: $detail }));";
  }

  // Set when capture happens before dialog1 has ever been initialized — the
  // event is then fired in onPageFinished, after the page is ready to listen.
  Map<String, dynamic>? _pendingCapturedSubtitle;

  void _sendCapturedSubtitleToDialog1(Map<String, dynamic> payload) {
    if (dialogController != null) {
      dialogController!.runJavaScript(_jsCodeForCapturedSubtitle(payload));
      _showDialog1();
      return;
    }
    // No dialog1 controller yet — let _openDialogWithWebview spin one up,
    // then dispatch from onPageFinished once the listener is alive.
    _pendingCapturedSubtitle = payload;
    _openDialogWithWebview('');
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
    // Never hide the bar while voice input is active — the user needs to see
    // the live mic state and the Stop control for as long as recording runs.
    if (_isListening) {
      if (!_showAppBar) _showAppBarWithTimer();
      return;
    }
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
    if (_autoHideAppBar && !_isListening) {
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
          if (_autoHideAppBar) setState(() => _urlBarFocused = focused);
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
        GestureDetector(
          // Long-press = enter continuous-listen mode (until next tap to stop).
          // Tap = original one-shot voice input.
          //
          // NOTE: on Android the inner IconButton must NOT set `tooltip:`.
          // Flutter's Tooltip claims the touch long-press to show itself, and
          // being the inner gesture detector it wins the arena over this outer
          // onLongPress — so the popup appeared but recording never started.
          // macOS shows tooltips on hover (no long-press conflict), so we keep
          // the hint there.
          onLongPress: () {
            if (Platform.isAndroid && !_isListening) {
              HapticFeedback.mediumImpact();
            }
            _startContinuousVoiceCapture();
          },
          child: ValueListenableBuilder<bool>(
            valueListenable: _isListeningNotifier,
            builder: (_, listening, __) => IconButton(
              tooltip: Platform.isAndroid
                  ? null
                  : (listening
                      ? (_continuousVoiceActive ? 'Stop continuous capture' : 'Stop listening')
                      : 'Voice input (long-press for continuous)'),
              icon: Icon(
                listening ? Icons.mic : Icons.mic_none,
                color: listening
                    ? (_continuousVoiceActive ? Colors.red : Colors.redAccent)
                    : null,
              ),
              onPressed: () {
                if (_continuousVoiceActive) {
                  _stopContinuousVoiceCapture();
                } else {
                  _toggleVoiceInput();
                }
              },
            ),
          ),
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
            // Double-tap + long-press detector for the auto-hiding app bar
            // (Android + macOS — desktop runs through PointerEvent the same
            // way, so the same gestures toggle the bar with a mouse). The
            // Listener doesn't consume events, so the WebView still gets the
            // input for native text selection.
            if (_autoHideAppBar)
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
            // App bar overlay — auto-hides on Android + macOS, always visible elsewhere
            if (_showAppBar || !_autoHideAppBar)
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

// ---------- YouTube subtitle isolate helpers ----------
// Top-level so they can be passed to `compute()`. The json3 cue blob can hit
// ~1 MB on hour-long videos — parsing on the UI isolate would jank the frame,
// so we hand it off to a background isolate.


/// Parses a YouTube `fmt=json3` caption body into `[{index, start, end, text}]`.
/// Empty / timing-only events are dropped; multi-segment events are flattened
/// by concatenating their `utf8` parts. `start`/`end` are in seconds.
List<Map<String, dynamic>> _parseYtJson3Captions(String body) {
  Map<String, dynamic> root;
  try {
    root = jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return const [];
  }
  final events = root['events'];
  if (events is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final e in events) {
    if (e is! Map) continue;
    final segs = e['segs'];
    if (segs is! List) continue;
    final buf = StringBuffer();
    for (final s in segs) {
      if (s is Map && s['utf8'] is String) buf.write(s['utf8']);
    }
    final text = buf.toString().replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    final tStart = (e['tStartMs'] as num?)?.toDouble() ?? 0;
    final dDur = (e['dDurationMs'] as num?)?.toDouble() ?? 0;
    out.add({
      'index': out.length,
      'start': tStart / 1000.0,
      'end': (tStart + dDur) / 1000.0,
      'text': text,
    });
  }
  return out;
}

/// Fallback parser for YouTube's default (`srv1`) timed-text XML, used when
/// `fmt=json3` comes back empty (happens on some non-English ASR tracks).
/// Shape we accept:
/// ```xml
/// <transcript>
///   <text start="0.42" dur="3.12">Hello &amp;amp; world</text>
///   ...
/// </transcript>
/// ```
/// Returns the same `[{index, start, end, text}]` shape as the json3 parser
/// so the caller path is identical.
List<Map<String, dynamic>> _parseYtTimedTextXml(String body) {
  if (body.isEmpty) return const [];
  // Regex parsing is fine here — the schema is fixed and shallow.
  final re = RegExp(
    r'<text\s+([^>]*?)>([\s\S]*?)<\/text>',
    multiLine: true,
  );
  final out = <Map<String, dynamic>>[];
  for (final m in re.allMatches(body)) {
    final attrs = m.group(1) ?? '';
    final raw = m.group(2) ?? '';
    double parseAttr(String name) {
      final am = RegExp('$name="([^"]*)"').firstMatch(attrs);
      if (am == null) return 0;
      return double.tryParse(am.group(1) ?? '') ?? 0;
    }
    final start = parseAttr('start');
    final dur = parseAttr('dur');
    final text = _decodeXmlEntities(raw).replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    out.add({
      'index': out.length,
      'start': start,
      'end': start + dur,
      'text': text,
    });
  }
  return out;
}

String _decodeXmlEntities(String s) {
  return s
      // Two-pass for nested entities (`&amp;amp;` → `&amp;` → `&`).
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAllMapped(RegExp(r'&#x([0-9A-Fa-f]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
}

/// Parses a WebVTT caption body into `[{index, start, end, text}]`. Used as
/// a fallback when yt-dlp can't produce json3 (some non-English ASR tracks).
/// Cue format:
/// ```
/// WEBVTT
///
/// 00:00:01.500 --> 00:00:04.000
/// Hello <c.colorE5E5E5>world</c>
/// ```
/// Inline tags (`<c>…</c>`, `<i>`, timestamp tags) are stripped — we only
/// keep the text payload.
List<Map<String, dynamic>> _parseVttCaptions(String body) {
  if (body.isEmpty) return const [];
  final tsRe = RegExp(
    r'(\d{1,2}):(\d{2}):(\d{2})[\.,](\d{1,3})\s+-->\s+'
    r'(\d{1,2}):(\d{2}):(\d{2})[\.,](\d{1,3})',
  );
  final tagRe = RegExp(r'<[^>]*>');
  final lines = body.split(RegExp(r'\r?\n'));
  final out = <Map<String, dynamic>>[];
  var i = 0;
  while (i < lines.length) {
    final m = tsRe.firstMatch(lines[i]);
    if (m == null) { i++; continue; }
    double parseTs(int h, int mm, int s, int ms) =>
        h * 3600 + mm * 60 + s + ms / 1000.0;
    final start = parseTs(
      int.parse(m.group(1)!), int.parse(m.group(2)!),
      int.parse(m.group(3)!), int.parse(m.group(4)!.padRight(3, '0')),
    );
    final end = parseTs(
      int.parse(m.group(5)!), int.parse(m.group(6)!),
      int.parse(m.group(7)!), int.parse(m.group(8)!.padRight(3, '0')),
    );
    i++;
    final buf = StringBuffer();
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      final stripped = lines[i].replaceAll(tagRe, '').trim();
      if (stripped.isNotEmpty) {
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(stripped);
      }
      i++;
    }
    final text = buf.toString().trim();
    if (text.isEmpty) continue;
    // De-dupe consecutive identical lines — YouTube's ASR VTT often repeats
    // each cue at finer granularity (rolling karaoke style).
    if (out.isNotEmpty && (out.last['text'] as String) == text) {
      out.last['end'] = end;
      continue;
    }
    out.add({
      'index': out.length,
      'start': start,
      'end': end,
      'text': text,
    });
  }
  return out;
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

