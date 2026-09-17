import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:cupitor/history_store.dart';

/// The store keeps the table in memory as well as on disk so the URL bar can
/// answer a keystroke without waiting. That second copy is the risky part:
/// every write has to leave the two agreeing, including when two page loads
/// land at once — which is the normal case on a single-page site, where a
/// page load and an in-page navigation both fire.
void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, _) => HistoryStore.createSchema(d),
      ),
    );
    await HistoryStore.initWithDatabase(db);
  });

  tearDown(() async => db.close());

  List<String> urls() =>
      HistoryStore.entries.value.map((e) => e.url).toList(growable: false);

  Future<List<String>> urlsOnDisk() async {
    final rows = await db.query('history', orderBy: 'last_visited DESC');
    return [for (final r in rows) r['url'] as String];
  }

  group('recording a visit', () {
    test('a new page lands at the head of the list and on disk', () async {
      await HistoryStore.record('https://a.test/', title: 'A');
      expect(urls(), ['https://a.test/']);
      expect(await urlsOnDisk(), ['https://a.test/']);
      expect(HistoryStore.entries.value.single.title, 'A');
    });

    test('a page that is not http(s) is ignored', () async {
      await HistoryStore.record('about:blank');
      await HistoryStore.record('file:///tmp/x.html');
      expect(urls(), isEmpty);
      expect(await urlsOnDisk(), isEmpty);
    });

    test('revisiting moves a page to the head rather than adding a row',
        () async {
      await HistoryStore.record('https://a.test/');
      await HistoryStore.record('https://b.test/');
      await HistoryStore.record('https://a.test/');
      expect(urls(), ['https://a.test/', 'https://b.test/']);
      expect(await urlsOnDisk(), hasLength(2));
    });

    test('the title arriving after the load fills it in without counting a '
        'second visit', () async {
      // This is the real sequence: the page is recorded, then its title is
      // read off the WebView a moment later.
      await HistoryStore.record('https://a.test/');
      await HistoryStore.record('https://a.test/', title: 'Now titled');
      final e = HistoryStore.entries.value.single;
      expect(e.title, 'Now titled');
      expect(e.visitCount, 1);
    });

    test('an empty title never erases one already known', () async {
      await HistoryStore.record('https://a.test/', title: 'Kept');
      await HistoryStore.record('https://a.test/');
      expect(HistoryStore.entries.value.single.title, 'Kept');
    });
  });

  group('two visits in flight at once', () {
    // The defect this pins: reading the entry's position before awaiting the
    // write, then acting on that position afterwards. The second call resumes
    // holding a view of a list the first one has already reordered, so it
    // removes an unrelated page and leaves a stale copy of its own.
    test('two revisits neither duplicate a page nor lose one', () async {
      await HistoryStore.record('https://a.test/');
      await HistoryStore.record('https://b.test/');
      await HistoryStore.record('https://c.test/');

      await Future.wait([
        HistoryStore.record('https://a.test/'),
        HistoryStore.record('https://b.test/'),
      ]);

      expect(urls(), hasLength(3));
      expect(urls().toSet(), {
        'https://a.test/',
        'https://b.test/',
        'https://c.test/',
      });
      expect(await urlsOnDisk(), hasLength(3));
    });

    test('two first-time visits do not leave a duplicate in memory', () async {
      await Future.wait([
        HistoryStore.record('https://x.test/'),
        HistoryStore.record('https://y.test/'),
      ]);
      expect(urls(), hasLength(2));
      expect(urls().toSet(), {'https://x.test/', 'https://y.test/'});
      // The disk de-dupes on the primary key regardless, so the in-memory
      // count is the one that can drift.
      expect(await urlsOnDisk(), hasLength(2));
    });

    test('the same page reported twice at once stays one row', () async {
      await Future.wait([
        HistoryStore.record('https://a.test/'),
        HistoryStore.record('https://a.test/', title: 'A'),
      ]);
      expect(urls(), ['https://a.test/']);
      expect(HistoryStore.entries.value.single.title, 'A');
    });

    test('a removal racing a visit does not take the wrong page with it',
        () async {
      await HistoryStore.record('https://a.test/');
      await HistoryStore.record('https://b.test/');
      await Future.wait([
        HistoryStore.record('https://a.test/'),
        HistoryStore.remove('https://b.test/'),
      ]);
      expect(urls(), contains('https://a.test/'));
      expect(urls(), isNot(contains('https://b.test/')));
    });
  });

  group('removing', () {
    test('one page goes from both copies', () async {
      await HistoryStore.record('https://a.test/');
      await HistoryStore.record('https://b.test/');
      await HistoryStore.remove('https://a.test/');
      expect(urls(), ['https://b.test/']);
      expect(await urlsOnDisk(), ['https://b.test/']);
    });

    test('clearing empties both copies', () async {
      await HistoryStore.record('https://a.test/');
      await HistoryStore.clear();
      expect(urls(), isEmpty);
      expect(await urlsOnDisk(), isEmpty);
    });

    test('removing a page that was never there changes nothing', () async {
      await HistoryStore.record('https://a.test/');
      await HistoryStore.remove('https://nope.test/');
      expect(urls(), ['https://a.test/']);
    });
  });

  group('suggestions come off the live list', () {
    test('a page recorded this second is suggestible immediately', () async {
      await HistoryStore.record('https://svtplay.se/', title: 'SVT Play');
      expect(HistoryStore.suggest('svt').single.url, 'https://svtplay.se/');
    });

    test('a removed page stops being suggested', () async {
      await HistoryStore.record('https://svtplay.se/');
      await HistoryStore.remove('https://svtplay.se/');
      expect(HistoryStore.suggest('svt'), isEmpty);
    });
  });
}
