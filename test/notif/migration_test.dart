import 'package:cupitor/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Frozen, verbatim copy of the real v6 DDL — copied from
/// `CupitorDb.createSchema` in lib/db.dart *before* it grew the v7
/// (notif_*) tables, back when it was exactly the v6 schema. This fixture
/// must NOT be updated to track future schema changes: its whole purpose
/// is to pin what a real v6 database on a user's device looks like, so the
/// v6→v7 migration test proves real-world zero data loss.
Future<void> _createV6Fixture(Database db) async {
  await db.execute('''
          CREATE TABLE profiles (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
            created_at INTEGER NOT NULL
          )''');
  await db.insert('profiles', {
    'id': 1,
    'name': 'Default',
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });
  await db.execute('''
          CREATE TABLE tags (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            name       TEXT NOT NULL COLLATE NOCASE,
            color      TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE(profile_id, name)
          )''');
  await db.execute('CREATE INDEX idx_tags_profile ON tags(profile_id)');
  await db.execute('''
          CREATE TABLE pages (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            surface      TEXT NOT NULL,
            locator      TEXT NOT NULL,
            title        TEXT,
            last_seen_at INTEGER NOT NULL,
            UNIQUE(surface, locator)
          )''');
  await db.execute('''
          CREATE TABLE sentences (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            page_id    INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
            text       TEXT NOT NULL,
            prev_fp    TEXT,
            next_fp    TEXT,
            mask       TEXT,
            created_at INTEGER NOT NULL,
            UNIQUE(profile_id, page_id, text, prev_fp, next_fp)
          )''');
  await db.execute('CREATE INDEX idx_sentences_page ON sentences(page_id)');
  await db.execute('CREATE INDEX idx_sentences_profile ON sentences(profile_id)');
  await db.execute('''
          CREATE TABLE sentence_tags (
            sentence_id INTEGER NOT NULL REFERENCES sentences(id) ON DELETE CASCADE,
            tag_id      INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (sentence_id, tag_id)
          )''');
  await db.execute('CREATE INDEX idx_st_tag ON sentence_tags(tag_id)');
  await db.execute('''
          CREATE TABLE sentence_media (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            sentence_id INTEGER NOT NULL REFERENCES sentences(id) ON DELETE CASCADE,
            kind        TEXT NOT NULL,
            sha1        TEXT NOT NULL,
            url         TEXT,
            mime_type   TEXT,
            filename    TEXT NOT NULL,
            size_bytes  INTEGER,
            created_at  INTEGER NOT NULL
          )''');
  await db.execute('CREATE INDEX idx_sentence_media_sentence ON sentence_media(sentence_id)');
  await db.execute('CREATE INDEX idx_sentence_media_sha1 ON sentence_media(sha1)');
  await db.execute('''
          CREATE TABLE playlists (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )''');
  await db.execute('''
          CREATE TABLE playlist_items (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            playlist_id   INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
            sentence_text TEXT NOT NULL,
            book_key      TEXT,
            book_title    TEXT,
            chapter_idx   INTEGER,
            chapter_title TEXT,
            position      INTEGER NOT NULL,
            created_at    INTEGER NOT NULL
          )''');
  await db.execute('CREATE INDEX idx_playlist_items_playlist ON playlist_items(playlist_id)');

  // Seed one real-looking row into EVERY v6 table, respecting FKs:
  // profile -> tag -> page -> sentence -> sentence_tags link -> sentence_media;
  // playlist -> playlist_item.
  final now = DateTime.now().millisecondsSinceEpoch;
  final tagId = await db.insert('tags', {
    'profile_id': 1,
    'name': 'vocab',
    'color': '#ff0000',
    'created_at': now,
  });
  final pageId = await db.insert('pages', {
    'surface': 'epub',
    'locator': 'epub:abc123:0',
    'title': 'Chapter One',
    'last_seen_at': now,
  });
  final sentenceId = await db.insert('sentences', {
    'profile_id': 1,
    'page_id': pageId,
    'text': 'Il fait beau aujourd\'hui.',
    'prev_fp': 'prevfp',
    'next_fp': 'nextfp',
    'mask': 'Il ___ beau aujourd\'hui.',
    'created_at': now,
  });
  await db.insert('sentence_tags', {
    'sentence_id': sentenceId,
    'tag_id': tagId,
  });
  await db.insert('sentence_media', {
    'sentence_id': sentenceId,
    'kind': 'image',
    'sha1': 'deadbeef00112233',
    'url': null,
    'mime_type': 'image/png',
    'filename': 'weather.png',
    'size_bytes': 1024,
    'created_at': now,
  });
  final playlistId = await db.insert('playlists', {
    'name': 'French basics',
    'created_at': now,
  });
  await db.insert('playlist_items', {
    'playlist_id': playlistId,
    'sentence_text': 'Il fait beau aujourd\'hui.',
    'book_key': 'abc123',
    'book_title': 'Le Petit Prince',
    'chapter_idx': 0,
    'chapter_title': 'Chapter One',
    'position': 0,
    'created_at': now,
  });
}

