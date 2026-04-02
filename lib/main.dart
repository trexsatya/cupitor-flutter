import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';

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

class WebViewExampleState extends State<WebViewExample> {
  late final WebViewController _controller;
  WebViewController? dialogController;
  final TextEditingController _urlController = TextEditingController(text: 'https://google.com');
  String _dialogUrl = 'https://satyendra.website/language.html';
  final List<String> _languages = ['sv', 'es'];
  final Map<String, String> _languageParams = {'sv': 'swedish', 'es': 'spanish'};
  String _selectedLanguage = 'sv';
  bool _isControllerReady = false;
  List<String> _bookmarks = [];
  String _currentDialogText = '';
  String? _cachedRemoteSnippet;
  final Set<String> _handledPdfUrls = {};
  bool _isTextView = false;
  bool _isShowingOurHtml = false;
  bool _isExtractingPdf = false;
  String? _currentPdfUrl;
  String? _extractedPdfText;
  String _lastStartedUrl = '';
  bool _isEinkMode = true;
  bool _showToolbar = false;
  bool _showAppBar = true;
  String? _githubToken;
  // Tracks Android main-frame navigations to detect the second onNavigationRequest
  // call that the download listener makes when WebView can't render a response
  // (e.g. application/pdf). First call = normal navigation; second call = download trigger.
  final Set<String> _androidPendingUrls = {};
  final ValueNotifier<String?> _dialogErrorNotifier = ValueNotifier(null);

