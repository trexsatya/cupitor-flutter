# Notifications Plan 2/3: Delivery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notifications actually fire. Pre-armed OS alarms deliver items (spec's hybrid model), tap opens dialog1, Again/Good/Easy action buttons grade offline, a shared sweep catches missed fires, Android gets a WorkManager safety net, and desktop/web get the best-effort in-process timer.

**Architecture:** Spec `docs/superpowers/specs/2026-07-27-notifications-design.md`, §Delivery. Two new seams over Plan 1: `NotifChannel` (the ONLY code that imports a notification plugin — everything above it tests against a fake) and `NotificationService` (`rearm()` + `sweep()`, pure logic over injected channel/dao/clock). Plan 1's `NotifBridge.onMutated` gets wired to `rearm()`.

**Tech Stack:** `flutter_local_notifications` (Android/iOS/macOS/Linux incl. offline action buttons), `workmanager` (Android periodic safety net). Existing: `timezone`, Plan 1's engines/DAO/bridge.

**Conventions for the executor:**
- Repo root: `Cupitor/`. Flutter binary: `/Users/satyendra.kumar/Documents/PersonalProjects/flutter/flutter/bin/flutter`.
- Tests: `flutter test <path> -r expanded`. Co-author trailer on every commit.
- **Plugin API drift is expected.** The code below targets the flutter_local_notifications v17/18-era API. If the resolved version's signatures differ (e.g. `zonedSchedule` params, permission method names), adapt the call site inside `notification_channel.dart` ONLY — the `NotifChannel` interface and everything above it must not change. Same for `workmanager`.
- Device-dependent behavior (permission prompts, reboot, Doze, killed-app actions) is verified by the Task 12 manual checklist, not unit tests. Unit tests cover everything with a fake channel.

