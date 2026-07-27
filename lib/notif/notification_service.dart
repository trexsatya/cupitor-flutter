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
  /// grade must be able to cancel exactly its own notification. The offset
  /// keeps this range disjoint from any future id families (int32-safe).
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
    final seenIds = <int>{};
    for (final f in fires) {
      if (armed >= maxArmed) break;
      if (!seenIds.add(f.notifId)) continue; // same item via two paths
      final bucket = f.whenMs ~/ 60000;
      final inBucket = perMinute[bucket] ?? 0;
      if (inBucket >= cap) continue; // not armed; drains via the sweep once due (silent auto-advance)
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
      var firedAny = false;
      if (withinGrace) {
        final capacity = cap - posted;
        if (capacity > 0) {
          final items = await d.itemsForList(list.id);
          final take = cfg.perFire < capacity ? cfg.perFire : capacity;
          final sel = takeForFire<NotifItemRow>(
              items, list.cursor, take, (i) => i.status == 'active');
          for (final item in sel.items) {
            posted++;
            await channel.showNow(
                await _itemFire(d, item, nowMs, withActions: false));
            await d.updateItem(item.id, {'last_fired_at': nowMs});
            await d.insertEvent(itemId: item.id, firedAt: nowMs);
          }
          newCursor = sel.newCursor;
          firedAny = sel.items.isNotEmpty;
        }
      }
      await d.updateList(list.id, {
        'cursor': newCursor,
        'last_fired_at': firedAny ? nowMs : list.lastFiredAt,
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
    if (item.status == 'done' && grade != gradeAgain) return null;
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
        await d.markEventResponded(last.id, now().millisecondsSinceEpoch);
      }
    } catch (_) {/* never crash on a tap */}
  }
}
