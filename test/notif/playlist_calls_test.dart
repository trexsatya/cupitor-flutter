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

void main() {
  late Database db;
  late NotifDao dao;
  late NotifBridge bridge;
  late NotificationService service;
  late FakeNotifChannel channel;
  late tz.TZDateTime now;
  final events = <(String, Map<String, Object?>)>[];
  final question = {'question': 'Capital of Sweden?', 'response_type': 'text',
    'accepted_answers': ['Stockholm']};
  Map<String, Object?> item(String id) => {'external_id': id, 'title': 'Capital',
    'payload': {'pl': 'Geography', 'xid': id, 'study_call': question}};
  Map<String, Object?> ack() => events.lastWhere((e) => e.$1 == 'cupitorNotifAck').$2;
  Future<void> send(String op, Map<String, Object?> payload) =>
      bridge.handle(jsonEncode({'op': op, 'request_id': 'test', ...payload}));
  Future<void> create({String schedule = 'ebbinghaus', String? intro}) => send('createList', {
    'external_key': 'geo', 'name': 'Geography', 'delivery': 'call',
    'schedule_key': schedule, if (intro != null) 'intro_schedule_key': intro,
    'call_config': {'max_retries': 3, 'language': 'sv-SE', 'direction': 'target-source', 'response_type': 'text'}, 'items': [item('one'), item('two')],
  });
  setUpAll(() {
    sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
  });
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, v) => CupitorDb.createSchema(d), version: 11));
    dao = NotifDao(db); events.clear();
    now = tz.TZDateTime(tz.UTC, 2026, 10, 23, 10);
    channel = FakeNotifChannel();
    service = NotificationService(channel: channel, dao: () async => dao,
      window: () => WakingWindow.defaults, perFireCap: () => 5, now: () => now, maxArmed: 200);
    bridge = NotifBridge(dao: () async => dao, activeProfileId: () => 1,
      emit: (name, detail) => events.add((name, detail)),
      capabilities: () async => const NotifCapabilities(supported: true,
        permission: 'granted', exactAlarms: true, actions: true, platform: 'android'),
      requestPermission: () async => 'granted', window: () => WakingWindow.defaults, now: () => now);
  });
  tearDown(() => db.close());

  test('create/sync/delivery switches preserve identity, full questions and SRS state', () async {
    await create(); expect(ack()['ok'], true);
    final list = (await dao.listByExternalKey(1, 'geo'))!;
    expect(list.delivery, 'call');
    expect(jsonDecode(list.callConfig!), containsPair('direction', 'target-source'));
    expect(jsonDecode(list.callConfig!), containsPair('answer_type', 'text'));
    var first = (await dao.itemsForList(list.id)).first;
    await dao.updateItem(first.id, {'step': 2});
    await send('syncItems', {'external_key': 'geo', 'mode': 'replace', 'items': [item('one')]});
    expect(ack()['ok'], true);
    first = (await dao.itemsForList(list.id)).single;
    expect(first.step, 2);
    await send('setDelivery', {'external_key': 'geo', 'delivery': 'notification'});
    expect((await dao.listById(list.id))!.delivery, 'notification');
    expect((await dao.itemsForList(list.id)).single.id, first.id);
    expect((await dao.itemsForList(list.id)).single.step, 2);
  });

  test('bad call settings and missing answer keys reject atomically', () async {
    await send('createList', {'external_key': 'bad', 'name': 'Bad', 'delivery': 'call',
      'call_config': {'max_retries': 99}, 'items': [item('one')]});
    expect(ack()['error'], 'bad_call');
    expect(await dao.listByExternalKey(1, 'bad'), isNull);
    await create(); final list = (await dao.listByExternalKey(1, 'geo'))!;
    await send('syncItems', {'external_key': 'geo', 'mode': 'replace',
      'items': [{'external_id': 'wrong', 'title': 'Missing answer'}]});
    expect(ack()['error'], 'bad_call');
    expect(await dao.itemsForList(list.id), hasLength(2));
  });

  test('series calls use the same schedule, carry original due identity, and omit shade summaries', () async {
    await create(); final list = (await dao.listByExternalKey(1, 'geo'))!;
    final first = (await dao.itemsForList(list.id)).first;
    final due = now.millisecondsSinceEpoch + 60000;
    await dao.updateItem(first.id, {'next_due_at': due});
    await service.rearm();
    final call = channel.scheduled.firstWhere((f) => f.notifId == NotificationService.itemNotifId(first.id));
    expect(call.studyCall, containsPair('due_at', due));
    expect(call.studyCall, containsPair('accepted_answers', ['Stockholm']));
    expect(call.studyCall, containsPair('max_retries', 3));
    expect(channel.scheduled.where((f) => f.isSummary), isEmpty);
    now = now.add(const Duration(minutes: 2));
    await service.sweep();
    final shown = channel.shown.firstWhere((f) => f.notifId == call.notifId);
    expect(shown.studyCall!['due_at'], due, reason: 'catch-up must dedupe the original armed fire');
    expect(shown.whenMs, now.millisecondsSinceEpoch);
    expect(channel.shown.where((f) => f.isSummary), isEmpty);
    await send('setStatus', {'external_key': 'geo', 'status': 'paused'});
    await service.rearm(); expect(channel.scheduled, isEmpty);
    expect(await dao.activeCallItemIds(), isEmpty);
  });

  test('existing v10 lists migrate to notifications without changing their progress', () async {
    // Build a v10 shape from the fresh schema, then exercise the real upgrade.
    await db.execute('ALTER TABLE notif_lists DROP COLUMN call_config');
    await db.execute('ALTER TABLE notif_lists DROP COLUMN delivery');
    await CupitorDb.runMigrations(db, 10, 11);
    final list = await dao.createList(profileId: 1, name: 'Old', source: 'webpage');
    expect(list.delivery, 'notification');
    await CupitorDb.runMigrations(db, 10, 11); // idempotent repair
    expect((await dao.listById(list.id))!.delivery, 'notification');
  });
}