**Fire semantics locked by the spec (do not re-decide):**
- `rearm()` arms strictly-future fires in a 48h window; overdue is `sweep()`'s job.
- A fire auto-advances the item (`advanceSeries(grade: null)`) at the moment it is posted/processed — that IS the automatic fading; a later grade re-advances from the new state (Again resets regardless).
- Sweep grace: overdue ≤ 2 *waking* hours → post now; older → advance silently with event `source:'auto'`.
- Grouped per list, global per-minute cap `NotifSettings.perFireCap` (default 5), armed-total cap 60 iOS / 200 elsewhere.
- Action buttons only for series-list items (grading a recurring list is `not_series`).
- Notifications must work across ALL profiles, not just the active one (a profile switch must not silence another profile's reviews).

---

## Task 1: Dependencies

**Files:** Modify `pubspec.yaml`

- [ ] **Step 1:** Under `dependencies:` after the `flutter_timezone` entry add:

```yaml
  # Delivery layer (Plan 2). flutter_local_notifications: pre-armed OS alarms
  # + offline action buttons on Android/iOS/macOS/Linux. workmanager: Android
  # periodic safety net (rearm + sweep) — spec §Delivery.
  flutter_local_notifications: ^18.0.1
  workmanager: ^0.5.2
```

- [ ] **Step 2:** `flutter pub get`. If `flutter_local_notifications ^18` conflicts with `timezone ^0.9.4`, first try `^17.2.0`; if only a 19.x resolves, bump `timezone` to `^0.10.0` (our usage — `TZDateTime`, `Location`, `initializeTimeZones` — is API-stable across 0.9/0.10) and re-run the full test suite. If `workmanager ^0.5.2` is superseded, take the latest stable. Record the resolved versions in the commit body.
- [ ] **Step 3:** `flutter analyze` — no new issues. `flutter test test/notif/ -r expanded` — 101 pass.
- [ ] **Step 4:** Commit `feat(notif): add flutter_local_notifications + workmanager deps` (include pubspec.lock and any regenerated plugin registrants).

---

## Task 2: `PendingFire` + `NotifChannel` interface + fake

**Files:**
- Create: `lib/notif/pending_fire.dart`
- Create: `lib/notif/notif_channel.dart`
- Create: `test/notif/fake_notif_channel.dart` (test helper, no `_test` suffix so the runner skips it)

- [ ] **Step 1:** Create `lib/notif/pending_fire.dart`:

```dart
/// One concrete notification the service wants shown — either scheduled for
/// [whenMs] (epoch ms, strictly future) or posted immediately via showNow.
/// Content is frozen at arm time (spec §Delivery): the OS holds this, the
/// app may be dead when it fires.
class PendingFire {
  /// Stable id derived from the item id (see NotificationService.itemNotifId)
  /// so cancel-and-rearm is idempotent.
  final int notifId;
  final int whenMs;
  final String title;
  final String? body;

  /// JSON the tap/action callbacks get back:
  /// {"v":1,"item_id":<internal>,"list_ek":...,"item_eid":...,"open_url":...,
  ///  "echo":<webpage payload>} — internal id stays inside the app; only
  /// external ids ever reach the webpage (spec identity rule).
  final String payloadJson;

  /// Android group / Darwin thread id — one group per list.
  final String groupKey;

  /// Again/Good/Easy buttons. Only true for series-list items.
  final bool withActions;

  const PendingFire({
    required this.notifId,
    required this.whenMs,
    required this.title,
    this.body,
    required this.payloadJson,
    required this.groupKey,
    required this.withActions,
  });
}
```

- [ ] **Step 2:** Create `lib/notif/notif_channel.dart`:

```dart
import 'pending_fire.dart';

/// Callbacks out of the notification system into the app. Wired in main.dart
/// (foreground) and the background action handler (Task 8).
class NotifCallbacks {
  /// User tapped the notification body. [payloadJson] is PendingFire.payloadJson.
  final Future<void> Function(String payloadJson) onOpened;

  /// User tapped an action button ('again' | 'good' | 'easy').
  final Future<void> Function(String actionId, String payloadJson) onAction;

  const NotifCallbacks({required this.onOpened, required this.onAction});
}

/// The ONLY seam that touches a notification plugin (spec §Code layout:
/// "the only file importing a notification package" is its implementation,
/// notification_channel.dart). Everything above tests against a fake.
abstract class NotifChannel {
  Future<void> init(NotifCallbacks callbacks);

  /// 'granted' | 'denied' | 'unknown'
  Future<String> permissionStatus();
  Future<String> requestPermission();

  /// Android: SCHEDULE_EXACT_ALARM granted? Always true elsewhere.
  Future<bool> exactAlarmsAllowed();

  Future<void> schedule(PendingFire fire);
  Future<void> showNow(PendingFire fire);

  /// Cancel every notification this app has pending. Cupitor has no local
  /// notifications outside this feature, so plugin-level cancelAll is safe.
  Future<void> cancelAllScheduled();

  /// Offline action buttons available on this platform?
  bool get supportsActions;
}
```

- [ ] **Step 3:** Create `test/notif/fake_notif_channel.dart`:

```dart
import 'package:cupitor/notif/notif_channel.dart';
import 'package:cupitor/notif/pending_fire.dart';

/// In-memory NotifChannel for service tests: records exactly what the
/// service armed/showed/cancelled, in order.
class FakeNotifChannel implements NotifChannel {
  final List<PendingFire> scheduled = [];
  final List<PendingFire> shown = [];
  int cancelAllCalls = 0;
  String permission = 'granted';
  bool exactAllowed = true;
  NotifCallbacks? callbacks;

  @override
  Future<void> init(NotifCallbacks cb) async => callbacks = cb;
  @override
  Future<String> permissionStatus() async => permission;
  @override
  Future<String> requestPermission() async => permission;
  @override
  Future<bool> exactAlarmsAllowed() async => exactAllowed;
  @override
  Future<void> schedule(PendingFire fire) async => scheduled.add(fire);
  @override
  Future<void> showNow(PendingFire fire) async => shown.add(fire);
  @override
  Future<void> cancelAllScheduled() async {
    cancelAllCalls++;
    scheduled.clear();
  }
  @override
  bool get supportsActions => true;
}
```

- [ ] **Step 4:** `flutter analyze lib/notif test/notif` → clean. (No tests yet — these are interfaces; Task 3 tests them through the service.)
- [ ] **Step 5:** Commit `feat(notif): PendingFire + NotifChannel seam + test fake`.

---

## Task 3: DAO additions for delivery

The service needs queries Plan 1 didn't: upcoming (future) items, due/upcoming recurring lists (across ALL profiles), and by-id lookups for the tap/action handlers.

**Files:**
- Modify: `lib/notif/notif_dao.dart`
- Modify: `test/notif/notif_dao_test.dart`

- [ ] **Step 1:** Append tests to `test/notif/notif_dao_test.dart` (inside `main()`):

```dart
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
```

- [ ] **Step 2:** Run → FAIL (methods missing).
- [ ] **Step 3:** Add to `NotifDao` (below `dueItems`):

```dart
  /// Active items in active lists due strictly AFTER [fromMs] and at or
  /// before [toMs] — the rearm window. Profile-agnostic by design: reviews
  /// keep firing for every profile (spec §Delivery).
  Future<List<NotifItemRow>> upcomingItems(int fromMs, int toMs) async =>
      (await db.rawQuery('''
        SELECT i.* FROM notif_items i
        JOIN notif_lists l ON l.id = i.list_id
        WHERE i.status = 'active' AND l.status = 'active'
          AND i.next_due_at IS NOT NULL
          AND i.next_due_at > ? AND i.next_due_at <= ?
        ORDER BY i.next_due_at ASC, i.id ASC
      ''', [fromMs, toMs]))
          .map(NotifItemRow.fromMap)
          .toList(growable: false);

  /// Active lists whose recurring fire time has passed. Profile-agnostic.
  Future<List<NotifListRow>> recurringDueLists(int nowMs) async =>
      (await db.query('notif_lists',
              where: "status = 'active' AND next_fire_at IS NOT NULL "
                  'AND next_fire_at <= ?',
              whereArgs: [nowMs],
              orderBy: 'next_fire_at ASC, id ASC'))
          .map(NotifListRow.fromMap)
          .toList(growable: false);

  /// Active lists firing inside the rearm window (strictly future).
  Future<List<NotifListRow>> recurringUpcomingLists(int fromMs, int toMs) async =>
      (await db.query('notif_lists',
              where: "status = 'active' AND next_fire_at IS NOT NULL "
                  'AND next_fire_at > ? AND next_fire_at <= ?',
              whereArgs: [fromMs, toMs],
              orderBy: 'next_fire_at ASC, id ASC'))
          .map(NotifListRow.fromMap)
          .toList(growable: false);

  Future<NotifItemRow?> itemById(int id) async {
    final r = await db.query('notif_items',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : NotifItemRow.fromMap(r.first);
  }

  Future<NotifListRow?> listById(int id) async {
    final r = await db.query('notif_lists',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : NotifListRow.fromMap(r.first);
  }
```

- [ ] **Step 4:** `flutter test test/notif/notif_dao_test.dart -r expanded` → pass; whole suite still green.
- [ ] **Step 5:** Commit `feat(notif): DAO delivery queries — upcoming items, recurring fires, by-id`.

---

## Task 4: `NotificationService.rearm()`

**Files:**
- Create: `lib/notif/notification_service.dart`
- Create: `test/notif/notification_service_test.dart`

- [ ] **Step 1:** Tests first. Create `test/notif/notification_service_test.dart`:

```dart
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
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Create `lib/notif/notification_service.dart`:

```dart
import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'notif_channel.dart';
import 'notif_dao.dart';
import 'pending_fire.dart';
import 'recurring_scheduler.dart';
import 'schedules.dart';
import 'series_scheduler.dart';
import 'waking_clock.dart';

/// Arms and catches up notification fires (spec §Delivery). All state lives
/// in SQLite; this class is a pure translation from "what's due/upcoming"
/// to NotifChannel calls, so it tests fully against FakeNotifChannel.
/// Profile-agnostic on purpose: every profile's reviews keep firing.
class NotificationService {
  final NotifChannel channel;
  final Future<NotifDao?> Function() dao;
  final WakingWindow Function() window;
  final int Function() perFireCap;
  final tz.TZDateTime Function() now;

  /// 60 on iOS (headroom under the 64-pending hard cap), 200 elsewhere.
  final int maxArmed;

  NotificationService({
    required this.channel,
    required this.dao,
    required this.window,
    required this.perFireCap,
    required this.now,
    required this.maxArmed,
  });

  /// Stable notification ids: cancel-and-rearm must be idempotent and a
  /// grade must be able to cancel exactly its own notification. Offsets
  /// keep item- and list-anchored ids in disjoint ranges (int32-safe).
  static int itemNotifId(int itemId) => 0x1000000 + itemId;

  /// Rearm window: 48 absolute hours (spec §Arming).
  static const int windowMs = 48 * 3600 * 1000;

  /// Sweep grace: overdue by at most this many WAKING hours → post now;
  /// older → silent auto-advance (spec §The sweep).
  static const double graceWakingHours = 2;

  // ── rearm ────────────────────────────────────────────────────────────

  /// Cancel-everything-then-arm-the-window. Triggers (wired in main.dart /
  /// worker): app resume, boot, any fire, any grade, any bridge mutation,
  /// settings change, worker tick.
  Future<void> rearm() async {
    final d = await dao();
    if (d == null) return;
    final t = now();
    final nowMs = t.millisecondsSinceEpoch;

    await channel.cancelAllScheduled();

    final fires = <PendingFire>[];
    for (final item in await d.upcomingItems(nowMs, nowMs + windowMs)) {
      fires.add(await _itemFire(d, item, item.nextDueAt!,
          withActions: await _isSeriesList(d, item.listId)));
    }
    for (final list in await d.recurringUpcomingLists(nowMs, nowMs + windowMs)) {
      fires.addAll(await _recurringFires(d, list, list.nextFireAt!));
    }

    fires.sort((a, b) => a.whenMs.compareTo(b.whenMs));
    final cap = perFireCap();
    final perMinute = <int, int>{};
    var armed = 0;
    for (final f in fires) {
      if (armed >= maxArmed) break;
      final bucket = f.whenMs ~/ 60000;
      final inBucket = perMinute[bucket] ?? 0;
      if (inBucket >= cap) continue; // deferred: next rearm picks it up
      perMinute[bucket] = inBucket + 1;
      armed++;
      await channel.schedule(f);
    }
  }

  // ── shared fire construction ─────────────────────────────────────────

  Future<bool> _isSeriesList(NotifDao d, int listId) async {
    final list = await d.listById(listId);
    if (list?.scheduleId == null) return false;
    final s = await d.scheduleById(list!.scheduleId!);
    return s?.kind == 'series';
  }

  Future<PendingFire> _itemFire(NotifDao d, NotifItemRow item, int whenMs,
      {required bool withActions}) async {
    final list = await d.listById(item.listId);
    return PendingFire(
      notifId: itemNotifId(item.id),
      whenMs: whenMs,
      title: item.title,
      body: item.body,
      payloadJson: jsonEncode({
        'v': 1,
        'item_id': item.id,
        'list_ek': list?.externalKey,
        'item_eid': item.externalId,
        'open_url': item.openUrl,
        'echo': item.payload == null ? null : jsonDecode(item.payload!),
      }),
      groupKey: 'cupitor-notif-list-${item.listId}',
      withActions: withActions && channel.supportsActions,
    );
  }

  /// The items a recurring list would show at [whenMs], selected with the
  /// CURRENT cursor. The cursor only advances when the fire is processed
  /// (sweep) — consecutive unattended fires may repeat items; documented
  /// spec §Delivery trade-off for content frozen at arm time.
  Future<List<PendingFire>> _recurringFires(
      NotifDao d, NotifListRow list, int whenMs) async {
    final schedule =
        list.scheduleId == null ? null : await d.scheduleById(list.scheduleId!);
    if (schedule == null || schedule.kind != 'recurring') return const [];
    final cfg = parseRecurring(
        jsonDecode(schedule.config) as Map<String, dynamic>);
    final items = await d.itemsForList(list.id);
    final sel = takeForFire<NotifItemRow>(
        items, list.cursor, cfg.perFire, (i) => i.status == 'active');
    return [
      for (final item in sel.items)
        await _itemFire(d, item, whenMs, withActions: false)
    ];
  }

  // ── sweep (Task 5 fills in the body; declared here so main.dart compiles
  //    incrementally — implemented in the same file, next task) ──────────
}
```

- [ ] **Step 4:** `flutter test test/notif/notification_service_test.dart -r expanded` → pass; suite green; analyze clean.
- [ ] **Step 5:** Commit `feat(notif): NotificationService.rearm — windowed arming with caps`.

---

## Task 5: `NotificationService.sweep()`

**Files:** Modify `lib/notif/notification_service.dart`, `test/notif/notification_service_test.dart`

- [ ] **Step 1:** Append tests (inside `main()`, new group):

```dart
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
```

- [ ] **Step 2:** Run → FAIL (`sweep` missing).
- [ ] **Step 3:** Implement in `notification_service.dart` (replace the trailing placeholder comment):

```dart
  // ── sweep ────────────────────────────────────────────────────────────

  /// Catch-up: process everything whose fire time has passed, then rearm.
  /// One function, three callers (spec §The sweep): Android worker, app
  /// launch/resume, desktop/web timer.
  Future<void> sweep() async {
    final d = await dao();
    if (d == null) return;
    final t = now();
    final nowMs = t.millisecondsSinceEpoch;
    final w = window();
    final cap = perFireCap();
    var posted = 0;

    // Overdue series items.
    for (final item in await d.dueItems(nowMs)) {
      final due = item.nextDueAt!;
      final last = await d.lastEventForItem(item.id);
      if (last != null && last.firedAt >= due) continue; // already handled
      final withinGrace = wakingHoursBetween(
              tz.TZDateTime.fromMillisecondsSinceEpoch(t.location, due),
              t, w) <=
          graceWakingHours;
      final fireNow = withinGrace && posted < cap;
      if (fireNow) {
        posted++;
        await channel.showNow(await _itemFire(d, item, nowMs,
            withActions: await _isSeriesList(d, item.listId)));
      }
      // Automatic fading: every processed fire advances one step. Items in
      // recurring lists carry due times only if they have prior series
      // state; advancing them is harmless and keeps one code path.
      final offsets = await _offsetsForList(d, item.listId);
      if (offsets != null) {
        final o = advanceSeries(
            step: item.step, done: item.status == 'done',
            offsetsWakingHours: offsets, now: t, grade: null, window: w);
        await d.updateItem(item.id, {
          'step': o.step,
          'status': o.done ? 'done' : 'active',
          'next_due_at': o.nextDue?.millisecondsSinceEpoch,
          'last_fired_at': nowMs,
        });
      } else {
        await d.updateItem(item.id,
            {'next_due_at': null, 'last_fired_at': nowMs});
      }
      await d.insertEvent(
          itemId: item.id, firedAt: nowMs, source: fireNow ? null : 'auto');
    }

    // Due recurring lists.
    for (final list in await d.recurringDueLists(nowMs)) {
      final schedule = list.scheduleId == null
          ? null
          : await d.scheduleById(list.scheduleId!);
      if (schedule == null || schedule.kind != 'recurring') {
        await d.updateList(list.id, {'next_fire_at': null});
        continue;
      }
      final cfg = parseRecurring(
          jsonDecode(schedule.config) as Map<String, dynamic>);
      final withinGrace = wakingHoursBetween(
              tz.TZDateTime.fromMillisecondsSinceEpoch(
                  t.location, list.nextFireAt!),
              t, w) <=
          graceWakingHours;
      var newCursor = list.cursor;
      if (withinGrace) {
        final items = await d.itemsForList(list.id);
        final sel = takeForFire<NotifItemRow>(
            items, list.cursor, cfg.perFire, (i) => i.status == 'active');
        for (final item in sel.items) {
          if (posted >= cap) break;
          posted++;
          await channel.showNow(
              await _itemFire(d, item, nowMs, withActions: false));
          await d.updateItem(item.id, {'last_fired_at': nowMs});
          await d.insertEvent(itemId: item.id, firedAt: nowMs);
        }
        newCursor = sel.newCursor;
      }
      await d.updateList(list.id, {
        'cursor': newCursor,
        'last_fired_at': withinGrace ? nowMs : list.lastFiredAt,
        'next_fire_at':
            nextRecurringFire(cfg, t, w).millisecondsSinceEpoch,
      });
    }

    await rearm();
  }

  Future<List<double>?> _offsetsForList(NotifDao d, int listId) async {
    final list = await d.listById(listId);
    if (list?.scheduleId == null) return null;
    final s = await d.scheduleById(list!.scheduleId!);
    if (s == null || s.kind != 'series') return null;
    return seriesOffsets(jsonDecode(s.config) as Map<String, dynamic>);
  }
```

- [ ] **Step 4:** Full suite + analyze → green/clean.
- [ ] **Step 5:** Commit `feat(notif): NotificationService.sweep — grace fires, auto-advance, recurring catch-up`.

---

## Task 6: Grading from a notification response (shared handler)

The tap/action handlers (foreground Task 7, background Task 8) share one pure-logic entry: grade-by-payload. Putting it on the service keeps both handlers thin and testable.

**Files:** Modify `lib/notif/notification_service.dart`, `test/notif/notification_service_test.dart`

- [ ] **Step 1:** Tests (new group):

```dart
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

    test('good and easy advance from the post-fire step', () async {
      final (_, item) = await firedItem(); // step 1 after auto-advance
      await service.handleAction(
          'easy', jsonEncode({'v': 1, 'item_id': item.id}));
      expect((await dao.itemById(item.id))!.step, 3); // 1 + 2
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
  });
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement on `NotificationService`:

```dart
  // ── notification responses ───────────────────────────────────────────

  static const Map<String, int> actionGrades = {
    'again': gradeAgain,
    'good': gradeGood,
    'easy': gradeEasy,
  };

  /// Grade an item from a notification action button. Returns
  /// ((list_ek, item_eid), grade) for the caller to emit cupitorNotifGraded
  /// (foreground only — the background isolate has no webview), or null on
  /// any invalid input — a notification action must never crash the app.
  Future<((String?, String?), int)?> handleAction(
      String actionId, String payloadJson) async {
    final grade = actionGrades[actionId];
    if (grade == null) return null;
    final d = await dao();
    if (d == null) return null;
    Map<String, dynamic> p;
    try {
      p = jsonDecode(payloadJson) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final itemId = p['item_id'];
    if (itemId is! int) return null;
    final item = await d.itemById(itemId);
    if (item == null) return null;
    final offsets = await _offsetsForList(d, item.listId);
    if (offsets == null) return null; // not a series list (or list gone)

    final t = now();
    final o = advanceSeries(
        step: item.step, done: item.status == 'done',
        offsetsWakingHours: offsets, now: t, grade: grade, window: window());
    await d.updateItem(item.id, {
      'step': o.step,
      'status': o.done ? 'done' : 'active',
      'next_due_at': o.nextDue?.millisecondsSinceEpoch,
      'last_grade': grade,
    });
    final nowMs = t.millisecondsSinceEpoch;
    await d.insertEvent(
        itemId: item.id, firedAt: item.lastFiredAt ?? nowMs,
        respondedAt: nowMs, grade: grade, source: 'action');
    final list = await d.listById(item.listId);
    await rearm();
    return ((list?.externalKey, item.externalId), grade);
  }

  /// Body tap: stamp responded_at on the item's latest event so the sweep's
  /// already-handled check sees it. Navigation is the caller's job.
  Future<void> recordOpened(String payloadJson) async {
    final d = await dao();
    if (d == null) return;
    try {
      final p = jsonDecode(payloadJson) as Map<String, dynamic>;
      final itemId = p['item_id'];
      if (itemId is! int) return;
      final last = await d.lastEventForItem(itemId);
      if (last != null && last.respondedAt == null) {
        await d.db.update('notif_events', {'responded_at': now().millisecondsSinceEpoch},
            where: 'id = ?', whereArgs: [last.id]);
      }
    } catch (_) {/* never crash on a tap */}
  }
```

Note: `recordOpened` needs the raw `db` — `NotifDao.db` is already public. If you prefer, add a tiny `markEventResponded(int eventId, int ms)` to `NotifDao` instead; either is acceptable, but if you add the DAO method, test it in the DAO test file.

- [ ] **Step 4:** Full suite + analyze → green/clean.
- [ ] **Step 5:** Commit `feat(notif): grade-from-notification + opened-event handling`.

---

## Task 7: `FlutterNotifChannel` — the plugin adapter

**Files:**
- Create: `lib/notif/notification_channel.dart`
- Modify: `lib/main.dart` (nothing yet — wiring is Task 8)

No unit tests — this file is exactly the untestable plugin surface the `NotifChannel` seam exists to isolate. Verification: `flutter analyze` + it compiles into the app + Task 12 manual checklist.

- [ ] **Step 1:** Create `lib/notif/notification_channel.dart`:

```dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'notif_channel.dart';
import 'pending_fire.dart';

/// Background action entry point — must be top-level with vm:entry-point so
/// the engine can invoke it in a fresh isolate while the app is dead.
/// Delegates to the handler main.dart registers (Task 8's
/// notifBackgroundActionHandler); kept here so this file remains the only
/// plugin importer.
@pragma('vm:entry-point')
void notifBackgroundResponse(NotificationResponse response) {
  FlutterNotifChannel.backgroundHandler?.call(response.actionId ?? '',
      response.payload ?? '');
}

/// flutter_local_notifications adapter. The ONLY file that imports the
/// plugin (spec §notification_channel). Android channel id/name and the
/// Darwin category are fixed constants — changing them orphans armed
/// notifications.
class FlutterNotifChannel implements NotifChannel {
  static const String androidChannelId = 'cupitor_reviews';
  static const String androidChannelName = 'Review reminders';
  static const String darwinCategoryId = 'cupitorNotif';

  /// Set by main.dart before init; used by the background entry point.
  static void Function(String actionId, String payloadJson)? backgroundHandler;

  final _plugin = FlutterLocalNotificationsPlugin();
  NotifCallbacks? _callbacks;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _isDarwin =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  bool get supportsActions => _isAndroid || _isDarwin;

  @override
  Future<void> init(NotifCallbacks callbacks) async {
    _callbacks = callbacks;
    const actions = [
      DarwinNotificationAction.plain('again', 'Again'),
      DarwinNotificationAction.plain('good', 'Good'),
      DarwinNotificationAction.plain('easy', 'Easy'),
    ];
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(darwinCategoryId, actions: actions),
      ],
    );
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: darwin,
      macOS: darwin,
      linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notifBackgroundResponse,
    );
  }

  void _onResponse(NotificationResponse r) {
    final cb = _callbacks;
    if (cb == null) return;
    final payload = r.payload ?? '';
    if (r.notificationResponseType ==
        NotificationResponseType.selectedNotificationAction) {
      cb.onAction(r.actionId ?? '', payload);
    } else {
      cb.onOpened(payload);
    }
  }

  /// Terminated-tap: if the app was launched by tapping a notification,
  /// return its payload so main.dart can route after startup.
  Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details!.notificationResponse?.payload;
  }

  @override
  Future<String> permissionStatus() async {
    try {
      if (_isAndroid) {
        final enabled = await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.areNotificationsEnabled();
        return enabled == null ? 'unknown' : (enabled ? 'granted' : 'denied');
      }
      if (_isDarwin) {
        // checkPermissions exists on newer plugin versions; fall back to
        // 'unknown' where unavailable rather than guessing.
        return 'unknown';
      }
    } catch (e) {
      debugPrint('notif permissionStatus failed: $e');
    }
    return 'unknown';
  }

  @override
  Future<String> requestPermission() async {
    try {
      if (_isAndroid) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        return granted == true ? 'granted' : 'denied';
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        return granted == true ? 'granted' : 'denied';
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        return granted == true ? 'granted' : 'denied';
      }
    } catch (e) {
      debugPrint('notif requestPermission failed: $e');
    }
    return 'unknown';
  }

  @override
  Future<bool> exactAlarmsAllowed() async {
    if (!_isAndroid) return true;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  NotificationDetails _details(PendingFire fire, {required bool exact}) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        androidChannelId,
        androidChannelName,
        channelDescription: 'Spaced-repetition review reminders',
        groupKey: fire.groupKey,
        actions: fire.withActions
            ? const [
                AndroidNotificationAction('again', 'Again',
                    showsUserInterface: false),
                AndroidNotificationAction('good', 'Good',
                    showsUserInterface: false),
                AndroidNotificationAction('easy', 'Easy',
                    showsUserInterface: false),
              ]
            : null,
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: fire.withActions ? darwinCategoryId : null,
        threadIdentifier: fire.groupKey,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: fire.withActions ? darwinCategoryId : null,
        threadIdentifier: fire.groupKey,
      ),
      linux: const LinuxNotificationDetails(),
    );
  }

  @override
  Future<void> schedule(PendingFire fire) async {
    final exact = await exactAlarmsAllowed();
    await _plugin.zonedSchedule(
      fire.notifId,
      fire.title,
      fire.body,
      tz.TZDateTime.fromMillisecondsSinceEpoch(tz.local, fire.whenMs),
      _details(fire, exact: exact),
      payload: fire.payloadJson,
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          // Exact denied → degrade honestly (spec: report exact_alarms:false,
          // "timing approximate"), never silently drop the fire.
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> showNow(PendingFire fire) async {
    await _plugin.show(fire.notifId, fire.title, fire.body,
        _details(fire, exact: true),
        payload: fire.payloadJson);
  }

  @override
  Future<void> cancelAllScheduled() => _plugin.cancelAll();

  /// True where this plugin actually delivers (spec: Windows/web are the
  /// timer-only shim, handled by NoopNotifChannel).
  static bool get platformSupported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS ||
          Platform.isLinux);
}

/// Windows/web shim: no OS notifications, no actions. The in-process timer
/// (Task 11) still runs the sweep so state advances while the app is open;
/// getCapabilities reports actions:false, and 'granted' here means "no
/// permission concept on this platform", not a real grant.
class NoopNotifChannel implements NotifChannel {
  @override
  Future<void> init(NotifCallbacks callbacks) async {}
  @override
  Future<String> permissionStatus() async => 'granted';
  @override
  Future<String> requestPermission() async => 'granted';
  @override
  Future<bool> exactAlarmsAllowed() async => false;
  @override
  Future<void> schedule(PendingFire fire) async {}
  @override
  Future<void> showNow(PendingFire fire) async {}
  @override
  Future<void> cancelAllScheduled() async {}
  @override
  bool get supportsActions => false;
}
```

- [ ] **Step 2:** `flutter analyze lib/notif` → resolve any plugin-version signature drift here (and only here) until clean.
- [ ] **Step 3:** Commit `feat(notif): flutter_local_notifications channel adapter + noop shim`.

---

## Task 8: main.dart wiring — service, lifecycle, tap→dialog1, background actions

**Files:** Modify `lib/main.dart`

- [ ] **Step 1:** Imports (near the other notif imports):

```dart
import 'notif/notif_channel.dart';
import 'notif/notification_channel.dart';
import 'notif/notification_service.dart';
```

- [ ] **Step 2:** Top-level (file scope, near `main()`), the channel/service singletons and background handler:

```dart
/// Feature-wide singletons. Channel choice: real plugin adapter where it
/// delivers, noop shim on Windows/web (spec §Platform specifics).
final NotifChannel notifChannel = FlutterNotifChannel.platformSupported
    ? FlutterNotifChannel()
    : NoopNotifChannel();

final NotificationService notifService = NotificationService(
  channel: notifChannel,
  dao: () => CupitorDb.instance.notifDao(),
  window: () => NotifSettings.window,
  perFireCap: () => NotifSettings.perFireCap,
  now: () => tz.TZDateTime.now(tz.local),
  maxArmed: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? 60 : 200,
);

/// Background isolate action handler (app may be dead). Boots just enough
/// of the world — bindings, tz, db — grades, and rearms. No webview here;
/// the webpage learns about the grade from the lists warm-push next launch.
@pragma('vm:entry-point')
Future<void> notifBackgroundActionHandler(
    String actionId, String payloadJson) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    tzdata.initializeTimeZones();
    try {
      final zoneName = await FlutterTimezone.getLocalTimezone()
          .timeout(const Duration(seconds: 2));
      tz.setLocalLocation(tz.getLocation(zoneName));
    } catch (_) {/* UTC */}
    await NotifSettings.init();
    await notifChannel.init(NotifCallbacks(
      onOpened: (_) async {/* taps never route here */},
      onAction: (_, __) async {},
    ));
    await notifService.handleAction(actionId, payloadJson);
  } catch (e) {
    debugPrint('notif background action failed: $e');
  }
}
```

`DartPluginRegistrant` needs `import 'dart:ui' show DartPluginRegistrant;` (or it may already be exported via services — check; add the import that resolves).

- [ ] **Step 3:** In `main()`, after the tz-init block, register the background handler and init the channel:

```dart
  FlutterNotifChannel.backgroundHandler =
      (actionId, payload) => notifBackgroundActionHandler(actionId, payload);
```

- [ ] **Step 4:** In the app State class (the one owning `_notifBridge`):

(a) Init + launch flow — in the same init sequence right after `await NotifSettings.init();`:

```dart
    await notifChannel.init(NotifCallbacks(
      onOpened: _onNotificationOpened,
      onAction: _onNotificationAction,
    ));
    // Terminated-tap: app was launched from a notification.
    if (notifChannel is FlutterNotifChannel) {
      final launch =
          await (notifChannel as FlutterNotifChannel).launchPayload();
      if (launch != null) {
        // Defer until the first frame so dialog1 infrastructure exists.
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => _onNotificationOpened(launch));
      }
    }
    await notifService.sweep(); // launch catch-up (spec: sweep callers)
```

(b) The two handlers, next to `_pushNotifStateToDialog`:

```dart
  /// Notification body tap → record response, open dialog1 at the item's
  /// open_url (fallback: plain dialog1), and tell the webpage
  /// (spec: cupitorNotificationOpened event; external ids only).
  Future<void> _onNotificationOpened(String payloadJson) async {
    await notifService.recordOpened(payloadJson);
    Map<String, dynamic> p;
    try {
      p = jsonDecode(payloadJson) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final openUrl = p['open_url'] as String?;
    if (openUrl != null && openUrl.isNotEmpty) {
      _openDialogWithWebview(openUrl);
    } else {
      _showDialog1();
    }
    _emitNotifEvent('cupitorNotificationOpened', {
      'external_key': p['list_ek'],
      'item_external_id': p['item_eid'],
      'payload': p['echo'],
    });
  }

  /// Foreground action button → grade via the shared service path, then
  /// mirror to the webpage so its state doesn't drift (spec:
  /// cupitorNotifGraded) and refresh the lists push.
  Future<void> _onNotificationAction(
      String actionId, String payloadJson) async {
    final graded = await notifService.handleAction(actionId, payloadJson);
    if (graded == null) return;
    final ((listEk, itemEid), grade) = graded;
    _emitNotifEvent('cupitorNotifGraded', {
      'external_key': listEk,
      'item_external_id': itemEid,
      'grade': grade,
      'source': 'action',
    });
    await _pushNotifStateToDialog();
  }
```

(`_openDialogWithWebview` and `_showDialog1` already exist in main.dart — verify names by searching; use whatever the existing dialog1-open path is called.)

(c) Lifecycle: make the State a `WidgetsBindingObserver` if it isn't already (search "WidgetsBindingObserver" — main.dart may already mix it in; if so just extend `didChangeAppLifecycleState`). On resume:

```dart
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ...existing body if present...
    if (state == AppLifecycleState.resumed) {
      notifService.sweep(); // resume catch-up + rearm (spec: sweep callers)
    }
  }
```

If the class doesn't currently observe, add `WidgetsBinding.instance.addObserver(this);` in `initState` and `removeObserver` in `dispose`, mixing in `WidgetsBindingObserver`.

(d) Wire the bridge to the service — in the `_notifBridge` field initializer, replace the stub capability callbacks and add `onMutated`:

```dart
    capabilities: () async => NotifCapabilities(
      supported: await CupitorDb.instance.isReady(),
      permission: await notifChannel.permissionStatus(),
      exactAlarms: await notifChannel.exactAlarmsAllowed(),
      actions: notifChannel.supportsActions,
      platform: defaultTargetPlatform.name,
    ),
    requestPermission: () async {
      final r = await notifChannel.requestPermission();
      await notifService.rearm(); // permission may have just been granted
      return r;
    },
    onMutated: () => notifService.rearm(),
```

- [ ] **Step 5:** `flutter analyze` → no new issues vs baseline. `flutter test test/notif/ -r expanded` → green. `flutter build apk --debug` → compiles (catches Android plugin wiring problems early; skip if no Android SDK available and say so).
- [ ] **Step 6:** Commit `feat(notif): delivery wired — lifecycle sweep, tap routing, offline grading`.

---

## Task 9: Android manifest + WorkManager safety net

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `lib/main.dart`

- [ ] **Step 1:** In the manifest, add inside `<manifest>` (alongside existing `<uses-permission>` entries):

```xml
    <!-- Notifications feature (spec §Platform specifics / Android) -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

Inside `<application>`, add the plugin's receivers (re-arms after reboot; exact names per the installed flutter_local_notifications README — verify against the package docs in `~/.pub-cache` or pub.dev for the resolved version):

```xml
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
```

- [ ] **Step 2:** WorkManager, in `lib/main.dart`. Top-level:

```dart
/// WorkManager entry point (Android periodic safety net, spec §Delivery:
/// re-arms the window and sweeps missed fires ~every 30 min even if alarms
/// were dropped by an OEM battery killer).
@pragma('vm:entry-point')
void notifWorkmanagerDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      tzdata.initializeTimeZones();
      try {
        final zoneName = await FlutterTimezone.getLocalTimezone()
            .timeout(const Duration(seconds: 2));
        tz.setLocalLocation(tz.getLocation(zoneName));
      } catch (_) {}
      await NotifSettings.init();
      await notifChannel.init(NotifCallbacks(
        onOpened: (_) async {},
        onAction: (_, __) async {},
      ));
      await notifService.sweep();
      return true;
    } catch (e) {
      debugPrint('notif worker failed: $e');
      return false; // let WorkManager retry
    }
  });
}
```

Add `import 'package:workmanager/workmanager.dart';`.

In `main()`, Android-only, after the tz init:

```dart
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await Workmanager().initialize(notifWorkmanagerDispatcher);
    await Workmanager().registerPeriodicTask(
      'cupitor-notif-sweep', 'notifSweep',
      frequency: const Duration(minutes: 30),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }
```

(If the resolved workmanager version names the policy enum differently — e.g. `ExistingPeriodicWorkPolicy.keep` — adapt.)

- [ ] **Step 3:** `flutter analyze` clean vs baseline; `flutter build apk --debug` compiles (or note SDK unavailability).
- [ ] **Step 4:** Commit `feat(notif): Android manifest permissions, boot receiver, workmanager sweep`.

---

## Task 10: iOS/macOS platform pass

**Files:** `ios/Runner/AppDelegate.swift` (verify), `macos/Runner/*` (verify) — likely no code changes needed: flutter_local_notifications handles UNUserNotificationCenter delegation on iOS ≥10 via its own plugin registration, and the Darwin categories were declared in Task 7.

- [ ] **Step 1:** Verify `ios/` and `macos/` build: `flutter build ios --debug --no-codesign` and `flutter build macos --debug` (skip whichever toolchain is unavailable, and say so in the report).
- [ ] **Step 2:** Confirm in code review of Task 7's adapter that: 60-cap comes from `maxArmed` (main.dart sets it for iOS), Darwin categories carry the three actions, `threadIdentifier` groups per list.
- [ ] **Step 3:** If either build surfaces plugin-registration or entitlement issues, fix minimally (macOS local notifications need no special entitlement; if the build says otherwise, follow its error).
- [ ] **Step 4:** Commit only if files changed: `fix(notif): iOS/macOS build adjustments`.

---

## Task 11: Desktop/web best-effort timer

**Files:**
- Create: `lib/notif/notif_timer.dart`
- Modify: `lib/main.dart`
- Test: `test/notif/notif_timer_test.dart`

- [ ] **Step 1:** Test first — `test/notif/notif_timer_test.dart`:

```dart
import 'package:cupitor/notif/notif_timer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ticks call the sweep on the interval and stop cleanly', () {
    fakeAsync((async) {
      var sweeps = 0;
      final timer = NotifSweepTimer(
        sweep: () async => sweeps++,
        interval: const Duration(minutes: 5),
      )..start();
      async.elapse(const Duration(minutes: 16));
      expect(sweeps, 3);
      timer.stop();
      async.elapse(const Duration(minutes: 30));
      expect(sweeps, 3);
    });
  });

  test('start is idempotent', () {
    fakeAsync((async) {
      var sweeps = 0;
      final timer = NotifSweepTimer(
        sweep: () async => sweeps++,
        interval: const Duration(minutes: 5),
      );
      timer.start();
      timer.start();
      async.elapse(const Duration(minutes: 6));
      expect(sweeps, 1);
      timer.stop();
    });
  });
}
```

(`fake_async` is already a transitive dev dep of flutter_test; if the import fails, add `fake_async: ^1.3.1` to dev_dependencies.)

- [ ] **Step 2:** Run → FAIL. Implement `lib/notif/notif_timer.dart`:

```dart
import 'dart:async';

/// Best-effort delivery for platforms with no OS wake (Windows/web/Linux
/// while running — spec §Platform specifics): a periodic in-process sweep.
/// Coarse 5-minute tick instead of a computed next-due deadline: the sweep
/// is cheap and idempotent, and a fixed tick survives clock changes.
class NotifSweepTimer {
  final Future<void> Function() sweep;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  NotifSweepTimer({
    required this.sweep,
    this.interval = const Duration(minutes: 5),
  });

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) async {
      if (_running) return; // a slow sweep must not overlap itself
      _running = true;
      try {
        await sweep();
      } finally {
        _running = false;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
```

- [ ] **Step 3:** Wire in main.dart's State: create `late final NotifSweepTimer _notifTimer = NotifSweepTimer(sweep: notifService.sweep);`, `start()` it in the init sequence right after the launch sweep on non-mobile platforms only:

```dart
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      _notifTimer.start();
    }
```

and `stop()` in `dispose()`. (macOS gets both alarms and the timer — cheap insurance while the app is open; Android/iOS rely on alarms + worker.)

- [ ] **Step 4:** Suite + analyze green. Commit `feat(notif): in-process sweep timer for desktop/web`.

---

## Task 12: Manual verification checklist + wrap-up

**Files:** Create `docs/superpowers/plans/2026-07-27-notifications-2-manual-checklist.md`

- [ ] **Step 1:** Write the checklist file:

```markdown
# Notifications delivery — manual device checklist

Run on a real Android device (primary target) after installing a debug build.
Each item maps to spec §Delivery behavior no unit test can cover.

## Android
- [ ] First run: `getCapabilities` from dialog1 devtools reports permission
      status; `requestPermission` shows the OS prompt (API 33+).
- [ ] Create a list via the webpage (or NotifBridge devtools call) with a
      2-minute Pimsleur-style custom offset; notification fires on time.
- [ ] Notification shows Again/Good/Easy; tapping Good with the APP KILLED
      updates the item (verify next launch: step advanced, event recorded)
      and does not open the app.
- [ ] Tapping the body opens dialog1 at the item's open_url and the webpage
      receives cupitorNotificationOpened.
- [ ] Reboot the device: pending notifications survive (boot receiver).
- [ ] Deny exact alarms (Settings → Alarms & reminders): capabilities report
      exact_alarms:false; fires still arrive (inexact, may drift minutes).
- [ ] Airplane-mode + kill app for > grace: on next launch the missed item
      advanced with an `auto` event and no notification burst beyond the cap.
- [ ] Grouping: 3 items due together → one summary group in the shade.

## iOS (if device available)
- [ ] Permission prompt on requestPermission; actions appear on long-press.
- [ ] ≤ 60 armed: create 70+ near-term items, verify pendingNotificationRequests
      stays ≤ 60 (Xcode console or a debug print in rearm()).

## macOS
- [ ] Notification fires while app open; actions grade.

## Desktop (Linux/Windows) / Web
- [ ] With the app open, a due item posts (Linux) or state advances silently
      (Windows/web) within one 5-minute tick.
```

- [ ] **Step 2:** Update the plan-1 carried notes if anything in Plan 2 changed them. Run the FULL suite one more time + `flutter analyze`. 
- [ ] **Step 3:** Commit `docs(notif): manual delivery checklist`.

---

## Done — definition of complete for Plan 2

- All unit-testable delivery logic green: service rearm/sweep/handleAction/recordOpened, DAO delivery queries, timer (expected new tests: ~25).
- `flutter analyze` clean vs baseline; `flutter build apk --debug` compiles.
- Bridge `getCapabilities` reports real permission/exact-alarm/actions values; `onMutated` re-arms.
- Manual checklist written; device items explicitly NOT claimed as verified — they are handed to the project owner to run.
- Plan 3 (manager UI) builds on: `NotifSettings.setWindow/setPerFireCap` (+ rearm), `NotificationService`, `NotifDao` — all in place.
