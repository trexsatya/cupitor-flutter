import 'dart:convert';

import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_bridge.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late tz.Location ny;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  late Database db;
  late NotifDao dao;
  late List<(String, Map<String, Object?>)> events;
  late NotifBridge bridge;
  late tz.TZDateTime now;
  var daoAvailable = true;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 7,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, v) => CupitorDb.createSchema(d)));
    dao = NotifDao(db);
    events = [];
    daoAvailable = true;
    now = tz.TZDateTime(ny, 2026, 7, 27, 10);
    bridge = NotifBridge(
      dao: () async => daoAvailable ? dao : null,
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
  Map<String, Object?>? lastEvent(String name) {
    final hits = events.where((e) => e.$1 == name);
    return hits.isEmpty ? null : hits.last.$2;
  }

  // Used from Task 10 onward; defined here so every task's tests share it.
  Future<void> createFrenchList({String scheduleKey = 'ebbinghaus'}) =>
      bridge.handle(jsonEncode({
        'op': 'createList', 'request_id': 'r-create',
        'external_key': 'fr-1', 'name': 'French idioms',
        'schedule_key': scheduleKey,
        'items': [
          {'external_id': 'c1', 'title': 'le dénouement',
           'body': 'the outcome', 'open_url': 'https://x/1',
           'payload': {'deck': 7}},
          {'external_id': 'c2', 'title': 'tomber dans les pommes'},
        ],
      }));

  group('dispatch + acks', () {
    test('malformed JSON → bad_json ack', () async {
      await bridge.handle('{nope');
      expect(lastAck()['ok'], false);
      expect(lastAck()['error'], 'bad_json');
    });
    test('missing op → unknown_op', () async {
      await bridge.handle('{"request_id":"r1"}');
      expect(lastAck()['error'], 'unknown_op');
      expect(lastAck()['request_id'], 'r1');
    });
    test('unknown op → unknown_op, echoes op', () async {
      await bridge.handle('{"op":"frobnicate","request_id":"r2"}');
      expect(lastAck()['op'], 'frobnicate');
      expect(lastAck()['error'], 'unknown_op');
    });
    test('dao unavailable → unsupported, nothing emitted besides ack',
        () async {
      daoAvailable = false;
      await bridge.handle('{"op":"getSchedules","request_id":"r3"}');
      expect(lastAck()['error'], 'unsupported');
      expect(lastEvent('cupitorNotifSchedules'), isNull);
    });
  });

  group('getCapabilities / requestPermission', () {
    test('capabilities returned in ack data', () async {
      await bridge.handle('{"op":"getCapabilities","request_id":"r4"}');
      final ack = lastAck();
      expect(ack['ok'], true);
      final data = ack['data'] as Map<String, Object?>;
      expect(data['supported'], true);
      expect(data['permission'], 'unknown');
      expect(data['platform'], 'test');
    });
    test('requestPermission answers via ack data', () async {
      await bridge.handle('{"op":"requestPermission","request_id":"r5"}');
      expect((lastAck()['data'] as Map)['permission'], 'unknown');
    });
  });

  group('getSchedules', () {
    test('emits the 7 built-ins with keys and configs', () async {
      await bridge.handle('{"op":"getSchedules","request_id":"r6"}');
      expect(lastAck()['ok'], true);
      final payload = lastEvent('cupitorNotifSchedules')!;
      final schedules = payload['schedules'] as List;
      expect(schedules, hasLength(7));
      final first = schedules.first as Map;
      expect(first['key'], 'ebbinghaus');
      expect(first['builtin'], true);
      expect((first['config'] as Map)['offsets_waking_hours'], isA<List>());
    });
  });

  group('createList', () {
    test('series list: items at step 0, due at offsets[0], events pushed',
        () async {
      await createFrenchList();
      expect(lastAck()['ok'], true);
      final lists = lastEvent('cupitorNotifLists')!['lists'] as List;
      final l = lists.single as Map;
      expect(l['external_key'], 'fr-1');
      expect(l['schedule_key'], 'ebbinghaus');
      expect(l['status'], 'active');
      final items = l['items'] as List;
      expect(items, hasLength(2));
      final c1 = items.first as Map;
      expect(c1['external_id'], 'c1');
      expect(c1['step'], 0);
      expect(c1['payload'], {'deck': 7});
      // ebbinghaus offsets[0] = 0.25 wh from Mon 10:00 → 10:15.
      final expected = tz.TZDateTime(ny, 2026, 7, 27, 10, 15)
          .millisecondsSinceEpoch;
      expect(c1['next_due_at'], expected);
      // No internal row ids cross the bridge.
      expect(c1.containsKey('id'), isFalse);
      expect(l.containsKey('id'), isFalse);
    });
    test('recurring list: items undue, list gets next_fire_at', () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      final l = (lastEvent('cupitorNotifLists')!['lists'] as List).single as Map;
      expect((l['items'] as List).first['next_due_at'], isNull);
      // Mon 10:00 is past 09:00 → Tue 09:00.
      expect(l['next_fire_at'],
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
    });
    test('duplicate external_key → duplicate_key', () async {
      await createFrenchList();
      await createFrenchList();
      expect(lastAck()['error'], 'duplicate_key');
    });
    test('unknown schedule → unknown_schedule', () async {
      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'x', 'name': 'X',
        'schedule_key': 'nope', 'items': [],
      }));
      expect(lastAck()['error'], 'unknown_schedule');
    });
    test('item missing title → bad_payload, nothing created', () async {
      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'x', 'name': 'X',
        'schedule_key': 'ebbinghaus',
        'items': [{'external_id': 'c1'}],
      }));
      expect(lastAck()['error'], 'bad_payload');
      expect(await dao.listByExternalKey(1, 'x'), isNull);
    });
    test('duplicate external_id within payload → bad_payload', () async {
      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'x', 'name': 'X',
        'schedule_key': 'ebbinghaus',
        'items': [
          {'external_id': 'c1', 'title': 'a'},
          {'external_id': 'c1', 'title': 'b'},
        ],
      }));
      expect(lastAck()['error'], 'bad_payload');
    });
  });

  group('syncItems', () {
    test('merge: updates content, preserves SRS state, inserts new', () async {
      await createFrenchList();
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      final c1 = (await dao.itemByExternalId(list.id, 'c1'))!;
      await dao.updateItem(c1.id, {'step': 4, 'next_due_at': 123456});

      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'request_id': 'r-sync', 'external_key': 'fr-1',
        'items': [
          {'external_id': 'c1', 'title': 'le dénouement (fixed)'},
          {'external_id': 'c3', 'title': 'quoi qu\'il en soit'},
        ],
      }));
      expect(lastAck()['ok'], true);

      final c1After = (await dao.itemByExternalId(list.id, 'c1'))!;
      expect(c1After.title, 'le dénouement (fixed)');
      expect(c1After.step, 4); // three weeks of progress survives a typo fix
      expect(c1After.nextDueAt, 123456);
      // c2 absent from payload: merge leaves it alone.
      expect(await dao.itemByExternalId(list.id, 'c2'), isNotNull);
      // c3 inserted fresh at step 0.
      expect((await dao.itemByExternalId(list.id, 'c3'))!.step, 0);
    });
    test('replace: absent items are deleted', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'external_key': 'fr-1', 'mode': 'replace',
        'items': [{'external_id': 'c1', 'title': 'le dénouement'}],
      }));
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(await dao.itemByExternalId(list.id, 'c2'), isNull);
      expect(await dao.itemByExternalId(list.id, 'c1'), isNotNull);
    });
    test('unknown list → unknown_list', () async {
      await bridge.handle(jsonEncode(
          {'op': 'syncItems', 'external_key': 'zzz', 'items': []}));
      expect(lastAck()['error'], 'unknown_list');
    });
    test('bad mode → bad_payload', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'external_key': 'fr-1', 'mode': 'upsert',
        'items': [],
      }));
      expect(lastAck()['error'], 'bad_payload');
    });
  });

  group('getLists', () {
    test('pushes cupitorNotifLists and acks', () async {
      await createFrenchList();
      events.clear();
      await bridge.handle('{"op":"getLists","request_id":"r-gl"}');
      expect(lastAck()['ok'], true);
      expect(lastEvent('cupitorNotifLists'), isNotNull);
    });
  });

  group('grade', () {
    test('Good advances step, records event, emits cupitorNotifGraded',
        () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'grade', 'request_id': 'r-g', 'external_key': 'fr-1',
        'item_external_id': 'c1', 'grade': 3,
      }));
      expect(lastAck()['ok'], true);
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      final c1 = (await dao.itemByExternalId(list.id, 'c1'))!;
      expect(c1.step, 1);
      expect(c1.lastGrade, 3);
      // offsets[1] = 1 wh from Mon 10:00 → 11:00.
      expect(c1.nextDueAt,
          tz.TZDateTime(ny, 2026, 7, 27, 11).millisecondsSinceEpoch);
      final ev = (await dao.lastEventForItem(c1.id))!;
      expect(ev.grade, 3);
      expect(ev.source, 'webpage');
      final graded = lastEvent('cupitorNotifGraded')!;
      expect(graded['item_external_id'], 'c1');
      expect(graded['grade'], 3);
      expect(graded['source'], 'webpage');
    });
    test('grade on recurring list → not_series', () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      await bridge.handle(jsonEncode({
        'op': 'grade', 'external_key': 'fr-1',
        'item_external_id': 'c1', 'grade': 3,
      }));
      expect(lastAck()['error'], 'not_series');
    });
    test('grade outside {1,3,5} → bad_grade', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'grade', 'external_key': 'fr-1',
        'item_external_id': 'c1', 'grade': 2,
      }));
      expect(lastAck()['error'], 'bad_grade');
    });
    test('unknown item → unknown_item', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'grade', 'external_key': 'fr-1',
        'item_external_id': 'zzz', 'grade': 3,
      }));
      expect(lastAck()['error'], 'unknown_item');
    });
  });

  group('setSchedule', () {
    test('recurring → series inits only items without series state',
        () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      // Simulate c1 having prior series state from an earlier stint.
      final c1 = (await dao.itemByExternalId(list.id, 'c1'))!;
      await dao.updateItem(c1.id, {'step': 5, 'next_due_at': 777});

      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'external_key': 'fr-1',
        'schedule_key': 'ebbinghaus',
      }));
      expect(lastAck()['ok'], true);

      final after = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(after.nextFireAt, isNull);
      final c1After = (await dao.itemByExternalId(list.id, 'c1'))!;
      expect(c1After.step, 5); // lossless: prior state kept
      expect(c1After.nextDueAt, 777);
      final c2After = (await dao.itemByExternalId(list.id, 'c2'))!;
      expect(c2After.step, 0); // no prior state: initialised
      expect(c2After.nextDueAt,
          tz.TZDateTime(ny, 2026, 7, 27, 10, 15).millisecondsSinceEpoch);
    });
    test('series → recurring sets next_fire_at, leaves item state', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'external_key': 'fr-1',
        'schedule_key': 'daily_0900',
      }));
      final after = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(after.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
      final c1 = (await dao.itemByExternalId(after.id, 'c1'))!;
      expect(c1.nextDueAt, isNotNull); // unread but preserved
    });
    test('unknown schedule → unknown_schedule', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'external_key': 'fr-1', 'schedule_key': 'nope',
      }));
      expect(lastAck()['error'], 'unknown_schedule');
    });
  });

  group('setStatus', () {
    test('pause and resume; resume recomputes recurring next_fire_at',
        () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      await bridge.handle(jsonEncode(
          {'op': 'setStatus', 'external_key': 'fr-1', 'status': 'paused'}));
      expect((await dao.listByExternalKey(1, 'fr-1'))!.status, 'paused');

      now = tz.TZDateTime(ny, 2026, 7, 30, 12); // resume days later
      await bridge.handle(jsonEncode(
          {'op': 'setStatus', 'external_key': 'fr-1', 'status': 'active'}));
      final l = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(l.status, 'active');
      expect(l.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 31, 9).millisecondsSinceEpoch);
    });
    test('bad status → bad_payload', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode(
          {'op': 'setStatus', 'external_key': 'fr-1', 'status': 'zzz'}));
      expect(lastAck()['error'], 'bad_payload');
    });
  });

  group('deleteList', () {
    test('deletes and pushes updated lists', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode(
          {'op': 'deleteList', 'external_key': 'fr-1'}));
      expect(lastAck()['ok'], true);
      expect(await dao.listByExternalKey(1, 'fr-1'), isNull);
      expect(lastEvent('cupitorNotifLists')!['lists'], isEmpty);
    });
    test('unknown key → unknown_list', () async {
      await bridge.handle(jsonEncode(
          {'op': 'deleteList', 'external_key': 'zzz'}));
      expect(lastAck()['error'], 'unknown_list');
    });
  });
}
