import 'dart:convert';

import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/notification_service.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'fake_notif_channel.dart';

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
  late FakeNotifChannel channel;
  late NotificationService service;
  late tz.TZDateTime now;
  int nowMs() => now.millisecondsSinceEpoch;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 7,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, v) => CupitorDb.createSchema(d)));
    dao = NotifDao(db);
    channel = FakeNotifChannel();
    now = tz.TZDateTime(ny, 2026, 7, 27, 10); // Monday
    service = NotificationService(
      channel: channel,
      dao: () async => dao,
      window: () => WakingWindow.defaults,
      perFireCap: () => 5,
      now: () => now,
      maxArmed: 60,
    );
  });
  tearDown(() => db.close());

  Future<NotifListRow> seriesList({String name = 'L', String? ek}) async {
    final eb = await dao.scheduleByKey('ebbinghaus');
    return dao.createList(
        profileId: 1, name: name, source: 'app',
        externalKey: ek, scheduleId: eb!.id);
  }

  group('rearm', () {
    test('arms only strictly-future items inside 48h, stable ids, cancels first',
        () async {
      final l = await seriesList();
      await dao.insertItem(
          listId: l.id, title: 'overdue', position: 0,
          nextDueAt: nowMs() - 1000); // sweep's job, not rearm's
      final soon = await dao.insertItem(
          listId: l.id, title: 'soon', position: 1,
          nextDueAt: nowMs() + 3600000);
      await dao.insertItem(
          listId: l.id, title: 'far', position: 2,
          nextDueAt: nowMs() + 49 * 3600000); // beyond window

      await service.rearm();
      expect(channel.cancelAllCalls, 1);
      expect(channel.scheduled, hasLength(1));
      final f = channel.scheduled.single;
      expect(f.notifId, NotificationService.itemNotifId(soon.id));
      expect(f.title, 'soon');
      expect(f.whenMs, nowMs() + 3600000);
      expect(f.withActions, isTrue);
      expect(f.groupKey, 'cupitor-notif-list-${l.id}');
      final payload = jsonDecode(f.payloadJson) as Map<String, dynamic>;
      expect(payload['item_id'], soon.id);
    });

    test('rearm twice is idempotent', () async {
      final l = await seriesList();
      await dao.insertItem(
          listId: l.id, title: 'x', position: 0, nextDueAt: nowMs() + 1000);
      await service.rearm();
      await service.rearm();
      expect(channel.scheduled, hasLength(1)); // fake clears on cancelAll
      expect(channel.cancelAllCalls, 2);
    });

    test('per-minute cap defers overflow within one minute bucket', () async {
      final l = await seriesList();
      final due = nowMs() + 600000; // all in the same minute
      for (var i = 0; i < 8; i++) {
        await dao.insertItem(
            listId: l.id, title: 'i$i', position: i, nextDueAt: due + i * 100);
      }
      await service.rearm();
      expect(channel.scheduled, hasLength(5)); // cap 5, 3 deferred
    });

    test('maxArmed cap holds', () async {
      final l = await seriesList();
      for (var i = 0; i < 70; i++) {
        await dao.insertItem(
            listId: l.id, title: 'i$i', position: i,
            // spread across minutes so the per-minute cap doesn't bite first
            nextDueAt: nowMs() + (i + 1) * 120000);
      }
      await service.rearm();
      expect(channel.scheduled, hasLength(60));
    });

    test('recurring list arms next fire with rotation items, no actions',
        () async {
      final daily = await dao.scheduleByKey('daily_0900');
      final l = await dao.createList(
          profileId: 1, name: 'R', source: 'app',
          scheduleId: daily!.id, nextFireAt: nowMs() + 3600000);
      await dao.insertItem(listId: l.id, title: 'r0', position: 0);
      await dao.insertItem(listId: l.id, title: 'r1', position: 1);

      await service.rearm();
      expect(channel.scheduled, hasLength(1)); // per_fire = 1
      final f = channel.scheduled.single;
      expect(f.title, 'r0'); // cursor 0
      expect(f.withActions, isFalse);
      expect(f.whenMs, nowMs() + 3600000);
      expect(f.notifId, NotificationService.itemNotifId(
          (await dao.itemsForList(l.id)).first.id));
    });

    test('paused list and dao-null are silent no-ops', () async {
      final l = await seriesList();
      await dao.insertItem(
          listId: l.id, title: 'x', position: 0, nextDueAt: nowMs() + 1000);
      await dao.updateList(l.id, {'status': 'paused'});
      await service.rearm();
      expect(channel.scheduled, isEmpty);

      final dead = NotificationService(
        channel: channel,
        dao: () async => null,
        window: () => WakingWindow.defaults,
        perFireCap: () => 5,
        now: () => now,
        maxArmed: 60,
      );
      await dead.rearm(); // must not throw
    });
  });
}
