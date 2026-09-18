import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:cupitor/db.dart';

/// The sentences table's identity compares text byte-for-byte, but the text
/// of a multi-line sentence depends on how its line breaks were read when it
/// was captured. These pin the rule that keeps one sentence one row.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(Database, int)> fresh() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    // The ffi factory hands every caller the same in-memory connection
    // until it is closed; without this the next test's schema collides.
    addTearDown(db.close);
    await CupitorDb.createSchema(db);
    final pageId = await db.insert('pages', {
      'surface': 'web',
      'locator': 'https://example.test/poem',
      'title': 'Poem',
      'last_seen_at': 0,
    });
    return (db, pageId);
  }

  Future<int> upsert(Database db, int pageId, String text,
      {String? prevFp, String? nextFp}) {
    return upsertSentenceRow(
      db,
      profileId: 1,
      pageId: pageId,
      text: text,
      prevFp: prevFp,
      nextFp: nextFp,
      now: 1,
    );
  }

  Future<List<String>> texts(Database db) async {
    final rows = await db.query('sentences', columns: ['text'], orderBy: 'id');
    return [for (final r in rows) r['text'] as String];
  }

  group('sentenceTextKey', () {
    test('treats every whitespace run as one space and trims', () {
      expect(sentenceTextKey('Line one\nLine two.'), 'Line one Line two.');
      expect(sentenceTextKey('  a \t\n b  '), 'a b');
      expect(sentenceTextKey('One two.'), 'One two.');
    });

    test('keeps everything that is not whitespace', () {
      expect(sentenceTextKey('a.b'), 'a.b');
      expect(sentenceTextKey('redViolet.'), 'redViolet.');
    });
  });

  group('sentenceMatchKey', () {
    test('every reading of the same line pair gives one key', () {
      expect(sentenceMatchKey('Line one\nLine two.'), 'Lineone Linetwo.'.replaceAll(' ', ''));
      expect(sentenceMatchKey('Line one Line two.'), sentenceMatchKey('Line one\nLine two.'));
      expect(sentenceMatchKey('Line oneLine two.'), sentenceMatchKey('Line one\nLine two.'));
    });

    test('text that differs by more than whitespace keeps its own key', () {
      expect(sentenceMatchKey('Han gick hem.') == sentenceMatchKey('Han gick hem!'), isFalse);
    });
  });

  group('matchSentenceRow', () {
    // The rule the capture sheet's lookup and the save share: whichever row
    // the save will land on is the row whose tags the sheet must show.
    final rows = <Map<String, Object?>>[
      {'id': 1, 'text': 'Line one Line two.'},
      {'id': 2, 'text': 'Han gick hem.'},
    ];

    test('an exact reading wins', () {
      expect(matchSentenceRow(rows, 'Han gick hem.')?['id'], 2);
    });

    test('a reading that differs only in whitespace is the same sentence', () {
      expect(matchSentenceRow(rows, 'Line one\nLine two.')?['id'], 1);
      expect(matchSentenceRow(rows, 'Line oneLine two.')?['id'], 1);
    });

    test('an exact match is preferred over a whitespace twin', () {
      final twins = <Map<String, Object?>>[
        {'id': 1, 'text': 'Line one Line two.'},
        {'id': 2, 'text': 'Line one\nLine two.'},
      ];
      expect(matchSentenceRow(twins, 'Line one\nLine two.')?['id'], 2);
    });

    test('the same row is chosen whatever order the query returned', () {
      final a = <String, Object?>{'id': 1, 'text': 'Line one Line two.'};
      final b = <String, Object?>{'id': 2, 'text': 'Line one\nLine two.'};
      // The sheet's lookup and the save read through different queries.
      expect(matchSentenceRow([a, b], 'Line oneLine two.')?['id'], 1);
      expect(matchSentenceRow([b, a], 'Line oneLine two.')?['id'], 1);
    });

    test('a query that names the id column differently still matches', () {
      final rows = <Map<String, Object?>>[
        <String, Object?>{'sid': 9, 'text': 'Line one Line two.'},
        <String, Object?>{'sid': 4, 'text': 'Line one\nLine two.'},
      ];
      expect(matchSentenceRow(rows, 'Line oneLine two.', idKey: 'sid')?['sid'], 4);
    });

    test('text that differs by more than whitespace is no match', () {
      expect(matchSentenceRow(rows, 'Han gick hem!'), isNull);
      expect(matchSentenceRow(const [], 'Han gick hem.'), isNull);
    });
  });

  group('upsertSentenceRow', () {
    test('the same text twice is one row', () async {
      final (db, pageId) = await fresh();
      final a = await upsert(db, pageId, 'Han gick hem.');
      final b = await upsert(db, pageId, 'Han gick hem.');
      expect(b, a);
      expect(await texts(db), ['Han gick hem.']);
    });

    // The case this rule exists for: a sentence saved before line breaks
    // were preserved, tagged again once they are.
    test('a sentence saved with spaces is found again with line breaks and takes the new reading',
        () async {
      final (db, pageId) = await fresh();
      final a = await upsert(db, pageId, 'Line one Line two.');
      final b = await upsert(db, pageId, 'Line one\nLine two.');
      expect(b, a);
      expect(await texts(db), ['Line one\nLine two.']);
    });

    // A page that runs its lines together with no whitespace at all —
    // Google Docs writes `</p><p>` like that — saved before the break was
    // read, then tagged again once it is.
    test('a sentence saved with its lines run together matches the broken reading',
        () async {
      final (db, pageId) = await fresh();
      final a = await upsert(db, pageId, 'Han gick hem,sa hon.');
      final b = await upsert(db, pageId, 'Han gick hem,\nsa hon.');
      expect(b, a);
      expect(await texts(db), ['Han gick hem,\nsa hon.']);
    });

    test('the reverse direction also matches', () async {
      final (db, pageId) = await fresh();
      final a = await upsert(db, pageId, 'Line one\nLine two.');
      final b = await upsert(db, pageId, 'Line one Line two.');
      expect(b, a);
      expect(await texts(db), ['Line one Line two.']);
    });

    // Two rows that only differ in whitespace can already exist. The exact
    // one is used and neither is rewritten — rewriting would collide with
    // the unique index.
    test('an exact match wins over a whitespace twin and nothing is rewritten',
        () async {
      final (db, pageId) = await fresh();
      final spaced = await upsert(db, pageId, 'X Y.');
      final broken = await db.insert('sentences', {
        'profile_id': 1,
        'page_id': pageId,
        'text': 'X\nY.',
        'created_at': 1,
      });
      expect(await upsert(db, pageId, 'X\nY.'), broken);
      expect(await upsert(db, pageId, 'X Y.'), spaced);
      expect(await texts(db), ['X Y.', 'X\nY.']);
    });

    test('different text on the same spot is a different row', () async {
      final (db, pageId) = await fresh();
      final a = await upsert(db, pageId, 'One.');
      final b = await upsert(db, pageId, 'Two.');
      expect(b, isNot(a));
      expect(await texts(db), ['One.', 'Two.']);
    });

    test('the same text between different neighbours is a different row',
        () async {
      final (db, pageId) = await fresh();
      final a = await upsert(db, pageId, 'Ja.', prevFp: 'aaaaaaaa');
      final b = await upsert(db, pageId, 'Ja.', prevFp: 'bbbbbbbb');
      expect(b, isNot(a));
      expect(await texts(db), ['Ja.', 'Ja.']);
    });

    test('whitespace matching never reaches across neighbours', () async {
      final (db, pageId) = await fresh();
      final a = await upsert(db, pageId, 'Line one Line two.', prevFp: 'aaaaaaaa');
      final b = await upsert(db, pageId, 'Line one\nLine two.', prevFp: 'bbbbbbbb');
      expect(b, isNot(a));
      expect(await texts(db), ['Line one Line two.', 'Line one\nLine two.']);
    });
  });
}
