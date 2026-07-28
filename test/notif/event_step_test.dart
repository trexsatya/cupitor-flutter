import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/notif_ops.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// v10: notif_events.step — the ladder rung a fire actually SHOWED, so a
/// late grade applies from what the user saw instead of the auto-advanced
/// item row (which skipped rungs and dropped grades on auto-graduated
/// items — a lost review).
void main() {
  late tz.Location ny;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  test('v9→v10 migration adds notif_events.step with zero loss; idempotent',
      () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE notif_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id INTEGER NOT NULL,
        fired_at INTEGER NOT NULL,
        responded_at INTEGER, grade INTEGER, source TEXT)''');
    await db.insert('notif_events', {
      'item_id': 7, 'fired_at': 1000, 'responded_at': 2000, 'grade': 3,
      'source': 'action',
    });
    await CupitorDb.runMigrations(db, 9, 10);
    final cols = await db.rawQuery('PRAGMA table_info(notif_events)');
    expect(cols.any((c) => c['name'] == 'step'), isTrue);
    final row = (await db.query('notif_events')).single;
    expect(row['fired_at'], 1000);
    expect(row['grade'], 3);
    expect(row['step'], isNull); // old rows: unknown shown step
    await CupitorDb.runMigrations(db, 9, 10); // no double-ALTER
    await db.close();
  });

  test('resetItemToStart clears last_fired_at so old fire events cannot be '
      'attributed to a fresh ladder', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 10,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => CupitorDb.createSchema(d)));
    final dao = NotifDao(db);
    final now = tz.TZDateTime(ny, 2026, 7, 28, 10);
    final s = await dao.scheduleByKey('ebbinghaus');
    final l = await dao.createList(
        profileId: 1, name: 'L', source: 'app', scheduleId: s!.id);
    final item = await dao.insertItem(
        listId: l.id, title: 'x', position: 0, step: 3,
        nextDueAt: now.millisecondsSinceEpoch + 1000);
    await dao.updateItem(item.id, {'last_fired_at': 12345});

    await resetItemToStart(
        dao, (await dao.itemById(item.id))!, s, now, WakingWindow.defaults);
    final after = (await dao.itemById(item.id))!;
    expect(after.step, 0);
    expect(after.lastFiredAt, isNull);
    await db.close();
  });
}
