import 'recurring_scheduler.dart';

/// Thrown by [validateScheduleConfig]; `code` is machine-readable and flows
/// straight into a bridge ack's `error` field.
class ScheduleConfigError implements Exception {
  final String code;
  ScheduleConfigError(this.code);
  @override
  String toString() => 'ScheduleConfigError($code)';
}

class BuiltinSchedule {
  final String key;
  final String name;
  final String kind; // 'series' | 'recurring'
  final Map<String, Object?> config;
  const BuiltinSchedule(this.key, this.name, this.kind, this.config);
}

/// The seven built-ins from the spec. Offsets are waking hours (17/day at the
/// default window); the research basis for the three series ladders is in the
/// spec's "Research basis" section.
const List<BuiltinSchedule> builtinSchedules = [
  BuiltinSchedule('ebbinghaus', 'Ebbinghaus-anchored', 'series', {
    'offsets_waking_hours': [0.25, 1, 4, 17, 51, 119, 272, 595, 1360, 3060],
  }),
  BuiltinSchedule('pimsleur', 'Pimsleur', 'series', {
    'offsets_waking_hours': [0.03, 0.17, 1, 5, 17, 85, 425, 2040],
  }),
  BuiltinSchedule('cepeda2x', 'Cepeda 2×', 'series', {
    'offsets_waking_hours': [1, 2, 4, 8, 17, 34, 68, 136, 272, 544, 1088],
  }),
  BuiltinSchedule('daily_0900', 'Daily 09:00', 'recurring', {
    'times': ['09:00'], 'days': [1, 2, 3, 4, 5, 6, 7], 'per_fire': 1,
  }),
  BuiltinSchedule('twice_daily', 'Twice daily 09:00 / 20:00', 'recurring', {
    'times': ['09:00', '20:00'], 'days': [1, 2, 3, 4, 5, 6, 7], 'per_fire': 1,
  }),
  BuiltinSchedule('every_4_waking', 'Every 4 waking hours', 'recurring', {
    'every_waking_hours': 4, 'per_fire': 1,
  }),
  BuiltinSchedule('weekdays_0800', 'Weekdays 08:00', 'recurring', {
    'times': ['08:00'], 'days': [1, 2, 3, 4, 5], 'per_fire': 1,
  }),
];

final RegExp _hhmmRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// Validate + normalise a schedule config. Returns the canonical map to
/// persist; throws [ScheduleConfigError] otherwise. Called for every custom
/// schedule write and by the built-in self-test.
Map<String, Object?> validateScheduleConfig(
    String kind, Map<String, Object?> config) {
  if (kind == 'series') {
    final raw = config['offsets_waking_hours'];
    if (raw is! List || raw.isEmpty) throw ScheduleConfigError('bad_offsets');
    final offsets = <double>[];
    for (final e in raw) {
      if (e is! num || !e.isFinite || e <= 0) throw ScheduleConfigError('bad_offsets');
      final v = e.toDouble();
      if (offsets.isNotEmpty && v <= offsets.last) {
        throw ScheduleConfigError('bad_offsets');
      }
      offsets.add(v);
    }
    return {'offsets_waking_hours': offsets};
  }
  if (kind == 'recurring') {
    final hasTimes = config.containsKey('times');
    final hasEvery = config.containsKey('every_waking_hours');
    if (hasTimes == hasEvery) throw ScheduleConfigError('bad_recurring');
    final perFire = config['per_fire'] ?? 1;
    if (perFire is! int || perFire < 1) throw ScheduleConfigError('bad_per_fire');
    if (hasEvery) {
      final e = config['every_waking_hours'];
      if (e is! num || e <= 0) throw ScheduleConfigError('bad_interval');
      return {'every_waking_hours': e.toDouble(), 'per_fire': perFire};
    }
    final times = config['times'];
    if (times is! List || times.isEmpty) throw ScheduleConfigError('bad_times');
    final normTimes = <String>[];
    for (final t in times) {
      if (t is! String || !_hhmmRe.hasMatch(t)) {
        throw ScheduleConfigError('bad_times');
      }
      normTimes.add(t);
    }
    final days = config['days'] ?? const [1, 2, 3, 4, 5, 6, 7];
    if (days is! List || days.isEmpty) throw ScheduleConfigError('bad_days');
    final normDays = <int>{};
    for (final d in days) {
      if (d is! int || d < 1 || d > 7) throw ScheduleConfigError('bad_days');
      normDays.add(d);
    }
    return {
      'times': normTimes,
      'days': normDays.toList()..sort(),
      'per_fire': perFire,
    };
  }
  throw ScheduleConfigError('bad_kind');
}

List<double> seriesOffsets(Map<String, dynamic> config) => [
      for (final e in config['offsets_waking_hours'] as List) (e as num).toDouble()
    ];

RecurringConfig parseRecurring(Map<String, dynamic> config) {
  final every = config['every_waking_hours'];
  final perFire = (config['per_fire'] as int?) ?? 1;
  if (every != null) {
    return RecurringConfig(
        everyWakingHours: (every as num).toDouble(), perFire: perFire);
  }
  return RecurringConfig(
    timesMinutes: [
      for (final t in config['times'] as List) _hhmmToMinutes(t as String)
    ],
    days: {for (final d in config['days'] as List) d as int},
    perFire: perFire,
  );
}

int _hhmmToMinutes(String s) =>
    int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(3, 5));
