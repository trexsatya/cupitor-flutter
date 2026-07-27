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
}
