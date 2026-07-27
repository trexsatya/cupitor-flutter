import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/notif_ops.dart';
import 'package:cupitor/notif/notif_ui_util.dart';
import 'package:cupitor/notif/schedules.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late Database db;
  late NotifDao dao;
  late tz.Location ny;
  // Mon 2026-07-27 10:00 EDT — mid-morning, well inside the default window.
  late tz.TZDateTime now;
  const w = WakingWindow.defaults;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('America/New_York'));
    ny = tz.getLocation('America/New_York');
    now = tz.TZDateTime(ny, 2026, 7, 27, 10);
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 1,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) async {
              await CupitorDb.createSchema(d);
              await CupitorDb.seedBuiltinSchedules(d);
            }));
    dao = NotifDao(db);
  });

  tearDown(() => db.close());

  group('schedule DAO additions', () {
    test('listsUsingSchedule finds lists across profiles', () async {
      await db.insert('profiles', {'id': 2, 'name': 'Second', 'created_at': 1});
      final s = await dao.scheduleByKey('ebbinghaus');
      await dao.createList(
          profileId: 1, name: 'a', source: 'app', scheduleId: s!.id);
      await dao.createList(
          profileId: 2, name: 'b', source: 'app', scheduleId: s.id);
      await dao.createList(profileId: 1, name: 'c', source: 'app');
      final using = await dao.listsUsingSchedule(s.id);
      expect(using.map((l) => l.name), ['a', 'b']);
    });

    test('updateCustomSchedule rewrites custom, refuses builtin', () async {
      final c = await dao.createCustomSchedule(
          name: 'mine',
          kind: 'series',
          config: {'offsets_waking_hours': [1, 2]});
      final ok = await dao.updateCustomSchedule(c.id,
          name: 'mine2',
          kind: 'series',
          config: {'offsets_waking_hours': [2, 4]});
      expect(ok, isTrue);
      final re = await dao.scheduleById(c.id);
      expect(re!.name, 'mine2');
      expect(re.config, contains('4'));

      final builtin = await dao.scheduleByKey('daily_0900');
      expect(
          await dao.updateCustomSchedule(builtin!.id,
              name: 'x',
              kind: 'series',
              config: {'offsets_waking_hours': [1]}),
          isFalse);
      expect((await dao.scheduleById(builtin.id))!.name, builtin.name);
    });

    test('updateCustomSchedule validates config', () async {
      final c = await dao.createCustomSchedule(
          name: 'mine',
          kind: 'series',
          config: {'offsets_waking_hours': [1, 2]});
      expect(
          () => dao.updateCustomSchedule(c.id,
              name: 'mine',
              kind: 'series',
              config: {'offsets_waking_hours': [2, 1]}),
          throwsA(isA<ScheduleConfigError>()));
    });

    test('deleteCustomSchedule deletes custom only', () async {
      final c = await dao.createCustomSchedule(
          name: 'gone',
          kind: 'series',
          config: {'offsets_waking_hours': [1]});
      expect(await dao.deleteCustomSchedule(c.id), isTrue);
      expect(await dao.scheduleById(c.id), isNull);

      final builtin = await dao.scheduleByKey('pimsleur');
      expect(await dao.deleteCustomSchedule(builtin!.id), isFalse);
      expect(await dao.scheduleById(builtin.id), isNotNull);
    });
  });

  group('notif_ops', () {
    test('offsetsIfSeries / initialNextDueMs / initialNextFireMs', () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final recurring = await dao.scheduleByKey('daily_0900');
      expect(offsetsIfSeries(series)!.first, 1);
      expect(offsetsIfSeries(recurring), isNull);
      expect(offsetsIfSeries(null), isNull);

      final due = initialNextDueMs(series, now, w);
      expect(due, now.add(const Duration(hours: 1)).millisecondsSinceEpoch);
      expect(initialNextDueMs(recurring, now, w), isNull);

      // Next 09:00 after Mon 10:00 is Tue 09:00.
      final fire = initialNextFireMs(recurring!, now, w);
      expect(fire,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
      expect(initialNextFireMs(series!, now, w), isNull);
    });

    test('applyScheduleToList series initialises only stateless items',
        () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final list = await dao.createList(
          profileId: 1, name: 'l', source: 'app');
      final fresh = await dao.insertItem(
          listId: list.id, title: 'fresh', position: 0);
      final veteran = await dao.insertItem(
          listId: list.id,
          title: 'veteran',
          position: 1,
          step: 3,
          nextDueAt: 12345);
      await applyScheduleToList(
          dao, (await dao.listById(list.id))!, series!, now, w);

      final l = await dao.listById(list.id);
      expect(l!.scheduleId, series.id);
      expect(l.nextFireAt, isNull);
      final f = await dao.itemById(fresh.id);
      expect(f!.nextDueAt,
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch);
      final v = await dao.itemById(veteran.id);
      expect(v!.step, 3);
      expect(v.nextDueAt, 12345); // lossless: state kept
    });

    test('applyScheduleToList recurring re-anchors and keeps item state',
        () async {
      final recurring = await dao.scheduleByKey('daily_0900');
      final list = await dao.createList(
          profileId: 1, name: 'l', source: 'app');
      final it = await dao.insertItem(
          listId: list.id, title: 'i', position: 0, step: 2, nextDueAt: 777);
      await applyScheduleToList(
          dao, (await dao.listById(list.id))!, recurring!, now, w);
      final l = await dao.listById(list.id);
      expect(l!.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
      final i = await dao.itemById(it.id);
      expect(i!.step, 2);
      expect(i.nextDueAt, 777);
    });

    test('setListStatus pause keeps fire; resume re-anchors recurring',
        () async {
      final recurring = await dao.scheduleByKey('daily_0900');
      final list = await dao.createList(
          profileId: 1,
          name: 'l',
          source: 'app',
          scheduleId: recurring!.id,
          nextFireAt: 111);
      await setListStatus(dao, list, 'paused', now, w);
      var l = await dao.listById(list.id);
      expect(l!.status, 'paused');
      expect(l.nextFireAt, 111);

      await setListStatus(dao, l, 'active', now, w);
      l = await dao.listById(list.id);
      expect(l!.status, 'active');
      expect(l.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
    });

    test('resetItemToStart clears state back to rung one', () async {
      final series = await dao.scheduleByKey('cepeda2x');
      final list = await dao.createList(
          profileId: 1, name: 'l', source: 'app', scheduleId: series!.id);
      final it = await dao.insertItem(
          listId: list.id, title: 'i', position: 0, step: 5, nextDueAt: 9);
      await dao.updateItem(it.id, {'status': 'done', 'last_grade': 5});
      await resetItemToStart(
          dao, (await dao.itemById(it.id))!, series, now, w);
      final i = await dao.itemById(it.id);
      expect(i!.step, 0);
      expect(i.status, 'active');
      expect(i.lastGrade, isNull);
      expect(i.nextDueAt,
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch);
    });
  });

  group('notif_ui_util', () {
    test('minutesToHhmm pads', () {
      expect(minutesToHhmm(0), '00:00');
      expect(minutesToHhmm(9 * 60 + 5), '09:05');
      expect(minutesToHhmm(22 * 60), '22:00');
    });

    test('formatDue buckets', () {
      final n = now.millisecondsSinceEpoch;
      expect(formatDue(null, n), '—');
      expect(formatDue(n - 1, n), 'overdue');
      expect(formatDue(n + 30 * 1000, n), 'in <1m');
      expect(formatDue(n + 5 * 60000, n), 'in 5m');
      expect(formatDue(n + 3 * 3600000, n), 'in 3h');
      expect(formatDue(n + 72 * 3600000, n), 'in 3d');
    });

    test('insideSleepWindow both window shapes', () {
      const normal = WakingWindow.defaults; // 05:00–22:00
      expect(insideSleepWindow(4 * 60, normal), isTrue);
      expect(insideSleepWindow(5 * 60, normal), isFalse);
      expect(insideSleepWindow(21 * 60 + 59, normal), isFalse);
      expect(insideSleepWindow(22 * 60, normal), isTrue);

      // Night worker: waking 20:00–03:00.
      const night = WakingWindow(startMinutes: 20 * 60, endMinutes: 3 * 60);
      expect(insideSleepWindow(23 * 60, night), isFalse);
      expect(insideSleepWindow(2 * 60, night), isFalse);
      expect(insideSleepWindow(12 * 60, night), isTrue);

      const degenerate = WakingWindow(startMinutes: 60, endMinutes: 60);
      expect(insideSleepWindow(0, degenerate), isFalse);
    });

    test('parseOffsetsText', () {
      expect(parseOffsetsText('1, 4, 17'), [1, 4, 17]);
      expect(parseOffsetsText('0.25 1  4'), [0.25, 1, 4]);
      expect(parseOffsetsText(''), isNull);
      expect(parseOffsetsText('1, x'), isNull);
    });

    test('scheduleErrorMessage maps every known code', () {
      for (final code in [
        'bad_offsets', 'bad_recurring', 'bad_per_fire', 'bad_interval',
        'bad_times', 'bad_days', 'bad_kind', 'something_else',
      ]) {
        final msg = scheduleErrorMessage(ScheduleConfigError(code));
        expect(msg, isNotEmpty);
        expect(msg, isNot(contains(code))); // mapped, never raw
      }
    });
  });
}
