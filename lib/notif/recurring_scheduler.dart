import 'package:timezone/timezone.dart' as tz;

import 'waking_clock.dart';

/// Parsed 'recurring' schedule config. Exactly one of the two forms is set:
/// clock-anchored (timesMinutes + days) or interval (everyWakingHours) —
/// validateScheduleConfig enforces that at write time.
class RecurringConfig {
  final List<int>? timesMinutes; // minutes after midnight
  final Set<int>? days; // ISO-8601, Mon=1 … Sun=7
  final double? everyWakingHours;
  final int perFire;
  const RecurringConfig(
      {this.timesMinutes, this.days, this.everyWakingHours, this.perFire = 1});
}

/// Next fire strictly after [after]. Clock-anchored slots that land inside
/// the sleep window (a user authoring error the editor blocks, but old data
/// may hold one) defer to the next wake start.
tz.TZDateTime nextRecurringFire(
    RecurringConfig cfg, tz.TZDateTime after, WakingWindow w) {
  final every = cfg.everyWakingHours;
  if (every != null) return addWakingHours(after, every, w);
  tz.TZDateTime? best;
  // days is non-empty ⊆ 1..7, so 8 calendar days always contains a hit.
  for (var d = 0; d <= 7; d++) {
    final day = tz.TZDateTime(
        after.location, after.year, after.month, after.day + d);
    if (!cfg.days!.contains(day.weekday)) continue;
    for (final m in cfg.timesMinutes!) {
      final cand = tz.TZDateTime(
          day.location, day.year, day.month, day.day, m ~/ 60, m % 60);
      if (!cand.isAfter(after)) continue;
      if (best == null || cand.isBefore(best)) best = cand;
    }
  }
  final fire = best!;
  return isAwake(fire, w) ? fire : nextWakingInstant(fire, w);
}

class FireSelection<T> {
  final List<T> items;
  final int newCursor;
  const FireSelection(this.items, this.newCursor);
}

/// Round-robin [perFire] active items starting at [cursor] (index into the
/// FULL ordered list, wrapping). Inactive items are skipped without consuming
/// a slot. Generic so the pure engine doesn't depend on the DAO's row types.
FireSelection<T> takeForFire<T>(
    List<T> ordered, int cursor, int perFire, bool Function(T) isActive) {
  if (ordered.isEmpty) return FireSelection(const [], cursor);
  final n = ordered.length;
  final picked = <T>[];
  var idx = cursor % n;
  for (var scanned = 0; scanned < n && picked.length < perFire; scanned++) {
    if (isActive(ordered[idx])) picked.add(ordered[idx]);
    idx = (idx + 1) % n;
  }
  return FireSelection(picked, idx);
}
