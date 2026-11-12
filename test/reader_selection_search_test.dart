import 'dart:convert';

import 'package:cupitor/epub_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test doubles implement the WebView plugin's platform contract directly.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _NavigationDelegate extends PlatformNavigationDelegate {
  _NavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback callback) async {}
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();
  final channels = <String, JavaScriptChannelParams>{};
  final loadedUrls = <String?>[];
  List<String> speechByChapter = [];

  @override
  Future<void> setBackgroundColor(Color color) async {}
  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channels[params.name] = params;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    loadedUrls.add(baseUrl);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    if (!javaScript.startsWith('window.__cupEpubSpeechLines(')) return '';
    return jsonEncode([
      {'text': speechByChapter[loadedUrls.length - 1], 'start': 0, 'end': 0},
    ]);
  }

  void markChapterReady() => channels['CupEpub']!.onMessageReceived(
    JavaScriptMessage(
      message: jsonEncode({
        'type': 'chapterReady',
        'loadId': loadedUrls.length,
      }),
    ),
  );

  void select(String text) => channels['CupEpub']!.onMessageReceived(
    JavaScriptMessage(
      message: jsonEncode({'type': 'select', 'text': text, 'x': 300, 'y': 200}),
    ),
  );
}

class _WebView extends PlatformWebViewWidget {
  _WebView(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Platform extends WebViewPlatform {
  late _Controller controller;
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _NavigationDelegate(params);
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = _Controller(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebView(params);
}

void main() {
  test('EPUB chapter origins use an HTTPS base on Mac and retain other platforms', () {
    expect(epubChapterBaseUrl(4, macOS: true),
        'https://reader.cupitor.invalid/chapter/4/');
    expect(epubChapterBaseUrl(4, macOS: false),
        'cupitor-epub://chapter/4');
  });

  testWidgets('Read aloud sets the speech locale before each chapter', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final platform = _Platform();
    WebViewPlatform.instance = platform;
    final calls = <MethodCall>[];
    const channel = MethodChannel('flutter_tts');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getLanguages') return ['en-US', 'sv-SE', 'es-MX'];
      if (call.method == 'setLanguage' || call.method == 'speak') {
        calls.add(call);
      }
      return 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: EpubReaderScreen(
          book: EpubBook(
            title: 'Testbok',
            author: null,
            language: 'sv',
            toc: [],
            resources: {},
            cssText: '',
            basePathInZip: '',
            key: 'read-aloud-language-test',
            filePath: '/tmp/book.epub',
            chapters: [
              EpubChapter(
                id: 'a',
                href: 'a.xhtml',
                title: 'One',
                html: '<p>Hej.</p>',
              ),
              EpubChapter(
                id: 'b',
                href: 'b.xhtml',
                title: 'Two',
                html: '<p>Hola.</p>',
                language: 'es-MX',
              ),
            ],
          ),
          onLookup: (_, _) {},
          speechFallbackLocale: 'en-US',
        ),
      ),
    );
    await tester.pumpAndSettle();
    platform.controller.speechByChapter = ['Hej.', 'Hola.'];
    platform.controller.markChapterReady();
    await tester.pump();
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();
    expect(platform.controller.loadedUrls, hasLength(2));
    platform.controller.markChapterReady();
    await tester.pumpAndSettle();
    expect(calls.map((call) => (call.method, call.arguments)), [
      ('setLanguage', 'sv-SE'),
      ('speak', 'Hej.'),
      ('setLanguage', 'es-MX'),
      ('speak', 'Hola.'),
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'Translate selected text without triggering a lookup',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final lookups = <String>[];
      final translations = <String>[];
      final platform = _Platform();
      WebViewPlatform.instance = platform;
      final book = EpubBook(
        title: 'Testbok',
        author: null,
        toc: [],
        resources: {},
        cssText: '',
        basePathInZip: '',
        key: 'selection-test',
        filePath: '/tmp/book.docx',
        chapters: [
          EpubChapter(
            id: 'a',
            href: 'a.xhtml',
            title: 'Kapitel ett',
            html: '<p>Inledning.</p>',
          ),
          EpubChapter(
            id: 'b',
            href: 'b.xhtml',
            title: 'Kapitel två',
            html: '<p>Sökbar svensk text.</p>',
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EpubReaderScreen(
            book: book,
            onLookup: (text, _) => lookups.add(text),
            onTranslate: (text) async {
              translations.add(text);
              return 'Searchable Swedish text.';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      platform.controller.select('Sökbar svensk text.');
      await tester.pump();
      await tester.tap(find.text('Translate'));
      await tester.pumpAndSettle();
      expect(translations, ['Sökbar svensk text.']);
      expect(lookups, isEmpty);
      expect(find.textContaining('Searchable Swedish text.'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Translate'), findsNothing);
      expect(platform.controller.loadedUrls, [epubChapterBaseUrl(0)]);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open lookup dialog'));
      await tester.pumpAndSettle();
      expect(lookups, ['']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
