import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

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

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final savedUrl = prefs.getString('lastUrl') ?? _urlController.text;
      _urlController.text = savedUrl;
      _bookmarks = prefs.getStringList('bookmarks') ?? [];
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent('Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36')
        ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) => _openDialogWithWebview(msg.message.toString().replaceAll('"', '')))
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (url) {
              setState(() {
                _urlController.text = url;
              });
            },
            onPageFinished: (url) {
              _injectJs();
              _injectAdBlocker();
            },
          ),
        )
        ..loadRequest(Uri.parse(savedUrl));
      setState(() {
        _isControllerReady = true;
      });
    });
  }

  Future<void> _injectJs() async {
    final jsCode = await rootBundle.loadString('assets/js/utils.js');
    _controller.runJavaScript(jsCode);
  }

  Future<void> _injectAdBlocker() async {
    const css = '''
      (function() {
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
    final dialog2Controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
              Expanded(child: WebViewWidget(controller: dialog2Controller)),
            ],
          ),
        ),
      ),
    );
  }

  String getUrlForLanguage(String lang) {
    return _dialogUrl + '?lang=' + (_languageParams[lang] ?? lang);
  }

  void _openDialogWithWebview(String text) {
    if (dialogController != null) {
      dialogController?.runJavaScript(jsCodeToFilterData(text));
    } else {
      dialogController ??= WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              if (request.isMainFrame) {
                _openDialog2WithWebview(request.url);
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onPageFinished: (url) {
              dialogController?.runJavaScript(jsCodeToFilterData(text));
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
              Expanded(child: WebViewWidget(controller: dialogController!)),
            ],
          ),
        ),
      ),
    );
  }

  String jsCodeToFilterData(String text) => "window.dispatchEvent(new CustomEvent('filterData', { detail: '${text.replaceAll("'", "\\'")}' }));";

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
      appBar: AppBar(
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
            icon: Icon(Icons.bookmark_add_outlined),
            onPressed: _addBookmark,
            tooltip: 'Add bookmark',
          ),
          IconButton(
            icon: Icon(Icons.bookmarks_outlined),
            onPressed: _showBookmarks,
            tooltip: 'Bookmarks',
          ),
          IconButton(
            icon: Icon(Icons.open_in_new),
            onPressed: () async {
              final text = await _controller.runJavaScriptReturningResult("window.getSelection().toString();");
              _openDialogWithWebview(text.toString().replaceAll('"', ''));
            },
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    ),
    );
  }
}
