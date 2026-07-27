import 'dart:convert';

import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_bridge.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/notif_ops.dart';
import 'package:cupitor/notif/notification_service.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'fake_notif_channel.dart';

/// v8 intro-cadence feature: items drip-fired by a recurring intro schedule,
/// each seeded onto the series ladder at its introduction.
void main() {
  late tz.Location ny;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  group('v7→v8 migration', () {
    test('ALTERs a real v7 notif_lists with zero loss; idempotent', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      // Frozen v7 shape (no intro_schedule_id).
      await db.execute('''
        CREATE TABLE profiles (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE COLLATE NOCASE,
          created_at INTEGER NOT NULL)''');
      await db.insert('profiles', {'id': 1, 'name': 'Default', 'created_at': 1});
      await db.execute('''
        CREATE TABLE notif_schedules (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL, kind TEXT NOT NULL,
          builtin_key TEXT UNIQUE, config TEXT NOT NULL,
          created_at INTEGER NOT NULL)''');
      await db.execute('''
        CREATE TABLE notif_lists (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
          name TEXT NOT NULL, source TEXT NOT NULL, external_key TEXT,
          schedule_id INTEGER REFERENCES notif_schedules(id),
          status TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
          next_fire_at INTEGER, last_fired_at INTEGER,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          UNIQUE(profile_id, external_key))''');
      await db.insert('notif_lists', {
        'profile_id': 1, 'name': 'kept', 'source': 'app', 'status': 'active',
        'cursor': 3, 'next_fire_at': 42, 'created_at': 1, 'updated_at': 2,
      });

      await CupitorDb.runMigrations(db, 7, 8);
      final cols = await db.rawQuery('PRAGMA table_info(notif_lists)');
      expect(cols.map((c) => c['name']), contains('intro_schedule_id'));
      final row = (await db.query('notif_lists')).single;
      expect(row['name'], 'kept');
      expect(row['cursor'], 3);
      expect(row['next_fire_at'], 42);
      expect(row['intro_schedule_id'], isNull);

      // Second run must not double-ALTER (protects the v6 chain, whose
      // createNotifTables step already includes the column).
      await CupitorDb.runMigrations(db, 7, 8);
      await db.close();
    });

    test('fresh createSchema has the column', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
              version: 8, onCreate: (d, _) => CupitorDb.createSchema(d)));
      final cols = await db.rawQuery('PRAGMA table_info(notif_lists)');
      expect(cols.map((c) => c['name']), contains('intro_schedule_id'));
      await db.close();
    });
  });

  group('ops + DAO', () {
    late Database db;
    late NotifDao dao;
    late tz.TZDateTime now;
    const w = WakingWindow.defaults;
    final tue9 = <String, int>{}; // filled in setUp

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
              version: 8,
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
              onCreate: (d, _) => CupitorDb.createSchema(d)));
      dao = NotifDao(db);
      now = tz.TZDateTime(ny, 2026, 7, 27, 10); // Monday 10:00
      tue9['ms'] = tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch;
    });
    tearDown(() => db.close());

    test('applyScheduleToList with intro: queue stays unseeded, fire anchored',
        () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final intro = await dao.scheduleByKey('daily_0900');
      final list =
          await dao.createList(profileId: 1, name: 'l', source: 'app');
      final fresh =
          await dao.insertItem(listId: list.id, title: 'fresh', position: 0);
      final veteran = await dao.insertItem(
          listId: list.id, title: 'vet', position: 1, step: 2, nextDueAt: 99);

      await applyScheduleToList(
          dao, (await dao.listById(list.id))!, series!, now, w,
          intro: intro);
      final l = await dao.listById(list.id);
      expect(l!.scheduleId, series.id);
      expect(l.introScheduleId, intro!.id);
      expect(l.nextFireAt, tue9['ms']); // next daily 09:00 after Mon 10:00
      expect((await dao.itemById(fresh.id))!.nextDueAt, isNull); // queued
      expect((await dao.itemById(veteran.id))!.nextDueAt, 99); // lossless

      // Queue = only 'fresh' (veteran already has state).
      expect((await dao.unintroducedItems(list.id)).map((i) => i.title),
          ['fresh']);
    });

    test('applyScheduleToList intro with empty queue is dormant; switching '
        'to recurring clears the intro', () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final intro = await dao.scheduleByKey('daily_0900');
      final list =
          await dao.createList(profileId: 1, name: 'l', source: 'app');
      await dao.insertItem(
          listId: list.id, title: 'seeded', position: 0, nextDueAt: 5);

      await applyScheduleToList(
          dao, (await dao.listById(list.id))!, series!, now, w,
          intro: intro);
      var l = await dao.listById(list.id);
      expect(l!.nextFireAt, isNull); // nothing to introduce

      await applyScheduleToList(dao, l, intro!, now, w); // recurring main
      l = await dao.listById(list.id);
      expect(l!.introScheduleId, isNull);
      expect(l.nextFireAt, tue9['ms']);
    });

    test('ensureIntroArmed wakes a dormant cadence only when queued',
        () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final intro = await dao.scheduleByKey('daily_0900');
      final list = await dao.createList(
          profileId: 1, name: 'l', source: 'app',
          scheduleId: series!.id, introScheduleId: intro!.id);

      await ensureIntroArmed(dao, (await dao.listById(list.id))!, now, w);
      expect((await dao.listById(list.id))!.nextFireAt, isNull); // empty

      await dao.insertItem(listId: list.id, title: 'q', position: 0);
      await ensureIntroArmed(dao, (await dao.listById(list.id))!, now, w);
      expect((await dao.listById(list.id))!.nextFireAt, tue9['ms']);

      // Already armed → untouched even with a different clock.
      final later = tz.TZDateTime(ny, 2026, 7, 29, 10);
      await ensureIntroArmed(dao, (await dao.listById(list.id))!, later, w);
      expect((await dao.listById(list.id))!.nextFireAt, tue9['ms']);
    });

    test('resume re-anchors the intro cadence; drained queue stays dormant',
        () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final intro = await dao.scheduleByKey('daily_0900');
      final list = await dao.createList(
          profileId: 1, name: 'l', source: 'app',
          scheduleId: series!.id, introScheduleId: intro!.id, nextFireAt: 7);
      await dao.insertItem(listId: list.id, title: 'q', position: 0);

      await setListStatus(dao, (await dao.listById(list.id))!, 'paused', now, w);
      await setListStatus(dao, (await dao.listById(list.id))!, 'active', now, w);
      expect((await dao.listById(list.id))!.nextFireAt, tue9['ms']);

      // Drain the queue, resume again → dormant.
      final q = await dao.unintroducedItems(list.id);
      await dao.updateItem(q.single.id, {'next_due_at': 1});
      await setListStatus(dao, (await dao.listById(list.id))!, 'paused', now, w);
      await setListStatus(dao, (await dao.listById(list.id))!, 'active', now, w);
      expect((await dao.listById(list.id))!.nextFireAt, isNull);
    });

    test('listsUsingSchedule counts intro users (delete guard)', () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final custom = await dao.createCustomSchedule(
          name: 'drip', kind: 'recurring',
          config: {'every_waking_hours': 2, 'per_fire': 1});
      await dao.createList(
          profileId: 1, name: 'l', source: 'app',
          scheduleId: series!.id, introScheduleId: custom.id);
      expect(await dao.listsUsingSchedule(custom.id), hasLength(1));
      expect(await dao.deleteCustomSchedule(custom.id), isFalse);
    });
  });

  group('delivery engine', () {
    late Database db;
    late NotifDao dao;
    late FakeNotifChannel channel;
    late NotificationService service;
    late tz.TZDateTime now;
    int nowMs() => now.millisecondsSinceEpoch;
    const w = WakingWindow.defaults;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
              version: 8,
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
              onCreate: (d, _) => CupitorDb.createSchema(d)));
      dao = NotifDao(db);
      channel = FakeNotifChannel();
      now = tz.TZDateTime(ny, 2026, 7, 27, 10); // Monday 10:00
      service = NotificationService(
        channel: channel,
        dao: () async => dao,
        window: () => w,
        perFireCap: () => 5,
        now: () => now,
        maxArmed: 60,
      );
    });
    tearDown(() => db.close());

    /// cepeda2x ladder (offsets[0]=1) + daily_0900 intro, 3 queued items.
    Future<NotifListRow> introList({int? nextFireAt}) async {
      final series = await dao.scheduleByKey('cepeda2x');
      final intro = await dao.scheduleByKey('daily_0900');
      final l = await dao.createList(
          profileId: 1, name: 'Drip', source: 'app',
          scheduleId: series!.id, introScheduleId: intro!.id,
          nextFireAt: nextFireAt);
      for (var i = 0; i < 3; i++) {
        await dao.insertItem(listId: l.id, title: 'q$i', position: i);
      }
      return l;
    }

    test('rearm arms the head of the intro queue with actions', () async {
      await introList(nextFireAt: nowMs() + 3600000);
      await service.rearm();
      final fires = channel.scheduled.where((f) => !f.isSummary).toList();
      expect(fires, hasLength(1)); // per_fire 1 → only the queue head
      expect(fires.single.title, 'q0');
      expect(fires.single.whenMs, nowMs() + 3600000);
      expect(fires.single.withActions, isTrue); // series item from first show
    });

    test('sweep within grace: introduces, seeds ladder, reschedules cadence',
        () async {
      final l = await introList(nextFireAt: nowMs() - 30 * 60000); // 09:30
      await service.sweep();

      final posted = channel.shown.where((f) => !f.isSummary).toList();
      expect(posted.map((f) => f.title), ['q0']);
      final items = await dao.itemsForList(l.id);
      final q0 = items.singleWhere((i) => i.title == 'q0');
      // Seeded at sweep time: next repetition = now + offsets[0] (1 waking h).
      expect(q0.step, 0);
      expect(q0.nextDueAt, nowMs() + 3600000);
      expect(q0.lastFiredAt, nowMs());
      expect((await dao.lastEventForItem(q0.id))!.firedAt, nowMs());
      // q1/q2 still queued; cadence re-anchored to tomorrow 09:00.
      expect(items.where((i) => i.nextDueAt == null), hasLength(2));
      final re = await dao.listById(l.id);
      expect(re!.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
      expect(re.lastFiredAt, nowMs());
    });

    test('stale intro fire is skipped silently, cadence continues', () async {
      // Due at 05:00 → 5 waking hours late, beyond the 2h grace.
      final l = await introList(
          nextFireAt:
              tz.TZDateTime(ny, 2026, 7, 27, 5).millisecondsSinceEpoch);
      await service.sweep();
      expect(channel.shown.where((f) => !f.isSummary), isEmpty);
      expect(await dao.unintroducedItems(l.id), hasLength(3)); // untouched
      expect((await dao.listById(l.id))!.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
    });

    test('cadence goes dormant when the queue drains', () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final intro = await dao.scheduleByKey('daily_0900');
      final l = await dao.createList(
          profileId: 1, name: 'Drip', source: 'app',
          scheduleId: series!.id, introScheduleId: intro!.id,
          nextFireAt: nowMs() - 60000);
      await dao.insertItem(listId: l.id, title: 'only', position: 0);
      await service.sweep();
      final re = await dao.listById(l.id);
      expect(re!.nextFireAt, isNull); // dormant — nothing left to introduce
      // The introduced item now lives on its own ladder.
      final item = (await dao.itemsForList(l.id)).single;
      expect(item.nextDueAt, nowMs() + 3600000);
    });
  });

  group('bridge', () {
    late Database db;
    late NotifDao dao;
    late List<(String, Map<String, Object?>)> events;
    late NotifBridge bridge;
    late tz.TZDateTime now;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
              version: 8,
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
              onCreate: (d, _) => CupitorDb.createSchema(d)));
      dao = NotifDao(db);
      events = [];
      now = tz.TZDateTime(ny, 2026, 7, 27, 10);
      bridge = NotifBridge(
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
    });
    tearDown(() => db.close());

    Map<String, Object?> lastAck() =>
        events.lastWhere((e) => e.$1 == 'cupitorNotifAck').$2;

    Future<void> create(Map<String, Object?> extra) => bridge.handle(jsonEncode({
          'op': 'createList', 'request_id': 'r1',
          'external_key': 'k1', 'name': 'Drip',
          'items': [
            {'external_id': 'a', 'title': 'A'},
            {'external_id': 'b', 'title': 'B'},
          ],
          ...extra,
        }));

    test('createList with intro: items unseeded, cadence armed, key exposed',
        () async {
      await create({
        'schedule_key': 'cepeda2x',
        'intro_schedule_key': 'daily_0900',
      });
      expect(lastAck()['ok'], true);
      final list = (await dao.listsForProfile(1)).single;
      expect(list.introScheduleId, isNotNull);
      expect(list.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
      expect(await dao.unintroducedItems(list.id), hasLength(2));

      final payload =
          events.lastWhere((e) => e.$1 == 'cupitorNotifLists').$2;
      final l = ((payload['lists'] as List).single as Map);
      expect(l['intro_schedule_key'], 'daily_0900');
      for (final item in l['items'] as List) {
        expect((item as Map)['next_due_at'], isNull);
      }
    });

    test('bad_intro: recurring main, or series intro', () async {
      await create({
        'schedule_key': 'daily_0900',
        'intro_schedule_key': 'twice_daily',
      });
      expect(lastAck()['error'], 'bad_intro');
      await create({
        'schedule_key': 'cepeda2x',
        'intro_schedule_key': 'pimsleur',
      });
      expect(lastAck()['error'], 'bad_intro');
      expect(await dao.listsForProfile(1), isEmpty); // nothing committed
    });

    test('unknown intro key → unknown_schedule', () async {
      await create({
        'schedule_key': 'cepeda2x',
        'intro_schedule_key': 'nope',
      });
      expect(lastAck()['error'], 'unknown_schedule');
    });

    test('syncItems wakes a dormant intro cadence', () async {
      await create({
        'schedule_key': 'cepeda2x',
        'intro_schedule_key': 'daily_0900',
      });
      final list = (await dao.listsForProfile(1)).single;
      // Simulate a drained queue: seed both items, cadence dormant.
      for (final i in await dao.itemsForList(list.id)) {
        await dao.updateItem(i.id, {'next_due_at': 1});
      }
      await dao.updateList(list.id, {'next_fire_at': null});

      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'request_id': 'r2', 'external_key': 'k1',
        'items': [
          {'external_id': 'a', 'title': 'A'},
          {'external_id': 'b', 'title': 'B'},
          {'external_id': 'c', 'title': 'C (new)'},
        ],
      }));
      expect(lastAck()['ok'], true);
      final re = await dao.listById(list.id);
      expect(re!.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
      // New item joined the queue unseeded; existing kept their state.
      expect((await dao.unintroducedItems(list.id)).map((i) => i.externalId),
          ['c']);
    });

    test('setSchedule with intro sets it; absent intro clears and seeds',
        () async {
      await create({'schedule_key': 'cepeda2x'});
      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'request_id': 'r3', 'external_key': 'k1',
        'schedule_key': 'cepeda2x', 'intro_schedule_key': 'daily_0900',
      }));
      expect(lastAck()['ok'], true);
      var list = (await dao.listsForProfile(1)).single;
      expect(list.introScheduleId, isNotNull);

      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'request_id': 'r4', 'external_key': 'k1',
        'schedule_key': 'cepeda2x',
      }));
      list = (await dao.listsForProfile(1)).single;
      expect(list.introScheduleId, isNull);
      expect(list.nextFireAt, isNull);
    });
  });
}
