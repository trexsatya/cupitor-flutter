import 'dart:convert';

import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_bridge.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Webapp notification feed: getNotifications / cupitorNotifFeed / ackItem.
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

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 9,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => CupitorDb.createSchema(d)));
    dao = NotifDao(db);
    events = [];
    now = tz.TZDateTime(ny, 2026, 7, 28, 10);
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
  List<dynamic> lastFeed() =>
      events.lastWhere((e) => e.$1 == 'cupitorNotifFeed').$2['notifications']
          as List;

  /// List with two items and three fire events across them.
  Future<void> seed() async {
    final s = await dao.scheduleByKey('cepeda2x');
    final l = await dao.createList(
        profileId: 1, name: 'French', source: 'webpage',
        externalKey: 'fr', scheduleId: s!.id);
    final a = await dao.insertItem(
        listId: l.id, externalId: 'a', title: 'A', position: 0);
    final b = await dao.insertItem(
        listId: l.id, externalId: 'b', title: 'B', body: 'bee', position: 1);
    await dao.insertEvent(itemId: a.id, firedAt: 1000); // unacknowledged
    await dao.insertEvent(
        itemId: b.id, firedAt: 2000, respondedAt: 2500, grade: 3,
        source: 'action');
    await dao.insertEvent(itemId: a.id, firedAt: 3000, source: 'auto');
  }

  test('recentEvents joins, orders newest-first, limits', () async {
    await seed();
    final all = await dao.recentEvents(1, 50);
    expect(all.map((e) => e.firedAt), [3000, 2000, 1000]);
    expect(all.first.title, 'A');
    expect(all.first.source, 'auto');
    expect(all.first.respondedAt, isNull);
    expect(all[1].grade, 3);
    expect(all[1].listExternalKey, 'fr');
    expect(all[1].listName, 'French');
    expect((await dao.recentEvents(1, 2)), hasLength(2));
    expect(await dao.recentEvents(2, 50), isEmpty); // other profile
  });

  test('getNotifications emits the feed and acks', () async {
    await seed();
    await bridge.handle(
        jsonEncode({'op': 'getNotifications', 'request_id': 'r1'}));
    expect(lastAck()['ok'], true);
    final feed = lastFeed();
    expect(feed, hasLength(3));
    final top = feed.first as Map;
    expect(top['item_external_id'], 'a');
    expect(top['fired_at'], 3000);
    expect(top['responded_at'], isNull); // unacknowledged
    expect(top['source'], 'auto');
    expect((feed[1] as Map)['grade'], 3);
    expect((feed[1] as Map)['list_name'], 'French');
  });

  test('limit is bounded and defaulted', () async {
    await seed();
    await bridge.handle(jsonEncode({'op': 'getNotifications', 'limit': 1}));
    expect(lastFeed(), hasLength(1));
    await bridge.handle(
        jsonEncode({'op': 'getNotifications', 'limit': 'nope'}));
    expect(lastFeed(), hasLength(3)); // fell back to the default 50
  });

  test('ackItem stamps EVERY outstanding fire; idempotent', () async {
    await seed();
    await bridge.handle(jsonEncode({
      'op': 'ackItem', 'request_id': 'r2',
      'external_key': 'fr', 'item_external_id': 'a',
    }));
    expect(lastAck()['ok'], true);

    final feed = await dao.recentEvents(1, 50);
    // Both of a's fires (1000 AND 3000) are read now — an older orphan must
    // not stay permanently unread once the item is acknowledged.
    expect(feed.where((e) => e.respondedAt == null), isEmpty);
    expect(feed.firstWhere((e) => e.firedAt == 2000).respondedAt,
        2500); // b's already-graded row untouched

    // Second ack: nothing left to stamp → ok, unchanged.
    await bridge.handle(jsonEncode({
      'op': 'ackItem', 'external_key': 'fr', 'item_external_id': 'a',
    }));
    expect(lastAck()['ok'], true);
  });

  test('webpage grade acknowledges the item\'s outstanding fires', () async {
    await seed();
    await bridge.handle(jsonEncode({
      'op': 'grade', 'external_key': 'fr', 'item_external_id': 'a',
      'grade': 3,
    }));
    expect(lastAck()['ok'], true);
    final feed = await dao.recentEvents(1, 50);
    // a's two unread fires are stamped; the grade landed as its own event.
    expect(feed.where((e) => e.respondedAt == null), isEmpty);
    expect(feed.where((e) => e.itemExternalId == 'a' && e.grade == 3),
        hasLength(1));
  });

  test('ackItem error codes', () async {
    await seed();
    await bridge.handle(jsonEncode({'op': 'ackItem', 'external_key': 'fr'}));
    expect(lastAck()['error'], 'bad_payload');
    await bridge.handle(jsonEncode({
      'op': 'ackItem', 'external_key': 'nope', 'item_external_id': 'a',
    }));
    expect(lastAck()['error'], 'unknown_list');
    await bridge.handle(jsonEncode({
      'op': 'ackItem', 'external_key': 'fr', 'item_external_id': 'zzz',
    }));
    expect(lastAck()['error'], 'unknown_item');
  });
}