  @override
  void dispose() {
    _urlController.dispose();
    _dialogErrorNotifier.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final savedUrl = prefs.getString('lastUrl') ?? _urlController.text;
      _urlController.text = savedUrl;
      _bookmarks = prefs.getStringList('bookmarks') ?? [];
      _githubToken = prefs.getString('githubToken');
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent('Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36')
        ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) => _openDialogWithWebview(msg.message.toString().replaceAll('"', '')))
        ..addJavaScriptChannel('PdfIframeDetector', onMessageReceived: (msg) => _handlePdfIframe(msg.message))
        ..addJavaScriptChannel('SpaNavigationDetector', onMessageReceived: (msg) => _onSpaNavigation(msg.message))
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
                  _extractedPdfText = null;
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
                        _extractedPdfText = null;
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
              _lastStartedUrl = url;
              setState(() {
                _urlController.text = url;
                if (_looksLikePdfUrl(url)) {
                  if (_currentPdfUrl != url) {
                    _currentPdfUrl = url;
                    _extractedPdfText = null;
                    _isTextView = false;
                  }
                } else {
                  _currentPdfUrl = null;
                  _extractedPdfText = null;
                  _isTextView = false;
                  _isShowingOurHtml = false;
                  _handledPdfUrls.clear();
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
                return;
              }
              _injectJs();
              _injectRemoteSnippet();
              _injectAdBlocker();
              _injectSpaHook();
              _injectEinkCss();
              // Detect PDF by content-type (handles non-.pdf URLs like download links)
              // and defer _injectPdfDetector so it never fires on native PDF pages.
              _detectPdfAndInject(url);
            },
          ),
        )
        ..loadRequest(Uri.parse(savedUrl));
      setState(() {
        _isControllerReady = true;
      });
      _revealAppBar(); // show on first launch, then auto-hide
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

  void _revealAppBar() {
    setState(() => _showAppBar = true);
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
          el.textContent = 'html { filter: contrast(1.1) brightness(0.95) !important; }';
        } else {
          if (el) el.remove();
        }
      })();
    ''';
    _controller.runJavaScript(js);
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
      // Switch back to PDF view
      setState(() { _isTextView = false; _isShowingOurHtml = false; });
      // On Android we show a Flutter PdfViewer overlay — no need to reload WebView.
      // On macOS/iOS WKWebView renders PDFs natively so we reload the URL.
      if (!Platform.isAndroid) {
        _controller.loadRequest(Uri.parse(_currentPdfUrl!));
      }
      return;
    }
    // Extract text if not yet cached
    if (_extractedPdfText == null) {
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
        final buf = StringBuffer();
        for (int i = 0; i < doc.pages.length; i++) {
          if (i > 0) buf.write('\n\n--- Page ${i + 1} ---\n\n');
          buf.write((await doc.pages[i].loadText()).fullText);
        }
        await doc.dispose();
        _extractedPdfText = buf.toString().trim();
      } catch (e) {
        debugPrint('PDF extraction error: $e');
        setState(() => _isExtractingPdf = false);
        return;
      }
      setState(() => _isExtractingPdf = false);
    }
    if (_extractedPdfText == null || _extractedPdfText!.isEmpty) {
      debugPrint('No extractable text in PDF (image-based?).');
      return;
    }
    final escaped = _extractedPdfText!
        .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final html = '<!DOCTYPE html><html><head>'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{font-family:serif;font-size:15px;line-height:1.7;'
        'padding:24px;margin:0;background:#fff;-webkit-user-select:text;user-select:text;}'
        'pre{white-space:pre-wrap;word-wrap:break-word;font-family:inherit;}</style>'
        '</head><body><pre>$escaped</pre></body></html>';
    setState(() { _isTextView = true; _isShowingOurHtml = true; });
    await _controller.loadHtmlString(html);
    // onPageFinished will call _injectJs() for word-click support
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

  Future<void> _injectAdBlocker() async {
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
        const _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          if (adHosts.some(h => url.includes(h))) return;
          return _open.call(this, method, url, ...rest);
        };
        const _fetch = window.fetch;
        window.fetch = function(input, init) {
          const url = typeof input === 'string' ? input : input.url;
          if (adHosts.some(h => url.includes(h))) return Promise.resolve(new Response('', { status: 200 }));
          return _fetch.call(this, input, init);
        };
      })();
    ''';
    _controller.runJavaScript(css);
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
    setState(() => _bookmarks.remove(url));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bookmarks', _bookmarks);
  }

  void _showBookmarks() {
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
                          setState(() => _bookmarks.clear());
                          setModalState(() {});
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setStringList('bookmarks', []);
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
                          return ListTile(
                            leading: Icon(Icons.bookmark),
                            title: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _urlController.text = url;
                              _loadUrl();
                            },
                            trailing: IconButton(
                              icon: Icon(Icons.delete_outline),
                              onPressed: () async {
                                await _removeBookmark(url);
                                setModalState(() {});
                              },
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

  void _openDialog2WithWebview(String url) {
    final errorNotifier = ValueNotifier<String?>(null);
    final dialog2Controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => errorNotifier.value = null,
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) {
            errorNotifier.value = '[${error.errorCode}] ${error.description}\n${error.url ?? ''}';
          }
        },
      ))
      ..loadRequest(Uri.parse(url));

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: screenHeight * 0.025),
        child: Container(
          width: screenWidth * 0.98,
          height: screenHeight * 0.95,
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Close')),
              ),
              Expanded(
                child: ValueListenableBuilder<String?>(
                  valueListenable: errorNotifier,
                  builder: (_, error, __) => error != null
                      ? _errorView(error, () {
                          errorNotifier.value = null;
                          dialog2Controller.loadRequest(Uri.parse(url));
                        })
                      : WebViewWidget(controller: dialog2Controller),
                ),
              ),
            ],
          ),
        ),
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
    if (dialogController != null) {
      dialogController?.runJavaScript(jsCodeToFilterData(text));
    } else {
      dialogController ??= WebViewController()
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
              dialogController?.runJavaScript(jsCodeToFilterData(_currentDialogText));
            },
          ),
        )
        ..loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: screenHeight * 0.025),
        child: Container(
          width: screenWidth,
          height: screenHeight * 0.95,
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Close')),
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
        ),
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

  @override
  Widget build(BuildContext context) {
    if (!_isControllerReady) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        }
      },
      child: Scaffold(
      appBar: _showAppBar ? AppBar(
        title: TextField(
          controller: _urlController,
          decoration: InputDecoration(
            hintText: 'Enter URL',
            border: InputBorder.none,
            suffixIcon: IconButton(icon: Icon(Icons.arrow_forward), onPressed: _loadUrl),
          ),
          keyboardType: TextInputType.url,
          onTap: () => _urlController.selection = TextSelection(baseOffset: 0, extentOffset: _urlController.text.length),
          onSubmitted: (_) => _loadUrl(),
        ),
        actions: [
          if (_showToolbar) ...([
            DropdownButton<String>(
              value: _selectedLanguage,
              items: _languages.map((lang) => DropdownMenuItem(value: lang, child: Text(lang))).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedLanguage = value!;
                  if (dialogController != null) {
                    dialogController?.loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
                  }
                });
              },
              underline: SizedBox(),
              icon: Icon(Icons.language, color: Colors.white),
              dropdownColor: Colors.white,
            ),
            IconButton(
              icon: Icon(_isEinkMode ? Icons.invert_colors_off : Icons.invert_colors),
              tooltip: _isEinkMode ? 'Disable E-ink mode' : 'Enable E-ink mode',
              onPressed: () {
                setState(() => _isEinkMode = !_isEinkMode);
                _injectEinkCss();
              },
            ),
            IconButton(
              icon: Icon(_githubToken != null ? Icons.key : Icons.key_off_outlined),
              tooltip: 'GitHub token',
              onPressed: _showTokenDialog,
            ),
          ]),
          IconButton(
            icon: Icon(_showToolbar ? Icons.tune : Icons.tune_outlined),
            tooltip: _showToolbar ? 'Hide toolbar' : 'Show toolbar',
            onPressed: () => setState(() => _showToolbar = !_showToolbar),
          ),
          if (_currentPdfUrl != null)
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
          IconButton(
            icon: Icon(Icons.bookmarks_outlined),
            onPressed: _showBookmarks,
            tooltip: 'Bookmarks',
          ),
          IconButton(
            icon: Icon(Icons.open_in_new),
            onPressed: () async {
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
              String text = '';
              try {
                final result = await _controller.runJavaScriptReturningResult(js);
                text = result.toString().replaceAll('"', '');
              } catch (_) {}
              _openDialogWithWebview(text);
            },
          ),
        ],
      ) : null,
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (_showAppBar) setState(() => _showAppBar = false);
        },
        child: ColorFiltered(
        colorFilter: _isEinkMode
            ? const ColorFilter.matrix([
                // Warm sepia — white maps to Kindle cream RGB(0.95, 0.91, 0.83)
                // Uses luminance weights tinted across warm-shifted rows.
                0.1913, 0.6437, 0.0650, 0, 0.05,  // R: warm boost
                0.1850, 0.6222, 0.0628, 0, 0.04,  // G: neutral-warm
                0.1722, 0.5793, 0.0585, 0, 0.02,  // B: blue reduced
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
            // On Android, WebView has no built-in PDF renderer.
            // Overlay a Flutter PdfViewer widget when viewing a PDF in PDF mode.
            if (Platform.isAndroid && _currentPdfUrl != null && !_isTextView)
              Positioned.fill(
                child: PdfViewer.uri(
                  Uri.parse(_currentPdfUrl!),
                  params: PdfViewerParams(backgroundColor: Colors.white),
                ),
              ),
            // Invisible strip at the top — swipe down on it to reveal the AppBar.
            // Must be last in the Stack so it sits above the PDF overlay.
            Positioned(
              top: 0, left: 0, right: 0,
              height: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) {
                  if (details.delta.dy > 2) _revealAppBar();
                },
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
