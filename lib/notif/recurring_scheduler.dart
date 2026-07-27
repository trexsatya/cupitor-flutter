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
