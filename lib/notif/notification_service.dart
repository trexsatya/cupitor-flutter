import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'notif_channel.dart';
import 'notif_dao.dart';
import 'notif_ops.dart';
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

  /// Android group-summary row id, one per list. Disjoint id family from
  /// itemNotifId's 0x1000000 so a summary can never collide with an item.
  static int summaryNotifId(int listId) => 0x2000000 + listId;

  /// Rearm window: 48 absolute hours (spec §Arming).
  static const int windowMs = 48 * 3600 * 1000;

  /// Sweep grace: overdue by at most this many WAKING hours → post now;
  /// older → silent auto-advance (spec §The sweep).
  static const double graceWakingHours = 2;

  /// Items whose notification the user TAPPED before the sweep processed
  /// the fire. The tap dismisses the shade entry, so by sweep time an
  /// alarm-delivered fire looks exactly like a missed one — and got posted
  /// again, a duplicate right after the click. The sweep treats these as
  /// delivered-and-seen: it records the fire (responded) without posting.
  /// Foreground-only state is enough: body taps always run in the UI
  /// isolate, and so does the resume/startup sweep that consumes them.
  final Set<int> _openedItemIds = {};

  /// Every state-mutating entry point runs on this chain. Overlapping
  /// calls are routine — the 5-min timer tick, the resume handler and a
  /// tap callback all coincide when a notification tap wakes the app —
  /// and two interleaved sweeps both read "due, no event yet" before
  /// either wrote, posting and recording the same fire twice. The DAO's
  /// optimistic claims cover the background worker isolate, which this
  /// in-memory chain cannot reach.
  Future<void> _chain = Future<void>.value();
  Future<T> _serialized<T>(Future<T> Function() body) {
    final run = _chain.then((_) => body());
    _chain = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  // ── rearm ────────────────────────────────────────────────────────────

  /// Cancel-everything-then-arm-the-window. Triggers (wired in main.dart /
  /// worker): app resume, boot, any fire, any grade, any bridge mutation,
  /// settings change, worker tick.
  Future<void> rearm() => _serialized(_rearmImpl);

  Future<void> _rearmImpl() async {
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
    // Earliest successfully-armed whenMs per list, keyed by listId (parsed
    // back out of the fire's groupKey — the "cupitor-notif-list-<id>" format
    // is owned by this file, see _itemFire/_recurringFires). Used to arm one
    // group-summary row per list below, exempt from both caps above.
    final earliestArmedByList = <int, int>{};
    for (final f in fires) {
      if (armed >= maxArmed) break;
      if (!seenIds.add(f.notifId)) continue; // same item via two paths
      final bucket = f.whenMs ~/ 60000;
      final inBucket = perMinute[bucket] ?? 0;
      if (inBucket >= cap) continue; // not armed; drains via the sweep once due (silent auto-advance)
      try {
        await channel.schedule(f);
      } catch (e, _) {
        // Platform can't schedule (e.g. Linux zonedSchedule): the sweep+showNow
        // path still delivers while the app runs. Don't let one failure kill
        // the rest of the window.
        continue;
      }
      perMinute[bucket] = inBucket + 1;
      armed++;
      final listId =
          int.parse(f.groupKey.substring('cupitor-notif-list-'.length));
      final earliest = earliestArmedByList[listId];
      if (earliest == null || f.whenMs < earliest) {
        earliestArmedByList[listId] = f.whenMs;
      }
    }

    // One group-summary row per list that actually got something armed —
    // without it, Android won't collapse custom-grouped notifications into
    // a stack (system auto-grouping only kicks in below 4 without a summary,
    // and doesn't understand our custom groupKey at all). Scheduled after
    // the capped loop so summaries never count against perMinute/maxArmed.
    for (final entry in earliestArmedByList.entries) {
      final list = await d.listById(entry.key);
      if (list == null) continue;
      try {
        await channel.schedule(_summaryFire(list, entry.value));
      } catch (_) {
        // Same rationale as the per-fire guard above: a summary that can't
        // be scheduled must not take down the rest of arming.
      }
    }
  }

  /// Android group-summary scaffolding for [list] at [whenMs] (the earliest
  /// armed/posted fire time for that list's group). Darwin/Linux channels
  /// ignore isSummary; Android sets setAsGroupSummary so grouped fires
  /// collapse into a stack instead of the system's default heuristic
  /// (auto-grouping only applies with 4+ ungrouped notifications and ignores
  /// custom groupKeys).
  PendingFire _summaryFire(NotifListRow list, int whenMs) => PendingFire(
        notifId: summaryNotifId(list.id),
        whenMs: whenMs,
        title: list.name,
        body: 'Reviews due',
        payloadJson: jsonEncode({'v': 1, 'summary': true}),
        groupKey: 'cupitor-notif-list-${list.id}',
        withActions: false,
        isSummary: true,
      );

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
        // Per-item deep link wins; the list-level default (v9) fills in.
        'open_url': item.openUrl ?? list?.openUrl,
        'echo': item.payload == null ? null : jsonDecode(item.payload!),
      }),
      groupKey: 'cupitor-notif-list-${item.listId}',
      withActions: withActions && channel.supportsActions,
    );
  }

  /// The items a list-level fire at [whenMs] would show. Two flavours:
  /// rotation for a recurring main schedule (selected with the CURRENT
  /// cursor — it only advances when the sweep processes the fire, so
  /// consecutive unattended fires may repeat items; documented spec
  /// §Delivery trade-off), or the head of the intro queue for a series
  /// list with an intro cadence (v8).
  Future<List<PendingFire>> _recurringFires(
      NotifDao d, NotifListRow list, int whenMs) async {
    final schedule =
        list.scheduleId == null ? null : await d.scheduleById(list.scheduleId!);
    if (schedule == null) return const [];
    if (schedule.kind == 'recurring') {
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
    if (schedule.kind == 'series' && list.introScheduleId != null) {
      final intro = await d.scheduleById(list.introScheduleId!);
      if (intro == null || intro.kind != 'recurring') return const [];
      final cfg =
          parseRecurring(jsonDecode(intro.config) as Map<String, dynamic>);
      final queue = await d.unintroducedItems(list.id);
      return [
        // Series items: grade actions apply from the very first showing.
        for (final item in queue.take(cfg.perFire))
          await _itemFire(d, item, whenMs, withActions: true)
      ];
    }
    return const [];
  }

  // ── sweep ────────────────────────────────────────────────────────────

  /// Catch-up: process everything whose fire time has passed, then rearm.
  /// One function, three callers (spec §The sweep): Android worker, app
  /// launch/resume, desktop/web timer.
  Future<void> sweep() => _serialized(_sweepImpl);

  Future<void> _sweepImpl() async {
    final d = await dao();
    if (d == null) return;
    final t = now();
    final nowMs = t.millisecondsSinceEpoch;
    final w = window();
    final cap = perFireCap();
    var posted = 0;
    // One summary showNow per list that actually posted a fire this sweep
    // (spec: group summary rows so collapsed Android notifications behave).
    final summarized = <int>{};
    // Fires the pre-armed alarms already delivered are still in the shade
    // under their stable ids: record those without re-posting — show()ing
    // the same id again re-alerts, which reads as a duplicate notification.
    final showing = await channel.activeNotificationIds();

    // Overdue series items.
    for (final item in await d.dueItems(nowMs)) {
      final due = item.nextDueAt!;
      final last = await d.lastEventForItem(item.id);
      if (last != null && last.firedAt >= due) continue; // already handled
      final withinGrace = wakingHoursBetween(
              tz.TZDateTime.fromMillisecondsSinceEpoch(t.location, due),
              t, w) <=
          graceWakingHours;
      final opened = _openedItemIds.remove(item.id);
      final delivered = opened || showing.contains(itemNotifId(item.id));
      final fireNow = withinGrace && (delivered || posted < cap);
      // Automatic fading: every processed fire advances one step. Items in
      // recurring lists carry due times only if they have prior series
      // state; advancing them is harmless and keeps one code path.
      final offsets = await _offsetsForList(d, item.listId);
      final Map<String, Object?> advance;
      if (offsets != null) {
        final o = advanceSeries(
            step: item.step, done: item.status == 'done',
            offsetsWakingHours: offsets, now: t, grade: null, window: w);
        advance = {
          'step': o.step,
          'status': o.done ? 'done' : 'active',
          'next_due_at': o.nextDue?.millisecondsSinceEpoch,
          'last_fired_at': nowMs,
        };
      } else {
        advance = {'next_due_at': null, 'last_fired_at': nowMs};
      }
      // Claim before posting: the advance applies only while the item
      // still shows the observed due time. A parallel sweep (the Android
      // worker isolate) that got here first makes the claim fail — it owns
      // this fire, ours must neither post nor record it.
      if (!await d.claimDueItem(item.id, due, advance)) continue;
      if (fireNow && !delivered) {
        posted++;
        await channel.showNow(await _itemFire(d, item, nowMs,
            withActions: await _isSeriesList(d, item.listId)));
        if (summarized.add(item.listId)) {
          final list = await d.listById(item.listId);
          if (list != null) {
            await channel.showNow(_summaryFire(list, nowMs));
          }
        }
      }
      // `item` still holds the pre-advance row: `step` is the rung the fire
      // actually SHOWED, which a late grade must apply from. An opened fire
      // was both shown (source null) and seen (responded by the tap).
      await d.insertEvent(
          itemId: item.id, firedAt: nowMs,
          respondedAt: opened ? nowMs : null,
          source: (fireNow || opened) ? null : 'auto',
          step: item.step);
    }

    // Due list-level fires: rotation (recurring main schedule) or the
    // intro cadence of a series list (v8).
    for (final list in await d.recurringDueLists(nowMs)) {
      final schedule = list.scheduleId == null
          ? null
          : await d.scheduleById(list.scheduleId!);
      if (schedule != null &&
          schedule.kind == 'series' &&
          list.introScheduleId != null) {
        posted = await _sweepIntroFire(
            d, list, schedule, t, nowMs, w, cap, posted, summarized, showing);
        continue;
      }
      if (schedule == null || schedule.kind != 'recurring') {
        await d.updateList(list.id, {'next_fire_at': null});
        continue;
      }
      final cfg = parseRecurring(
          jsonDecode(schedule.config) as Map<String, dynamic>);
      // Claim the fire (moving next_fire_at to the following slot) before
      // processing — same parallel-sweep rationale as the due-items claim.
      if (!await d.claimListFire(list.id, list.nextFireAt!,
          nextRecurringFire(cfg, t, w).millisecondsSinceEpoch)) {
        continue;
      }
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
            final opened = _openedItemIds.remove(item.id);
            if (!opened && !showing.contains(itemNotifId(item.id))) {
              posted++;
              await channel.showNow(
                  await _itemFire(d, item, nowMs, withActions: false));
              if (summarized.add(list.id)) {
                await channel.showNow(_summaryFire(list, nowMs));
              }
            }
            await d.updateItem(item.id, {'last_fired_at': nowMs});
            await d.insertEvent(
                itemId: item.id, firedAt: nowMs,
                respondedAt: opened ? nowMs : null, step: item.step);
          }
          newCursor = sel.newCursor;
          firedAny = sel.items.isNotEmpty;
        }
      }
      // next_fire_at was already moved forward by the claim above.
      await d.updateList(list.id, {
        'cursor': newCursor,
        'last_fired_at': firedAny ? nowMs : list.lastFiredAt,
      });
    }

    // Entries not consumed above had no pending fire to process (the tap
    // hit an already-recorded fire) — drop them rather than leak them.
    _openedItemIds.clear();

    await _rearmImpl();
  }

  /// Process one due intro fire (v8): within the grace window, post up to
  /// per_fire queued items (capacity-bounded) and seed each onto the first
  /// rung of the list's ladder anchored at now; a stale fire is skipped
  /// silently and the cadence just continues (same trade-off as rotation).
  /// The cadence goes dormant (null next_fire_at) once the queue drains.
  /// Returns the updated global posted count.
  Future<int> _sweepIntroFire(
      NotifDao d,
      NotifListRow list,
      NotifScheduleRow schedule,
      tz.TZDateTime t,
      int nowMs,
      WakingWindow w,
      int cap,
      int posted,
      Set<int> summarized,
      Set<int> showing) async {
    final intro = await d.scheduleById(list.introScheduleId!);
    if (intro == null || intro.kind != 'recurring') {
      await d.updateList(list.id, {'next_fire_at': null});
      return posted;
    }
    final cfg =
        parseRecurring(jsonDecode(intro.config) as Map<String, dynamic>);
    final nextFire = nextRecurringFire(cfg, t, w).millisecondsSinceEpoch;
    // Claim the fire before processing — same parallel-sweep rationale as
    // the due-items claim. The queue-drained case below may null it again.
    if (!await d.claimListFire(list.id, list.nextFireAt!, nextFire)) {
      return posted;
    }
    final offsets =
        seriesOffsets(jsonDecode(schedule.config) as Map<String, dynamic>);
    final withinGrace = wakingHoursBetween(
            tz.TZDateTime.fromMillisecondsSinceEpoch(
                t.location, list.nextFireAt!),
            t, w) <=
        graceWakingHours;
    var firedAny = false;
    if (withinGrace) {
      final capacity = cap - posted;
      if (capacity > 0) {
        final take = cfg.perFire < capacity ? cfg.perFire : capacity;
        for (final item in (await d.unintroducedItems(list.id)).take(take)) {
          final opened = _openedItemIds.remove(item.id);
          if (!opened && !showing.contains(itemNotifId(item.id))) {
            posted++;
            await channel.showNow(
                await _itemFire(d, item, nowMs, withActions: true));
            if (summarized.add(list.id)) {
              await channel.showNow(_summaryFire(list, nowMs));
            }
          }
          await seedItemLadder(d, item, offsets, t, w);
          await d.updateItem(item.id, {'last_fired_at': nowMs});
          // Intro fires show the very first rung (seedItemLadder rung 0).
          await d.insertEvent(
              itemId: item.id, firedAt: nowMs,
              respondedAt: opened ? nowMs : null, step: 0);
          firedAny = true;
        }
      }
    }
    final remaining = await d.unintroducedItems(list.id);
    await d.updateList(list.id, {
      'last_fired_at': firedAny ? nowMs : list.lastFiredAt,
      'next_fire_at': remaining.isEmpty ? null : nextFire,
    });
    return posted;
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
          String actionId, String payloadJson) =>
      _serialized(() => _handleActionImpl(actionId, payloadJson));

  Future<((String?, String?), int)?> _handleActionImpl(
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
    final nowMs = t.millisecondsSinceEpoch;
    final latest = await d.lastEventForItem(item.id);
    // Grade from the state the notification actually SHOWED. Once the sweep
    // has processed a fire it auto-advances the item — and may graduate it —
    // so the item row no longer matches what the user responded to: grading
    // from it skipped ladder rungs, and on an auto-graduated item the grade
    // was dropped outright (a lost review). The sweep records the shown
    // rung on the event; firedAt == item.lastFiredAt pins that event to the
    // item's latest fire. A still-due item means the current fire is not
    // yet processed, so the item row itself IS the shown state.
    final stillDue = item.nextDueAt != null && item.nextDueAt! <= nowMs;
    final shown = (!stillDue &&
            latest != null &&
            latest.respondedAt == null &&
            latest.step != null &&
            latest.firedAt == item.lastFiredAt)
        ? (step: latest.step!, done: false) // fires only show active items
        : (step: item.step, done: item.status == 'done');
    if (shown.done && grade != gradeAgain) return null;

    final o = advanceSeries(
        step: shown.step, done: shown.done,
        offsetsWakingHours: offsets, now: t, grade: grade, window: window());
    await d.updateItem(item.id, {
      'step': o.step,
      'status': o.done ? 'done' : 'active',
      'next_due_at': o.nextDue?.millisecondsSinceEpoch,
      'last_grade': grade,
    });
    // The sweep usually recorded this fire already (it runs on every timer
    // tick/resume): grade THAT row instead of inserting a second one the
    // feed would show as a permanently-unread duplicate — and stamp any
    // older orphans while at it (a grade acknowledges the whole item).
    if (latest != null && latest.respondedAt == null) {
      await d.ackUnrespondedEvents(item.id, nowMs);
      await d.setEventGrade(latest.id, grade: grade, source: 'action');
    } else {
      await d.insertEvent(
          itemId: item.id, firedAt: item.lastFiredAt ?? nowMs,
          respondedAt: nowMs, grade: grade, source: 'action',
          step: shown.step);
    }
    final list = await d.listById(item.listId);
    await _rearmImpl();
    return ((list?.externalKey, item.externalId), grade);
  }

  /// Body tap: remember the tap so the next sweep processes this fire as
  /// SEEN (the tap dismissed the shade entry, so the shade check alone
  /// cannot tell it was delivered), and stamp responded_at on every
  /// outstanding event so no fire stays orphaned unread in the feed.
  /// Navigation is the caller's job.
  Future<void> recordOpened(String payloadJson) =>
      _serialized(() => _recordOpenedImpl(payloadJson));

  Future<void> _recordOpenedImpl(String payloadJson) async {
    final d = await dao();
    if (d == null) return;
    try {
      final p = jsonDecode(payloadJson) as Map<String, dynamic>;
      final itemId = p['item_id'];
      if (itemId is! int) return;
      _openedItemIds.add(itemId);
      await d.ackUnrespondedEvents(itemId, now().millisecondsSinceEpoch);
      // If the resume sweep won the race and re-posted this fire before the
      // tap landed, a copy of the just-tapped notification is back in the
      // shade: take it down. dismiss() may also drop the pending alarm for
      // the item's next review (same stable id) — rearm to restore it.
      if (await channel.dismiss(itemNotifId(itemId))) {
        await _rearmImpl();
      }
    } catch (_) {/* never crash on a tap */}
  }
}
