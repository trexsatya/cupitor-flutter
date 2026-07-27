import 'dart:convert';

import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_bridge.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/notification_service.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'fake_notif_channel.dart';

/// v9: list-level open_url — items without their own deep link inherit it.
void main() {
  late tz.Location ny;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  test('v8→v9 migration adds open_url with zero loss; idempotent', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE notif_lists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        profile_id INTEGER NOT NULL,
        name TEXT NOT NULL, source TEXT NOT NULL, external_key TEXT,
        schedule_id INTEGER, intro_schedule_id INTEGER,
        status TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
        next_fire_at INTEGER, last_fired_at INTEGER,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''');
    await db.insert('notif_lists', {
      'profile_id': 1, 'name': 'kept', 'source': 'app', 'status': 'active',
      'created_at': 1, 'updated_at': 2,
    });
    await CupitorDb.runMigrations(db, 8, 9);
    final row = (await db.query('notif_lists')).single;
    expect(row['name'], 'kept');
    expect(row['open_url'], isNull);
    await CupitorDb.runMigrations(db, 8, 9); // no double-ALTER
    await db.close();
  });

  group('with schema', () {
    late Database db;
    late NotifDao dao;
    late tz.TZDateTime now;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
              version: 9,
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
              onCreate: (d, _) => CupitorDb.createSchema(d)));
      dao = NotifDao(db);
      now = tz.TZDateTime(ny, 2026, 7, 27, 10);
    });
    tearDown(() => db.close());

    test('fire payload: item open_url wins, list open_url fills in',
        () async {
      final channel = FakeNotifChannel();
      final service = NotificationService(
        channel: channel,
        dao: () async => dao,
        window: () => WakingWindow.defaults,
        perFireCap: () => 5,
        now: () => now,
        maxArmed: 60,
      );
      final s = await dao.scheduleByKey('cepeda2x');
      final l = await dao.createList(
          profileId: 1, name: 'L', source: 'app', scheduleId: s!.id,
          openUrl: 'https://x/list');
      final ms = now.millisecondsSinceEpoch;
      await dao.insertItem(
          listId: l.id, title: 'inherits', position: 0,
          nextDueAt: ms + 60000);
      await dao.insertItem(
          listId: l.id, title: 'own', position: 1, openUrl: 'https://x/own',
          nextDueAt: ms + 120000);

      await service.rearm();
      final fires = channel.scheduled.where((f) => !f.isSummary).toList();
      String openUrlOf(String title) =>
          (jsonDecode(fires.firstWhere((f) => f.title == title).payloadJson)
              as Map<String, dynamic>)['open_url'] as String;
      expect(openUrlOf('inherits'), 'https://x/list');
      expect(openUrlOf('own'), 'https://x/own');
    });

    test('bridge: createList stores it, syncItems sets/clears/keeps it',
        () async {
      final events = <(String, Map<String, Object?>)>[];
      final bridge = NotifBridge(
        dao: () async => dao,
        activeProfileId: () => 1,
        emit: (e, d) => events.add((e, d)),
        capabilities: () async => const NotifCapabilities(
            supported: true, permission: 'unknown', exactAlarms: false,
            actions: false, platform: 'test'),
        requestPermission: () async => 'unknown',
        window: () => WakingWindow.defaults,
        now: () => now,
      );
      Map<String, Object?> lastAck() =>
          events.lastWhere((e) => e.$1 == 'cupitorNotifAck').$2;

      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'k', 'name': 'L',
        'open_url': 'https://x/list',
        'items': [{'external_id': 'a', 'title': 'A'}],
      }));
      expect(lastAck()['ok'], true);
      var list = (await dao.listsForProfile(1)).single;
      expect(list.openUrl, 'https://x/list');

      // Exposed in the lists payload.
      final payload = events.lastWhere((e) => e.$1 == 'cupitorNotifLists').$2;
      expect(((payload['lists'] as List).single as Map)['open_url'],
          'https://x/list');

      // Absent key → unchanged.
      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'external_key': 'k',
        'items': [{'external_id': 'a', 'title': 'A'}],
      }));
      list = (await dao.listsForProfile(1)).single;
      expect(list.openUrl, 'https://x/list');

      // Present string → updated; explicit null → cleared.
      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'external_key': 'k', 'open_url': 'https://y',
        'items': [{'external_id': 'a', 'title': 'A'}],
      }));
      expect((await dao.listsForProfile(1)).single.openUrl, 'https://y');
      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'external_key': 'k', 'open_url': null,
        'items': [{'external_id': 'a', 'title': 'A'}],
      }));
      expect((await dao.listsForProfile(1)).single.openUrl, isNull);

      // Non-string → bad_payload, nothing changed.
      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'k2', 'name': 'L2',
        'open_url': 5,
        'items': [{'external_id': 'a', 'title': 'A'}],
      }));
      expect(lastAck()['error'], 'bad_payload');
      expect(await dao.listByExternalKey(1, 'k2'), isNull);
    });
  });
}
