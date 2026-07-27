import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/schedules.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late NotifDao dao;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 7,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, v) => CupitorDb.createSchema(d)));
    dao = NotifDao(db);
  });
  tearDown(() => db.close());

  test('listSchedules returns the 7 seeds; scheduleByKey resolves both forms',
      () async {
    expect(await dao.listSchedules(), hasLength(7));
    final eb = await dao.scheduleByKey('ebbinghaus');
    expect(eb!.kind, 'series');
    final custom = await dao.createCustomSchedule(
        name: 'Mine', kind: 'series',
        config: {'offsets_waking_hours': [1, 2, 4]});
    final again = await dao.scheduleByKey('custom:${custom.id}');
    expect(again!.name, 'Mine');
    expect(await dao.scheduleByKey('nope'), isNull);
    expect(await dao.scheduleByKey('custom:zzz'), isNull);
  });

  test('createCustomSchedule rejects invalid config', () async {
    expect(
        () => dao.createCustomSchedule(
            name: 'Bad', kind: 'series', config: {'offsets_waking_hours': []}),
        throwsA(isA<ScheduleConfigError>()));
  });

  test('list + item lifecycle with cascade delete', () async {
    final eb = await dao.scheduleByKey('ebbinghaus');
    final list = await dao.createList(
        profileId: 1, name: 'French', source: 'webpage',
        externalKey: 'fr-1', scheduleId: eb!.id);
    expect((await dao.listByExternalKey(1, 'fr-1'))!.id, list.id);
    expect(await dao.listByExternalKey(1, 'zzz'), isNull);

    final item = await dao.insertItem(
        listId: list.id, externalId: 'c1', title: 'le dénouement',
        position: 0, nextDueAt: 1000);
    expect((await dao.itemsForList(list.id)), hasLength(1));
    expect((await dao.itemByExternalId(list.id, 'c1'))!.id, item.id);

    await dao.updateItem(item.id, {'step': 2, 'next_due_at': 5000});
    expect((await dao.itemByExternalId(list.id, 'c1'))!.step, 2);

    await dao.insertEvent(
        itemId: item.id, firedAt: 1000, respondedAt: 1100,
        grade: 3, source: 'webpage');
    expect((await dao.lastEventForItem(item.id))!.grade, 3);

    await dao.deleteList(list.id);
    expect(await dao.itemsForList(list.id), isEmpty);
    expect(await dao.lastEventForItem(item.id), isNull); // cascaded
  });

  test('updateList bumps updated_at', () async {
    final list = await dao.createList(
        profileId: 1, name: 'L', source: 'app');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await dao.updateList(list.id, {'status': 'paused'});
    final rows = await dao.listsForProfile(1);
    expect(rows.single.status, 'paused');
    expect(rows.single.updatedAt, greaterThan(list.updatedAt));
  });

  test('dueItems: only active items in active lists, due, ordered', () async {
    final eb = await dao.scheduleByKey('ebbinghaus');
    final a = await dao.createList(
        profileId: 1, name: 'A', source: 'app', scheduleId: eb!.id);
    final b = await dao.createList(
        profileId: 1, name: 'B', source: 'app', scheduleId: eb.id);
    await dao.insertItem(listId: a.id, title: 'due-late', position: 0, nextDueAt: 200);
    await dao.insertItem(listId: a.id, title: 'due-early', position: 1, nextDueAt: 100);
    await dao.insertItem(listId: a.id, title: 'future', position: 2, nextDueAt: 9999);
    final suspended = await dao.insertItem(
        listId: a.id, title: 'suspended', position: 3, nextDueAt: 100);
    await dao.updateItem(suspended.id, {'status': 'suspended'});
    await dao.insertItem(listId: b.id, title: 'paused-list', position: 0, nextDueAt: 100);
    await dao.updateList(b.id, {'status': 'paused'});

    final due = await dao.dueItems(500);
    expect(due.map((i) => i.title), ['due-early', 'due-late']);
  });

  test('UNIQUE(list_id, external_id) allows multiple NULLs', () async {
    final list = await dao.createList(profileId: 1, name: 'L', source: 'app');
    await dao.insertItem(listId: list.id, title: 'one', position: 0);
    await dao.insertItem(listId: list.id, title: 'two', position: 1);
    expect(await dao.itemsForList(list.id), hasLength(2));
  });

  test('upcomingItems: future window, active∩active, ordered', () async {
    final eb = await dao.scheduleByKey('ebbinghaus');
    final a = await dao.createList(
        profileId: 1, name: 'A', source: 'app', scheduleId: eb!.id);
    await dao.insertItem(listId: a.id, title: 'past', position: 0, nextDueAt: 50);
    await dao.insertItem(listId: a.id, title: 'in-window', position: 1, nextDueAt: 150);
    await dao.insertItem(listId: a.id, title: 'beyond', position: 2, nextDueAt: 950);
    final up = await dao.upcomingItems(100, 900);
    expect(up.map((i) => i.title), ['in-window']);
  });

  test('recurringDueLists / recurringUpcomingLists filter on next_fire_at and status',
      () async {
    final daily = await dao.scheduleByKey('daily_0900');
    final l1 = await dao.createList(
        profileId: 1, name: 'due', source: 'app',
        scheduleId: daily!.id, nextFireAt: 100);
    final l2 = await dao.createList(
        profileId: 1, name: 'upcoming', source: 'app',
        scheduleId: daily.id, nextFireAt: 500);
    final l3 = await dao.createList(
        profileId: 1, name: 'paused', source: 'app',
        scheduleId: daily.id, nextFireAt: 100);
    await dao.updateList(l3.id, {'status': 'paused'});
    // Second profile — must still be visible (notifications are profile-agnostic).
    await db.insert('profiles',
        {'id': 2, 'name': 'P2', 'created_at': 1});
    final other = await dao.createList(
        profileId: 2, name: 'other-profile', source: 'app',
        scheduleId: daily.id, nextFireAt: 100);

    final due = await dao.recurringDueLists(200);
    expect(due.map((l) => l.id), containsAll([l1.id, other.id]));
    expect(due.map((l) => l.id), isNot(contains(l3.id)));
    final up = await dao.recurringUpcomingLists(200, 900);
    expect(up.map((l) => l.id), [l2.id]);
  });

  test('itemById / listById', () async {
    final l = await dao.createList(profileId: 1, name: 'L', source: 'app');
    final i = await dao.insertItem(listId: l.id, title: 'x', position: 0);
    expect((await dao.itemById(i.id))!.title, 'x');
    expect((await dao.listById(l.id))!.name, 'L');
    expect(await dao.itemById(999999), isNull);
    expect(await dao.listById(999999), isNull);
  });
}
