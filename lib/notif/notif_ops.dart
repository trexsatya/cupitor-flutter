import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'notif_dao.dart';
import 'recurring_scheduler.dart';
import 'schedules.dart';
import 'waking_clock.dart';

/// List/item mutation logic shared by the bridge and the in-app UI screens.
/// Extracted from NotifBridge so the two surfaces cannot drift; the bridge
/// tests pin the behaviour.

/// Series offsets when [schedule] is a series, else null. The null form
/// doubles as "items get no per-item due time" (recurring lists).
List<double>? offsetsIfSeries(NotifScheduleRow? schedule) {
  if (schedule == null || schedule.kind != 'series') return null;
  return seriesOffsets(jsonDecode(schedule.config) as Map<String, dynamic>);
}

/// next_due_at for a brand-new active item under [schedule] — the first
/// ladder rung for a series, null for recurring or no schedule.
int? initialNextDueMs(
    NotifScheduleRow? schedule, tz.TZDateTime now, WakingWindow w) {
  final offsets = offsetsIfSeries(schedule);
  if (offsets == null) return null;
  return addWakingHours(now, offsets[0], w).millisecondsSinceEpoch;
}

/// next_fire_at for a list adopting [schedule] — the next recurring slot,
/// or null for a series schedule (series fire per-item, not per-list).
int? initialNextFireMs(
    NotifScheduleRow schedule, tz.TZDateTime now, WakingWindow w) {
  if (schedule.kind != 'recurring') return null;
  final config = jsonDecode(schedule.config) as Map<String, dynamic>;
  return nextRecurringFire(parseRecurring(config), now, w)
      .millisecondsSinceEpoch;
}

/// Assign [schedule] (and optionally a recurring [intro] cadence) to [list]
/// (spec: setSchedule semantics).
///
/// - recurring main: re-anchors the list fire time, leaves per-item state
///   untouched, clears any intro ([intro] must be null — callers validate).
/// - series without intro: clears the list fire time and initialises only
///   items that carry no series state yet — items with history keep it
///   (lossless round trip).
/// - series with intro: stateless items stay UN-seeded (they are the intro
///   queue); the list fire time runs the intro cadence while that queue is
///   non-empty, else goes dormant.
Future<void> applyScheduleToList(NotifDao d, NotifListRow list,
    NotifScheduleRow schedule, tz.TZDateTime now, WakingWindow w,
    {NotifScheduleRow? intro}) async {
  assert(intro == null ||
      (schedule.kind == 'series' && intro.kind == 'recurring'));
  if (schedule.kind == 'recurring') {
    await d.updateList(list.id, {
      'schedule_id': schedule.id,
      'intro_schedule_id': null,
      'next_fire_at': initialNextFireMs(schedule, now, w),
    });
    return;
  }
  if (intro != null) {
    final queued = await d.unintroducedItems(list.id);
    await d.updateList(list.id, {
      'schedule_id': schedule.id,
      'intro_schedule_id': intro.id,
      'next_fire_at':
          queued.isEmpty ? null : initialNextFireMs(intro, now, w),
    });
    return;
  }
  final offsets =
      seriesOffsets(jsonDecode(schedule.config) as Map<String, dynamic>);
  await d.updateList(list.id, {
    'schedule_id': schedule.id,
    'intro_schedule_id': null,
    'next_fire_at': null,
  });
  for (final i in await d.itemsForList(list.id)) {
    if (i.status == 'active' && i.nextDueAt == null) {
      await d.updateItem(i.id, {
        'step': 0,
        'next_due_at': addWakingHours(now, offsets[0], w).millisecondsSinceEpoch,
      });
    }
  }
}

/// Re-arm a dormant intro cadence: when [list] has an intro schedule, no
/// pending fire, and a non-empty intro queue, anchor next_fire_at to the
/// next slot. Called after items are added (bridge syncItems, UI add-item).
Future<void> ensureIntroArmed(
    NotifDao d, NotifListRow list, tz.TZDateTime now, WakingWindow w) async {
  if (list.introScheduleId == null || list.nextFireAt != null) return;
  final intro = await d.scheduleById(list.introScheduleId!);
  if (intro == null || intro.kind != 'recurring') return;
  if ((await d.unintroducedItems(list.id)).isEmpty) return;
  await d.updateList(list.id, {'next_fire_at': initialNextFireMs(intro, now, w)});
}

/// Pause/resume (spec: setStatus semantics). Resuming re-anchors the list
/// fire time — the stale pre-pause slot may be long past. For a recurring
/// main schedule that's the rotation slot; for an intro list it's the next
/// intro slot (only while the intro queue is non-empty).
Future<void> setListStatus(NotifDao d, NotifListRow list, String status,
    tz.TZDateTime now, WakingWindow w) async {
  final fields = <String, Object?>{'status': status};
  if (status == 'active') {
    if (list.scheduleId != null) {
      final schedule = await d.scheduleById(list.scheduleId!);
      if (schedule != null && schedule.kind == 'recurring') {
        fields['next_fire_at'] = initialNextFireMs(schedule, now, w);
      }
    }
    if (list.introScheduleId != null) {
      final intro = await d.scheduleById(list.introScheduleId!);
      if (intro != null && intro.kind == 'recurring') {
        fields['next_fire_at'] =
            (await d.unintroducedItems(list.id)).isEmpty
                ? null
                : initialNextFireMs(intro, now, w);
      }
    }
  }
  await d.updateList(list.id, fields);
}

/// Seed [item] onto the first rung of its ladder at [anchor] — the moment
/// the intro cadence fires it. Next repetition = anchor + offsets[0].
Future<void> seedItemLadder(NotifDao d, NotifItemRow item,
    List<double> offsets, tz.TZDateTime anchor, WakingWindow w) async {
  await d.updateItem(item.id, {
    'step': 0,
    'next_due_at':
        addWakingHours(anchor, offsets[0], w).millisecondsSinceEpoch,
  });
}

/// Reset an item to the start of its ladder (manager UI: reset-to-step-1).
/// A done or suspended item comes back active. last_fired_at is cleared so
/// a pre-reset fire event can never be mistaken for the fresh ladder's
/// latest fire (handleAction pins events to fires via that timestamp).
Future<void> resetItemToStart(NotifDao d, NotifItemRow item,
    NotifScheduleRow? schedule, tz.TZDateTime now, WakingWindow w) async {
  await d.updateItem(item.id, {
    'step': 0,
    'status': 'active',
    'next_due_at': initialNextDueMs(schedule, now, w),
    'last_fired_at': null,
    'last_grade': null,
  });
}
