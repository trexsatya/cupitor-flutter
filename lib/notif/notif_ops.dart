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

/// Assign [schedule] to [list] (spec: setSchedule semantics). Recurring
/// re-anchors the list fire time and leaves per-item state untouched;
/// series clears the list fire time and initialises only items that carry
/// no series state yet — items with history keep it (lossless round trip).
Future<void> applyScheduleToList(NotifDao d, NotifListRow list,
    NotifScheduleRow schedule, tz.TZDateTime now, WakingWindow w) async {
  if (schedule.kind == 'recurring') {
    await d.updateList(list.id, {
      'schedule_id': schedule.id,
      'next_fire_at': initialNextFireMs(schedule, now, w),
    });
    return;
  }
  final offsets =
      seriesOffsets(jsonDecode(schedule.config) as Map<String, dynamic>);
  await d.updateList(
      list.id, {'schedule_id': schedule.id, 'next_fire_at': null});
  for (final i in await d.itemsForList(list.id)) {
    if (i.status == 'active' && i.nextDueAt == null) {
      await d.updateItem(i.id, {
        'step': 0,
        'next_due_at': addWakingHours(now, offsets[0], w).millisecondsSinceEpoch,
      });
    }
  }
}

/// Pause/resume (spec: setStatus semantics). Resuming a recurring list
/// re-anchors next_fire_at — the stale pre-pause slot may be long past.
Future<void> setListStatus(NotifDao d, NotifListRow list, String status,
    tz.TZDateTime now, WakingWindow w) async {
  final fields = <String, Object?>{'status': status};
  if (status == 'active' && list.scheduleId != null) {
    final schedule = await d.scheduleById(list.scheduleId!);
    if (schedule != null && schedule.kind == 'recurring') {
      fields['next_fire_at'] = initialNextFireMs(schedule, now, w);
    }
  }
  await d.updateList(list.id, fields);
}

/// Reset an item to the start of its ladder (manager UI: reset-to-step-1).
/// A done or suspended item comes back active.
Future<void> resetItemToStart(NotifDao d, NotifItemRow item,
    NotifScheduleRow? schedule, tz.TZDateTime now, WakingWindow w) async {
  await d.updateItem(item.id, {
    'step': 0,
    'status': 'active',
    'next_due_at': initialNextDueMs(schedule, now, w),
    'last_grade': null,
  });
}
