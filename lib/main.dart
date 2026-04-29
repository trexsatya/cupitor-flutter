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
  bool _showToolbar = false;
  bool _showAppBar = true;
  String? _githubToken;
  int _pdfTextFontSize = 15;
  bool _showFindBar = false;
  bool _urlBarFocused = false;
  String _pdfSelectedText = '';
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable();
    } else if (state == AppLifecycleState.paused) {
      WakelockPlus.disable();
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
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent('Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36')
        ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) => _openDialogWithWebview(msg.message.toString().replaceAll('"', '')))
        ..addJavaScriptChannel('PdfIframeDetector', onMessageReceived: (msg) => _handlePdfIframe(msg.message))
        ..addJavaScriptChannel('SpaNavigationDetector', onMessageReceived: (msg) => _onSpaNavigation(msg.message))
        ..addJavaScriptChannel('AdHostDetector', onMessageReceived: (msg) => _onJsAdHostDetected(msg.message))
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) async {
              if (!request.isMainFrame) return NavigationDecision.navigate;
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
              //_injectRemoteSnippet();
              _injectAdBlocker();
              _injectYouTubeAdBlocker();
              _injectSpaHook();
              _injectEinkCss();
              _injectPageZoom();
              // Detect PDF by content-type (handles non-.pdf URLs like download links)
              // and defer _injectPdfDetector so it never fires on native PDF pages.
              _detectPdfAndInject(url);
              // Restore scroll position for this URL
              _restoreScrollPosition(url);
            },
          ),
        )
        ..loadRequest(Uri.parse(savedUrl));
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

  void _injectEinkCss() {
    final enabled = _isEinkMode;
    final js = '''
      (function() {
        const id = 'flutter_eink_style';
        let el = document.getElementById(id);
        if (${enabled ? 'true' : 'false'}) {
          if (!el) {
            el = document.createElement('style');
            el.id = id;
            document.head.appendChild(el);
          }
          // Applied to body (not html) — `filter` on the root element creates
          // a new containing block for fixed-position descendants and can
          // interfere with internal scroll containers on some sites.
          el.textContent = 'body { filter: contrast(1.1) brightness(0.95) !important; }';
        } else {
          if (el) el.remove();
        }
      })();
    ''';
    _controller.runJavaScript(js);
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
        _controller.runJavaScript(_cachedRemoteSnippet!);
      }
    }).catchError((_) {
      // Network unavailable, timeout, or server error — skip silently
      if (_cachedRemoteSnippet != null) {
        _controller.runJavaScript(_cachedRemoteSnippet!);
      }
    });
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

  void _injectYouTubeAdBlocker([WebViewController? ctrl]) {
    const js = r'''
      (function() {
        if (!location.hostname.includes('youtube.com')) return;
        if (window._ytAdBlockerInjected) return;
        window._ytAdBlockerInjected = true;

        // --- 1. Hide overlay / banner ad elements ---
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
        document.head.appendChild(style);

        // --- 2. Core skip logic ---
        // Track whether *we* muted the video so we can restore audio when the
        // ad ends. Without this, the next non-ad video stays silently muted.
        let _mutedByAdSkip = false;

        function skipAd() {
          // Click any visible skip / close button
          const skipBtn = document.querySelector(
            '.ytp-skip-ad-button, .ytp-ad-skip-button, ' +
            '.ytp-ad-skip-button-slot button, .ytp-ad-overlay-close-button'
          );
          if (skipBtn) { skipBtn.click(); return; }

          // Fast-forward through non-skippable video ads.
          // Only seek when the video has enough data (readyState >= 3 = HAVE_FUTURE_DATA)
          // to avoid triggering a buffering stall/loop.
          const player = document.querySelector('.html5-video-player');
          if (player && player.classList.contains('ad-showing')) {
            const video = document.querySelector('video');
            if (video && isFinite(video.duration) && video.duration > 0
                && video.readyState >= 3 && !video.seeking) {
              if (!video.muted) {
                video.muted = true;
                _mutedByAdSkip = true;
              }
              video.currentTime = video.duration;
            }
          }
        }

        function restoreAudioAfterAd() {
          if (!_mutedByAdSkip) return;
          const player = document.querySelector('.html5-video-player');
          if (player && player.classList.contains('ad-showing')) return;
          const video = document.querySelector('video');
          if (video) video.muted = false;
          _mutedByAdSkip = false;
        }

        // --- 3. Immediate skip on video timeupdate (fires every ~250 ms or less) ---
        function attachVideoListener() {
          const video = document.querySelector('video');
          if (!video || video._ytAdListenerAttached) return;
          video._ytAdListenerAttached = true;
          video.addEventListener('timeupdate', () => {
            const player = document.querySelector('.html5-video-player');
            if (player && player.classList.contains('ad-showing')) {
              skipAd();
            } else {
              restoreAudioAfterAd();
            }
          });
        }
        attachVideoListener();

        // --- 4. MutationObserver scoped to the player container ---
        // Observing document.documentElement with subtree:true fires the callback
        // on every YouTube UI tweak — hundreds per second during ad playback,
        // enough to saturate the renderer thread and freeze the WebView. We
        // bootstrap with a narrow observer just to find the player, then watch
        // only the player itself.
        function startPlayerObserver(player) {
          if (player._ytAdObserverAttached) return;
          player._ytAdObserverAttached = true;
          new MutationObserver((mutations) => {
            for (const m of mutations) {
              if (m.type === 'attributes' && m.attributeName === 'class') {
                // Only the player element itself carries ad-showing.
                if (m.target === player) {
                  if (player.classList.contains('ad-showing')) { skipAd(); return; }
                  if (_mutedByAdSkip) restoreAudioAfterAd();
                }
              } else if (m.type === 'childList') {
                for (const node of m.addedNodes) {
                  if (node.nodeType !== 1) continue;
                  if (node.matches && (
                    node.matches('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-slot')
                    || (node.querySelector && node.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button'))
                  )) { skipAd(); return; }
                }
                // A fresh video element may have been inserted (SPA nav).
                attachVideoListener();
              }
            }
          }).observe(player, {
            childList: true, subtree: true,
            attributes: true, attributeFilter: ['class']
          });
        }

        const _existingPlayer = document.querySelector('.html5-video-player');
        if (_existingPlayer) {
          startPlayerObserver(_existingPlayer);
        } else {
          // Light bootstrap observer — disconnects as soon as the player appears.
          const _bootstrap = new MutationObserver(() => {
            const p = document.querySelector('.html5-video-player');
            if (p) {
              _bootstrap.disconnect();
              startPlayerObserver(p);
            }
          });
          _bootstrap.observe(document.documentElement, { childList: true, subtree: true });
        }

        // --- 5. Block YouTube's own ad-reporting and ad-stats endpoints ---
        // Only block truly ad-specific paths. Do NOT block /api/stats/qoe or
        // /youtubei/v1/log_event — these are used by the player for all events
        // (not just ads) and blocking them causes the player to hang/freeze.
        const YT_AD_PATHS = [
          '/api/stats/ads',
          '/pagead/',
          '/ptracking',
        ];
        function isYtAdUrl(url) {
          try {
            const u = new URL(url, location.href);
            if (!u.hostname.includes('youtube.com') &&
                !u.hostname.includes('googlevideo.com')) return false;
            return YT_AD_PATHS.some(p => u.pathname.startsWith(p));
          } catch(_) { return false; }
        }
        // --- 5. Behavioral ad-host recorder ---
        // When ad-showing is active, every 3rd-party hostname contacted is
        // a confirmed ad-network host — detected by causality, not by name.
        // We report each new one to Flutter via the AdHostDetector JS channel.
        const _reportedHosts = new Set();
        function isAdShowing() {
          const p = document.querySelector('.html5-video-player');
          return p && p.classList.contains('ad-showing');
        }
        function reportAdHost(url) {
          if (!isAdShowing()) return;
          try {
            const host = new URL(url, location.href).hostname;
            if (!host || host === location.hostname) return; // same-origin: skip
            const key = host.split('.').slice(-2).join('.'); // registrable host
            if (_reportedHosts.has(key)) return;
            _reportedHosts.add(key);
            if (typeof AdHostDetector !== 'undefined') AdHostDetector.postMessage(key);
          } catch(_) {}
        }
        // Wrap fetch
        const _origFetch2 = window.fetch;
        window.fetch = function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          reportAdHost(url);
          if (isYtAdUrl(url)) return Promise.resolve(new Response('{}', {status:200, headers:{'content-type':'application/json'}}));
          return _origFetch2.apply(this, arguments);
        };
        // Wrap XHR — redirect blocked URLs to a data: URL so the request
        // completes cleanly with empty JSON. Dropping send() (the previous
        // approach) left callers waiting for onload forever, which froze the
        // YouTube player and any host page using XHR-based ad trackers.
        const _origOpen2 = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          reportAdHost(url);
          const target = (typeof url === 'string' && isYtAdUrl(url))
            ? 'data:application/json,{}' : url;
          return _origOpen2.call(this, method, target, ...rest);
        };

        // Fallback poll — catches any edge case the observer misses.
        // Self-terminates after 20 consecutive attempts with an ad still showing
        // (meaning the skip approach isn't working) to avoid an infinite hammering
        // loop that can freeze the dialog WebView.
        let _skipStuckCount = 0;
        const _skipPollId = setInterval(function() {
          const player = document.querySelector('.html5-video-player');
          if (!player || !player.classList.contains('ad-showing')) {
            _skipStuckCount = 0; // ad gone — reset counter
            return;
          }
          _skipStuckCount++;
          if (_skipStuckCount > 20) {
            // Ad has been stuck for >10 s and isn't skipping — stop trying to
            // avoid freezing the WebView renderer.
            clearInterval(_skipPollId);
            return;
          }
          skipAd();
        }, 500);
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
                        setModalState(() {});
                        _injectEinkCss();
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
    // Create unique dialog ID based on URL and timestamp
    final dialogId = '${Uri.parse(url).host}_${DateTime.now().millisecondsSinceEpoch}';

    final errorNotifier = ValueNotifier<String?>(null);
    bool hasRedirected = false;
    late final WebViewController dialog2Controller;
    dialog2Controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => errorNotifier.value = null,
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) {
            errorNotifier.value = '[${error.errorCode}] ${error.description}\n${error.url ?? ''}';
          }
        },
        onPageFinished: (finishedUrl) {
          _injectAdBlocker(dialog2Controller);
          _injectYouTubeAdBlocker(dialog2Controller);
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
            },
            child: Container(
              color: Colors.transparent,
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // Prevent tap propagation from dialog content
                  child: Dialog(
                    insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: screenHeight * 0.025),
                    child: _buildDialog2Content(ctx, dialogId, url, controller, errorNotifier, screenWidth, screenHeight),
                  ),
                ),
              ),
            ),
          )
        : Dialog(
            insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: screenHeight * 0.025),
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
      }
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
      height: screenHeight * 0.95,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            child: Row(
              children: [
                // Show dialog title with host name
                Expanded(
                  child: Text(
                    Uri.tryParse(url)?.host ?? 'Dialog',
                    style: TextStyle(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    _minimizedDialog2s.add(dialogId);
                    _everMinimizedDialog2s.add(dialogId); // Mark as ever minimized
                    Navigator.of(ctx).pop();
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
                  : WebViewWidget(controller: controller),
            ),
          ),
        ],
      ),
    );
  }

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
        ..addJavaScriptChannel('GitHubProxy', onMessageReceived: _handleGitHubProxyRequest)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) => _dialogErrorNotifier.value = null,
            onWebResourceError: (error) {
              if (error.isForMainFrame == true) {
                _dialogErrorNotifier.value = '[${error.errorCode}] ${error.description}\n${error.url ?? ''}';
              }
            },
            onNavigationRequest: (request) {
              final reqHost = Uri.tryParse(request.url)?.host;
              final dialogHost = Uri.tryParse(_dialogUrl)?.host;
              if (request.isMainFrame && reqHost != dialogHost) {
                _openDialog2WithWebview(request.url);
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onPageFinished: (url) {
              _injectAdBlocker(dialogController);
              _injectYouTubeAdBlocker(dialogController);
              dialogController?.runJavaScript(jsCodeToFilterData(_currentDialogText));
            },
          ),
        )
        ..loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
    }

    // Always show the dialog (it may have been dismissed previously)
    _showDialog1();
  }

  void _showDialog1() {
    if (dialogController == null) return;
    setState(() => _dialog1Minimized = false);
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // If dialog has been minimized before, tapping outside should minimize, not close
    final hasBeenMinimized = _dialog1EverMinimized;

    showDialog(
      context: context,
      barrierDismissible: !hasBeenMinimized, // Prevent outside tap closing if ever minimized
      builder: (ctx) => hasBeenMinimized
        ? GestureDetector(
            // Custom barrier tap handler - minimizes instead of closing
            onTap: () {
              setState(() => _dialog1Minimized = true);
              Navigator.of(ctx).pop();
            },
            child: Container(
              color: Colors.transparent,
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // Prevent tap propagation from dialog content
                  child: Dialog(
                    insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: screenHeight * 0.025),
                    child: _buildDialog1Content(ctx, screenWidth, screenHeight),
                  ),
                ),
              ),
            ),
          )
        : Dialog(
            insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: screenHeight * 0.025),
            child: _buildDialog1Content(ctx, screenWidth, screenHeight),
          ),
    ).then((_) {
      // Dialog closed - but keep controller alive to avoid reloading.
      // Controller will be cleaned up only when app is disposed or language changes.
      // This prevents unnecessary reloads when reopening the dialog.
    });
  }

  Widget _buildDialog1Content(BuildContext ctx, double screenWidth, double screenHeight) {
    return Container(
      width: screenWidth,
      height: screenHeight * 0.95,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _dialog1Minimized = true;
                      _dialog1EverMinimized = true; // Mark as ever minimized
                    });
                    Navigator.of(ctx).pop();
                  },
                  child: Text('Minimize'),
                ),
                TextButton(
                  onPressed: () {
                    // Clear minimized state when manually closing
                    setState(() => _dialog1Minimized = false);
                    Navigator.of(ctx).pop();
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
                  : WebViewWidget(controller: dialogController!),
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
      await _speech.listen(
        localeId: _speechLocale(),
        onResult: (result) {
          lastWords = result.recognizedWords;
          if (result.finalResult && lastWords.isNotEmpty) {
            _speech.stop();
            setState(() => _isListening = false);
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

  void _handleDoubleTapDetection() {
    final now = DateTime.now();
    if (_lastTapTime != null && now.difference(_lastTapTime!) < const Duration(milliseconds: 400)) {
      _lastTapTime = null;
      if (_showAppBar) {
        _appBarTimer?.cancel();
        setState(() => _showAppBar = false);
      } else {
        _showAppBarWithTimer();
      }
    } else {
      _lastTapTime = now;
    }
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
              try {
                final result = await _controller.runJavaScriptReturningResult(js);
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
              colorFilter: _isEinkMode
                  ? const ColorFilter.matrix([
                      0.1913, 0.6437, 0.0650, 0, 0.05,
                      0.1850, 0.6222, 0.0628, 0, 0.04,
                      0.1722, 0.5793, 0.0585, 0, 0.02,
                      0,      0,      0,      1, 0,
                    ])
                  : const ColorFilter.matrix([
                      1, 0, 0, 0, 0,
                      0, 1, 0, 0, 0,
                      0, 0, 1, 0, 0,
                      0, 0, 0, 1, 0,
                    ]),
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
            // Double-tap detector (Android only — macOS keeps app bar always visible)
            if (Platform.isAndroid)
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => _handleDoubleTapDetection(),
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
            // Restore buttons for minimized dialog webviews
            if (_dialog1Minimized || _minimizedDialog2s.isNotEmpty)
              Positioned(
                right: 16,
                bottom: 16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Multiple dialog2 restore buttons
                    ..._minimizedDialog2s.map((dialogId) {
                      final url = _dialog2Urls[dialogId] ?? '';
                      final host = Uri.tryParse(url)?.host ?? 'Dialog';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FloatingActionButton.extended(
                          heroTag: 'restoreDialog2_$dialogId',
                          tooltip: 'Restore: $host',
                          onPressed: () => _showDialog2(dialogId),
                          icon: const Icon(Icons.menu_book, size: 16),
                          label: Text(
                            host.length > 12 ? '${host.substring(0, 12)}...' : host,
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      );
                    }).toList(),
                    // Dialog1 restore button
                    if (_dialog1Minimized)
                      FloatingActionButton.small(
                        heroTag: 'restoreDialog1',
                        tooltip: 'Restore dialog',
                        onPressed: _showDialog1,
                        child: const Icon(Icons.translate),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
