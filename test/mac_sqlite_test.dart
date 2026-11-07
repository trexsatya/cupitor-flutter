import 'dart:io';

import 'package:cupitor/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  test('macOS SQLite opens the tagging schema and persists tags', () async {
    if (!Platform.isMacOS) return;

    initializeSqliteForPlatform();
    initializeSqliteForPlatform(); // Safe to call on repeated startup paths.
    expect(isSqlitePlatform, isTrue);

    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 12,
      onCreate: (database, _) => CupitorDb.createSchema(database),
    );
    addTearDown(db.close);

    final profiles = await db.query('profiles');
    expect(profiles, hasLength(1));
    expect(profiles.single['name'], 'Default');

    final tagId = await db.insert('tags', {
      'profile_id': CupitorDb.defaultProfileId,
      'name': 'Mac EPUB',
      'color': '#ffffff',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    expect(tagId, greaterThan(0));

    final rows = await db.query(
      'tags',
      where: 'id = ?',
      whereArgs: [tagId],
    );
    expect(rows, hasLength(1));
    expect(rows.single['name'], 'Mac EPUB');
  });
}
