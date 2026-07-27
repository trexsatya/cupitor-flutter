import 'package:cupitor/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('createSchema builds the current schema on a blank database', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await CupitorDb.createSchema(db);
    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toSet();
    expect(
        tables,
        containsAll([
          'profiles', 'tags', 'pages', 'sentences', 'sentence_tags',
          'sentence_media', 'playlists', 'playlist_items',
        ]));
    final profiles = await db.query('profiles');
    expect(profiles, hasLength(1)); // seeded Default profile
    await db.close();
  });
}
