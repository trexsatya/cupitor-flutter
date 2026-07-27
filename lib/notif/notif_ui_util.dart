import 'schedules.dart';
import 'waking_clock.dart';

/// Small pure helpers for the notification UI screens. Kept out of the
/// widgets so they unit-test without a widget harness.

String minutesToHhmm(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// Human string for an epoch-ms due/fire time relative to [nowMs].
String formatDue(int? ms, int nowMs) {
  if (ms == null) return '—';
  final delta = ms - nowMs;
  if (delta <= 0) return 'overdue';
  final mins = delta ~/ 60000;
  if (mins < 1) return 'in <1m';
  if (mins < 60) return 'in ${mins}m';
  final hours = mins ~/ 60;
  if (hours < 48) return 'in ${hours}h';
  return 'in ${hours ~/ 24}d';
}

/// True when the wall-clock time [minutes] falls inside the sleep window —
/// the editor blocks authoring such times (spec §In-app UI validation).
bool insideSleepWindow(int minutes, WakingWindow w) {
  if (w.alwaysAwake) return false;
  if (w.startMinutes < w.endMinutes) {
    return minutes < w.startMinutes || minutes >= w.endMinutes;
  }
  // Waking window crosses midnight; sleep is the complement.
  return minutes < w.startMinutes && minutes >= w.endMinutes;
}

/// Comma/whitespace-separated numbers → offsets list, or null on any
/// unparsable token. Positivity and strict ordering are
/// [validateScheduleConfig]'s job — this only parses.
List<double>? parseOffsetsText(String text) {
  final parts =
      text.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final out = <double>[];
  for (final p in parts) {
    final v = double.tryParse(p);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

/// Editor-facing message for each ScheduleConfigError code (carried note
/// from Plan 1: codes surface in the UI mapped, never raw).
String scheduleErrorMessage(ScheduleConfigError e) => switch (e.code) {
      'bad_offsets' =>
        'Offsets must be positive, strictly increasing numbers.',
      'bad_recurring' => 'Choose either fixed times or an interval, not both.',
      'bad_per_fire' => 'Items per fire must be a whole number of at least 1.',
      'bad_interval' =>
        'The interval must be a positive number of waking hours.',
      'bad_times' => 'Times must be valid HH:mm values.',
      'bad_days' => 'Pick at least one weekday.',
      'bad_kind' => 'Unknown schedule kind.',
      _ => 'Invalid schedule configuration.',
    };
