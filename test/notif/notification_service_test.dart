import 'dart:convert';

import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/notification_service.dart';
import 'package:cupitor/notif/pending_fire.dart';
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
      expect(channel.scheduled.where((f) => !f.isSummary), hasLength(1));
      final f = channel.scheduled.firstWhere((f) => !f.isSummary);
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
      expect(channel.scheduled.where((f) => !f.isSummary),
          hasLength(1)); // fake clears on cancelAll
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
      expect(channel.scheduled.where((f) => !f.isSummary),
          hasLength(5)); // cap 5, 3 deferred
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
      expect(channel.scheduled.where((f) => !f.isSummary), hasLength(60));
      // One list → exactly one summary, exempt from the maxArmed cap.
      expect(channel.scheduled.where((f) => f.isSummary), hasLength(1));
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
      expect(channel.scheduled.where((f) => !f.isSummary),
          hasLength(1)); // per_fire = 1
      final f = channel.scheduled.firstWhere((f) => !f.isSummary);
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

      expect(channel.shown.where((f) => !f.isSummary), hasLength(1));
      expect(channel.shown.firstWhere((f) => !f.isSummary).notifId,
          NotificationService.itemNotifId(item.id));
      final after = (await dao.itemById(item.id))!;
      expect(after.step, 1); // auto-advance = the automatic fading
      expect(after.nextDueAt, greaterThan(nowMs()));
      expect(after.lastFiredAt, nowMs());
      final ev = (await dao.lastEventForItem(item.id))!;
      expect(ev.respondedAt, isNull);
      expect(ev.source, isNull); // a real posted fire
    });

    test('a fire already displayed by its alarm is recorded, not re-posted',
        () async {
      final l = await seriesList();
      final item = await dao.insertItem(
          listId: l.id, title: 'due', position: 0,
          nextDueAt: nowMs() - 3600000);
      // The pre-armed alarm delivered this one; it's still in the shade.
      channel.activeIds.add(NotificationService.itemNotifId(item.id));
      await service.sweep();

      expect(channel.shown, isEmpty); // no duplicate alert, no summary
      final after = (await dao.itemById(item.id))!;
      expect(after.step, 1); // fire still processed
      final ev = (await dao.lastEventForItem(item.id))!;
      expect(ev.respondedAt, isNull);
      expect(ev.source, isNull); // it WAS shown — not a silent auto-advance
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

      expect(channel.shown.where((f) => !f.isSummary), hasLength(1));
      expect(channel.shown.firstWhere((f) => !f.isSummary).title, 'r0');
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
      expect(channel.shown.where((f) => !f.isSummary), hasLength(5));
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
      expect(channel.scheduled.where((f) => !f.isSummary), hasLength(1));
    });
  });

  group('handleAction / recordOpened', () {
    Future<(NotifListRow, NotifItemRow)> firedItem() async {
      final l = await seriesList(ek: 'fr-1');
      final item = await dao.insertItem(
          listId: l.id, externalId: 'c1', title: 'x', position: 0,
          nextDueAt: nowMs() - 1000);
      await service.sweep(); // fires it, step → 1
      channel.shown.clear();
      channel.scheduled.clear();
      return (l, (await dao.itemById(item.id))!);
    }

    test('again resets to step 0 and records responded event', () async {
      final (_, item) = await firedItem();
      final payload = jsonEncode({'v': 1, 'item_id': item.id});
      final graded = await service.handleAction('again', payload);
      expect(graded, isNotNull);
      final after = (await dao.itemById(item.id))!;
      expect(after.step, 0);
      expect(after.lastGrade, 1);
      final ev = (await dao.lastEventForItem(item.id))!;
      expect(ev.grade, 1);
      expect(ev.source, 'action');
      expect(ev.respondedAt, nowMs());
      expect(graded!.$2, 1); // (externals, grade) for the cupitorNotifGraded push
    });

    test('good and easy advance from the step SHOWN at fire time', () async {
      // The sweep auto-advanced the item to step 1, but the notification the
      // user responds to was shown at step 0 — grading from the mutated row
      // would skip rung 2 entirely (missed reviews).
      final (_, item) = await firedItem(); // shown at 0, auto-advanced to 1
      await service.handleAction(
          'easy', jsonEncode({'v': 1, 'item_id': item.id}));
      expect((await dao.itemById(item.id))!.step, 2); // 0 + 2, not 1 + 2
    });

    test('unknown action / bad payload / missing item are silent no-ops',
        () async {
      expect(await service.handleAction('again', 'not-json'), isNull);
      expect(await service.handleAction('again',
          jsonEncode({'v': 1, 'item_id': 999999})), isNull);
      final (_, item) = await firedItem();
      expect(await service.handleAction('snooze',
          jsonEncode({'v': 1, 'item_id': item.id})), isNull);
    });

    test('handleAction ends by rearming', () async {
      final (_, item) = await firedItem();
      await service.handleAction(
          'good', jsonEncode({'v': 1, 'item_id': item.id}));
      expect(channel.scheduled, isNotEmpty);
    });

    test('recordOpened stamps responded_at on the latest fire event', () async {
      final (_, item) = await firedItem();
      await service.recordOpened(jsonEncode({'v': 1, 'item_id': item.id}));
      final ev = (await dao.lastEventForItem(item.id))!;
      expect(ev.respondedAt, nowMs());
    });

    test('grading a sweep-recorded fire stamps that event, no duplicate row',
        () async {
      final (_, item) = await firedItem(); // sweep inserted the fire event
      await service.handleAction(
          'easy', jsonEncode({'v': 1, 'item_id': item.id}));
      final events = await db.query('notif_events',
          where: 'item_id = ?', whereArgs: [item.id]);
      expect(events, hasLength(1)); // stamped in place, not duplicated
      final ev = (await dao.lastEventForItem(item.id))!;
      expect(ev.respondedAt, nowMs());
      expect(ev.grade, 5);
      expect(ev.source, 'action');
    });

    test('a response acknowledges every outstanding fire of the item',
        () async {
      final (_, item) = await firedItem();
      // An older orphaned fire (e.g. recorded while the user was away).
      await dao.insertEvent(
          itemId: item.id, firedAt: nowMs() - 86400000, source: 'auto');
      await service.recordOpened(jsonEncode({'v': 1, 'item_id': item.id}));
      final unread = await db.query('notif_events',
          where: 'item_id = ? AND responded_at IS NULL',
          whereArgs: [item.id]);
      expect(unread, isEmpty);
    });
  });

  group('review fixes', () {
    test('recurring rotation is not consumed when the global cap is exhausted',
        () async {
      final l = await seriesList();
      for (var i = 0; i < 5; i++) {
        await dao.insertItem(
            listId: l.id, title: 's$i', position: i, nextDueAt: nowMs() - 1000 - i);
      }
      final daily = await dao.scheduleByKey('daily_0900');
      final r = await dao.createList(
          profileId: 1, name: 'R', source: 'app',
          scheduleId: daily!.id, nextFireAt: nowMs() - 60000);
      await dao.insertItem(listId: r.id, title: 'r0', position: 0);
      await service.sweep();
      expect(channel.shown.where((f) => !f.isSummary),
          hasLength(5)); // series ate the cap
      final after = (await dao.listById(r.id))!;
      expect(after.cursor, 0); // rotation NOT consumed
      expect(after.lastFiredAt, isNull); // no phantom fire stamp
      expect(after.nextFireAt, greaterThan(nowMs())); // still rescheduled
    });

    test('an item reachable via both series and recurring paths arms once',
        () async {
      final daily = await dao.scheduleByKey('daily_0900');
      final r = await dao.createList(
          profileId: 1, name: 'R', source: 'app',
          scheduleId: daily!.id, nextFireAt: nowMs() + 7200000);
      // Leftover series state on a recurring-list item:
      await dao.insertItem(
          listId: r.id, title: 'r0', position: 0, nextDueAt: nowMs() + 3600000);
      await service.rearm();
      expect(channel.scheduled.where((f) => !f.isSummary), hasLength(1));
      expect(channel.scheduled.firstWhere((f) => !f.isSummary).whenMs,
          nowMs() + 3600000); // earliest wins
    });

    test('a grade on an auto-graduated fire is applied, never dropped',
        () async {
      final l = await seriesList();
      // Single-rung custom ladder graduates on first fire.
      final s = await dao.createCustomSchedule(
          name: 'One', kind: 'series', config: {'offsets_waking_hours': [1]});
      await dao.updateList(l.id, {'schedule_id': s.id});
      final item = await dao.insertItem(
          listId: l.id, title: 'x', position: 0, nextDueAt: nowMs() - 1000);
      await service.sweep(); // shown at step 0, auto-graduates to done
      // The user responds to that notification: the grade must be recorded
      // from the shown step, not silently discarded because the row says
      // 'done' — dropping it loses the review.
      expect(await service.handleAction(
          'good', jsonEncode({'v': 1, 'item_id': item.id})), isNotNull);
      final after = (await dao.itemById(item.id))!;
      expect(after.lastGrade, 3);
      final ev = (await dao.lastEventForItem(item.id))!;
      expect(ev.grade, 3);
      expect(ev.respondedAt, nowMs());
    });

    test('good on a long-done item with no pending fire is a silent no-op',
        () async {
      final l = await seriesList();
      final s = await dao.createCustomSchedule(
          name: 'One', kind: 'series', config: {'offsets_waking_hours': [1]});
      await dao.updateList(l.id, {'schedule_id': s.id});
      final item = await dao.insertItem(
          listId: l.id, title: 'x', position: 0, nextDueAt: nowMs() - 1000);
      await service.sweep(); // graduates: done
      // Fire acknowledged: a later stray 'good' has nothing to grade.
      await service.recordOpened(jsonEncode({'v': 1, 'item_id': item.id}));
      final evCountBefore = (await dao.lastEventForItem(item.id))!.id;
      expect(await service.handleAction(
          'good', jsonEncode({'v': 1, 'item_id': item.id})), isNull);
      expect((await dao.itemById(item.id))!.lastGrade, isNull);
      expect((await dao.lastEventForItem(item.id))!.id, evCountBefore);
      // Again still resurrects:
      expect(await service.handleAction(
          'again', jsonEncode({'v': 1, 'item_id': item.id})), isNotNull);
      expect((await dao.itemById(item.id))!.step, 0);
    });

    test('rearm survives a channel that throws on schedule', () async {
      final throwing = _ThrowingChannel();
      final svc = NotificationService(
        channel: throwing,
        dao: () async => dao,
        window: () => WakingWindow.defaults,
        perFireCap: () => 5,
        now: () => now,
        maxArmed: 60,
      );
      final l = await seriesList();
      await dao.insertItem(
          listId: l.id, title: 'a', position: 0, nextDueAt: nowMs() + 1000);
      await dao.insertItem(
          listId: l.id, title: 'b', position: 1, nextDueAt: nowMs() + 2000);
      await svc.rearm(); // must not throw
      expect(throwing.attempts, 2); // tried both, gave up per-fire
    });
  });

  group('group summaries', () {
    test('rearm schedules one summary per armed group at earliest fire time',
        () async {
      final l = await seriesList(name: 'French');
      await dao.insertItem(
          listId: l.id, title: 'a', position: 0, nextDueAt: nowMs() + 2000);
      await dao.insertItem(
          listId: l.id, title: 'b', position: 1, nextDueAt: nowMs() + 1000);
      await service.rearm();
      final summaries =
          channel.scheduled.where((f) => f.isSummary).toList();
      expect(summaries, hasLength(1));
      expect(summaries.single.notifId,
          NotificationService.summaryNotifId(l.id));
      expect(summaries.single.whenMs, nowMs() + 1000); // earliest
      expect(summaries.single.title, 'French');
      // Items themselves are unaffected and summaries don't eat the caps.
      expect(channel.scheduled.where((f) => !f.isSummary), hasLength(2));
    });

    test('summaries are exempt from per-minute cap and maxArmed', () async {
      final l = await seriesList();
      final due = nowMs() + 600000;
      for (var i = 0; i < 5; i++) {
        await dao.insertItem(
            listId: l.id, title: 'i$i', position: i, nextDueAt: due + i * 100);
      }
      await service.rearm();
      expect(channel.scheduled.where((f) => !f.isSummary), hasLength(5));
      expect(channel.scheduled.where((f) => f.isSummary), hasLength(1));
    });

    test('sweep posts a summary once per list that posted fires', () async {
      final l = await seriesList();
      await dao.insertItem(
          listId: l.id, title: 'x', position: 0, nextDueAt: nowMs() - 1000);
      await dao.insertItem(
          listId: l.id, title: 'y', position: 1, nextDueAt: nowMs() - 2000);
      await service.sweep();
      expect(channel.shown.where((f) => !f.isSummary), hasLength(2));
      expect(channel.shown.where((f) => f.isSummary), hasLength(1));
    });

    test('no summary when nothing was posted for a list', () async {
      final l = await seriesList();
      await dao.insertItem(
          listId: l.id, title: 'stale', position: 0,
          nextDueAt: nowMs() - 4 * 3600000); // beyond grace: silent
      await service.sweep();
      expect(channel.shown, isEmpty);
    });
  });
}

class _ThrowingChannel extends FakeNotifChannel {
  int attempts = 0;
  @override
  Future<void> schedule(PendingFire fire) async {
    attempts++;
    throw UnimplementedError();
  }
}