const _v6Tables = [
  'profiles',
  'tags',
  'pages',
  'sentences',
  'sentence_tags',
  'sentence_media',
  'playlists',
  'playlist_items',
];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v6→v7 migrates with zero loss to pre-existing tables', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await _createV6Fixture(db);

    // Snapshot BEFORE migration: schema SQL of all pre-existing tables +
    // full row dumps.
    final schemaBefore = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY name");
    final rowsBefore = {
      for (final t in _v6Tables) t: await db.query(t),
    };

    await CupitorDb.runMigrations(db, 6, 7);

    // New tables exist.
    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toSet();
    expect(
        tables,
        containsAll([
          'notif_schedules',
          'notif_lists',
          'notif_items',
          'notif_events',
        ]));

    // Seeds present, ordered, exactly 7.
    final seeds = await db.query('notif_schedules', orderBy: 'id ASC');
    expect(seeds, hasLength(7));
    expect(seeds.first['builtin_key'], 'ebbinghaus');

    // ZERO LOSS: schema SQL of every pre-existing table/index unchanged...
    final schemaAfter = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY name");
    final preExistingAfter = schemaAfter
        .where((r) =>
            !(r['name'] as String).startsWith('notif_') &&
            !(r['name'] as String).startsWith('idx_notif_'))
        .toList();
    expect(preExistingAfter, schemaBefore);

    // ...and every row in every pre-existing table survives byte-identical.
    for (final t in _v6Tables) {
      expect(await db.query(t), rowsBefore[t], reason: 'table $t');
    }

    // Referential integrity intact.
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

    await db.close();
  });

  test('seeding is idempotent', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await _createV6Fixture(db);
    await CupitorDb.runMigrations(db, 6, 7);
    await CupitorDb.seedBuiltinSchedules(db);
    final seeds = await db.query('notif_schedules');
    expect(seeds, hasLength(7));
    await db.close();
  });

  test('fresh createSchema also has notif tables and seeds', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await CupitorDb.createSchema(db);
    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toSet();
    expect(
        tables,
        containsAll([
          'notif_schedules',
          'notif_lists',
          'notif_items',
          'notif_events',
        ]));
    final seeds = await db.query('notif_schedules');
    expect(seeds, hasLength(7));
    await db.close();
  });
  test('v11 rollback preserves notification data and pauses old playlist calls', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await CupitorDb.createSchema(db);
    // Exact additive columns introduced by the previously shipped v11.
    await db.execute("ALTER TABLE notif_lists ADD COLUMN delivery TEXT NOT NULL DEFAULT 'notification'");
    await db.execute('ALTER TABLE notif_lists ADD COLUMN call_config TEXT');
    for (final delivery in ['call', 'notification']) {
      await db.insert('notif_lists', {'profile_id': 1, 'name': delivery, 'source': 'webpage',
        'external_key': delivery, 'status': 'active', 'delivery': delivery,
        'call_config': delivery == 'call' ? '{"max_retries":3}' : null,
        'created_at': 1, 'updated_at': 1});
    }
    final before = (await db.query('notif_lists', where: "delivery = 'notification'")).single;
    await CupitorDb.runMigrations(db, 11, 12);
    final call = (await db.query('notif_lists', where: "external_key = 'call'")).single;
    expect(call['status'], 'paused'); expect(call['delivery'], 'notification'); expect(call['call_config'], isNull);
    expect((await db.query('notif_lists', where: "external_key = 'notification'")).single, before);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await db.close();
  });

}
