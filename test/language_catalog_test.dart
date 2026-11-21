import 'dart:async';
import 'dart:convert';

import 'package:cupitor/language_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object> language(
  String name,
  String code,
  String locale, {
  bool study = true,
}) => {
  'name': name,
  'code': code,
  'locale': locale,
  'capabilities': {'study': study, 'calls': true},
};
String catalog(List<Map<String, Object>> languages) =>
    jsonEncode({'version': 1, 'languages': languages});
final swedish = language('swedish', 'sv', 'sv-SE');
final polish = language('polish', 'pl', 'pl-PL');
final german = language('german', 'de', 'de-DE', study: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'new study languages need no native code; metadata-only languages stay out of the picker',
    () {
      final data = CupitorLanguageCatalog.parse(
        catalog([swedish, german, polish]),
      );
      expect(data.studyLanguages.map((item) => item.code), ['sv', 'pl']);
      expect(data.find('PL')?.name, 'polish');
      expect(data.find('polish')?.locale, 'pl-PL');
      expect(data.find('pl-PL')?.label, 'Polish');
      expect(data.find('german')?.study, isFalse);
      expect(data.find('unknown'), isNull);
    },
  );

  test(
    'invalid versions, paths, locales and duplicate identities are rejected',
    () {
      for (final text in [
        'not json',
        '{"version":2,"languages":[]}',
        catalog([]),
        catalog([swedish, swedish]),
        catalog([
          {...swedish, 'name': '../swedish'},
        ]),
        catalog([
          {...swedish, 'name': 'swedish-'},
        ]),
        catalog([
          {...swedish, 'code': 'not-a-code'},
        ]),
        catalog([
          {...swedish, 'locale': 'not a locale'},
        ]),
        catalog([
          {...swedish, 'capabilities': {}},
        ]),
      ]) {
        expect(() => CupitorLanguageCatalog.parse(text), throwsFormatException);
      }
    },
  );

  test(
    'refresh uses the published catalog and persists new choices for offline use',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final source = catalog([swedish, german, polish]);
      final store = CupitorLanguageCatalogStore(
        preferences,
        client: MockClient((request) async {
          expect(request.url, CupitorLanguageCatalogStore.endpoint);
          expect(request.headers['Cache-Control'], 'no-cache');
          expect(request.headers.containsKey('Authorization'), isFalse);
          return http.Response(source, 200);
        }),
      );
      expect(store.readCached(), isNull);
      expect((await store.refresh()).studyLanguages.map((item) => item.code), [
        'sv',
        'pl',
      ]);
      expect(
        CupitorLanguageCatalogStore(preferences).readCached()?.find('pl')?.name,
        'polish',
      );
    },
  );

  test(
    'failed or malformed responses preserve the last valid cached languages',
    () async {
      final original = catalog([swedish, polish]);
      SharedPreferences.setMockInitialValues({
        CupitorLanguageCatalogStore.cacheKey: original,
      });
      final preferences = await SharedPreferences.getInstance();
      for (final response in [
        http.Response('not json', 200),
        http.Response('missing', 404),
        http.Response(catalog([swedish, swedish]), 200),
      ]) {
        final store = CupitorLanguageCatalogStore(
          preferences,
          client: MockClient((_) async => response),
        );
        await expectLater(store.refresh(), throwsA(anything));
        expect(
          preferences.getString(CupitorLanguageCatalogStore.cacheKey),
          original,
        );
        expect(store.readCached()?.find('pl')?.code, 'pl');
      }
    },
  );

  testWidgets(
    'picker shows available language names and returns the catalog URL key and locale',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = CupitorLanguageCatalogStore(
        await SharedPreferences.getInstance(),
        client: MockClient(
          (_) async => http.Response(catalog([swedish, german, polish]), 200),
        ),
      );
      CupitorLanguage? selected;
      CupitorLanguageCatalog? loaded;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CupitorLanguagePicker(
              selectedCode: 'sv',
              store: store,
              onSelected: (value) => selected = value,
              onCatalog: (value) => loaded = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loaded?.find('pl')?.code, 'pl');
      expect(find.text('Swedish'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('German'), findsNothing);
      await tester.tap(find.text('Polish').last);
      await tester.pumpAndSettle();
      expect(selected?.name, 'polish');
      expect(selected?.code, 'pl');
      expect(selected?.locale, 'pl-PL');
    },
  );

  testWidgets(
    'offline cached choices stay usable and retry can discover a new language',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        CupitorLanguageCatalogStore.cacheKey: catalog([swedish]),
      });
      var requests = 0;
      final store = CupitorLanguageCatalogStore(
        await SharedPreferences.getInstance(),
        client: MockClient(
          (_) async => ++requests == 1
              ? http.Response('offline', 503)
              : http.Response(catalog([swedish, polish]), 200),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CupitorLanguagePicker(
              selectedCode: 'sv',
              store: store,
              onSelected: (_) {},
              onCatalog: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Swedish'), findsOneWidget);
      expect(find.text('Using saved languages'), findsOneWidget);
      await tester.tap(find.byTooltip('Reload languages'));
      await tester.pumpAndSettle();
      expect(find.text('Using saved languages'), findsNothing);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Polish'), findsOneWidget);
    },
  );

  testWidgets(
    'a first offline launch disables choices until the catalog can load',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = CupitorLanguageCatalogStore(
        await SharedPreferences.getInstance(),
        client: MockClient((_) async => http.Response('offline', 503)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CupitorLanguagePicker(
              selectedCode: 'sv',
              store: store,
              onSelected: (_) {},
              onCatalog: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connect to load languages'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .onChanged,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing the picker while refreshing ignores the late result', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final response = Completer<http.Response>();
    final store = CupitorLanguageCatalogStore(
      await SharedPreferences.getInstance(),
      client: MockClient((_) => response.future),
    );
    var adopted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupitorLanguagePicker(
            selectedCode: 'sv',
            store: store,
            onSelected: (_) {},
            onCatalog: (_) {
              adopted = true;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(http.Response(catalog([swedish, polish]), 200));
    await tester.pumpAndSettle();
    expect(adopted, isFalse);
    expect(tester.takeException(), isNull);
  });
}
