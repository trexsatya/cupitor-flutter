import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  final List<String> _languages = ['swedish', 'spanish'];
  String _selectedLanguage = 'swedish';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final savedUrl = prefs.getString('lastUrl') ?? _urlController.text;
      _urlController.text = savedUrl;
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) => print(msg.message))
        ..loadRequest(Uri.parse(savedUrl));
    });
  }

  void _loadUrl() {
    final url = _urlController.text;
    if (Uri.tryParse(url)?.isAbsolute ?? false) {
      _controller.loadRequest(Uri.parse(url));
      _controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            dialogController?.runJavaScript('''
              const observer = new MutationObserver(() => {
                const captions = document.querySelectorAll('.captions-text');
                if (captions.length > 0) {
                  let content = [];
                  captions.forEach(el => content.push(el.innerText));
                  CaptionHandler.postMessage(content.join("\n"));
                }
              });
              observer.observe(document.body, { childList: true, subtree: true });
            ''');
          },
        ),
      );
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
    return _dialogUrl + '?lang=' + lang;
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
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _urlController,
          decoration: InputDecoration(
            hintText: 'Enter URL',
            border: InputBorder.none,
            suffixIcon: IconButton(icon: Icon(Icons.arrow_forward), onPressed: _loadUrl),
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _loadUrl(),
        ),
        actions: [
          DropdownButton<String>(
            value: _selectedLanguage,
            items: _languages.map((lang) => DropdownMenuItem(value: lang, child: Text(lang))).toList(),
            onChanged: (value) {
              setState(() {
                _selectedLanguage = value!;
                // Optionally, reload WebView with language-specific URL
                _controller.loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
              });
            },
            underline: SizedBox(),
            icon: Icon(Icons.language, color: Colors.white),
            dropdownColor: Colors.white,
          ),
          IconButton(
            icon: Icon(Icons.open_in_new),
            onPressed: () async {
              final text = await _controller.runJavaScriptReturningResult("window.getSelection().toString();");
              _openDialogWithWebview(text.toString().replaceAll('"', ''));
            },
          ),
          IconButton(
            icon: Icon(Icons.open_in_new_sharp),
            onPressed: () async {
              final text = await _controller.runJavaScriptReturningResult("window.getSelection().toString();");
              _openDialogWithWebview("<*" + text.toString().replaceAll('"', ''));
            },
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
