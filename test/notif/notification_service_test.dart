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

  group('sweep', () {
    test('overdue within grace: posts now, auto-advances, records fire event',
        () async {
      final l = await seriesList();
      final item = await dao.insertItem(
          listId: l.id, title: 'due', position: 0,
          nextDueAt: nowMs() - 3600000); // 1 waking hour ago (10:00 Mon)
      await service.sweep();

      expect(channel.shown, hasLength(1));
      expect(channel.shown.single.notifId,
          NotificationService.itemNotifId(item.id));
      final after = (await dao.itemById(item.id))!;
      expect(after.step, 1); // auto-advance = the automatic fading
      expect(after.nextDueAt, greaterThan(nowMs()));
      expect(after.lastFiredAt, nowMs());
      final ev = (await dao.lastEventForItem(item.id))!;
      expect(ev.respondedAt, isNull);
      expect(ev.source, isNull); // a real posted fire
    });

    test('overdue beyond grace: silent auto-advance, source auto', () async {
      final l = await seriesList();
      final item = await dao.insertItem(
          listId: l.id, title: 'stale', position: 0,
          nextDueAt: nowMs() - 4 * 3600000); // 4 waking hours ago
      await service.sweep();
      expect(channel.shown, isEmpty);
      final after = (await dao.itemById(item.id))!;
      expect(after.step, 1);
      expect((await dao.lastEventForItem(item.id))!.source, 'auto');
    });

    test('already-handled fire (event at/after due) is not re-fired', () async {
      final l = await seriesList();
      final item = await dao.insertItem(
          listId: l.id, title: 'handled', position: 0,
          nextDueAt: nowMs() - 1000);
      await dao.insertEvent(
          itemId: item.id, firedAt: nowMs() - 500, respondedAt: nowMs() - 400,
          grade: 3, source: 'webpage');
      await service.sweep();
      expect(channel.shown, isEmpty);
      expect((await dao.itemById(item.id))!.step, 0); // untouched
    });

    test('due recurring list within grace: fires rotation, advances cursor, reschedules',
        () async {
      final daily = await dao.scheduleByKey('daily_0900');
      final l = await dao.createList(
          profileId: 1, name: 'R', source: 'app',
          scheduleId: daily!.id, nextFireAt: nowMs() - 3600000);
      await dao.insertItem(listId: l.id, title: 'r0', position: 0);
      await dao.insertItem(listId: l.id, title: 'r1', position: 1);
      await service.sweep();

      expect(channel.shown, hasLength(1));
      expect(channel.shown.single.title, 'r0');
      final after = (await dao.listById(l.id))!;
      expect(after.cursor, 1);
      expect(after.lastFiredAt, nowMs());
      // Mon 10:00 → next daily 09:00 is Tue 09:00.
      expect(after.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
    });

    test('stale recurring fire: skipped, just rescheduled', () async {
      final daily = await dao.scheduleByKey('daily_0900');
      final l = await dao.createList(
          profileId: 1, name: 'R', source: 'app',
          scheduleId: daily!.id, nextFireAt: nowMs() - 8 * 3600000);
      await dao.insertItem(listId: l.id, title: 'r0', position: 0);
      await service.sweep();
      expect(channel.shown, isEmpty);
      final after = (await dao.listById(l.id))!;
      expect(after.cursor, 0); // nothing consumed
      expect(after.nextFireAt, greaterThan(nowMs()));
    });

    test('sweep respects the per-fire cap on the posted batch', () async {
      final l = await seriesList();
      for (var i = 0; i < 8; i++) {
        await dao.insertItem(
            listId: l.id, title: 'i$i', position: i,
            nextDueAt: nowMs() - 1000 - i);
      }
      await service.sweep();
      expect(channel.shown, hasLength(5));
      // The other 3 still advanced silently (auto) so the backlog drains.
      final items = await dao.itemsForList(l.id);
      expect(items.where((i) => i.step == 1), hasLength(8));
    });

    test('sweep ends by rearming the future window', () async {
      final l = await seriesList();
      await dao.insertItem(
          listId: l.id, title: 'due', position: 0, nextDueAt: nowMs() - 1000);
      await service.sweep();
      // The auto-advanced item got a future next_due_at → must now be armed.
      expect(channel.scheduled, hasLength(1));
    });
  });
}
