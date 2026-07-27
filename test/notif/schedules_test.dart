import 'package:cupitor/notif/schedules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('builtinSchedules', () {
    test('seven built-ins with spec keys', () {
      expect(builtinSchedules.map((b) => b.key), [
        'ebbinghaus', 'pimsleur', 'cepeda2x', 'daily_0900',
        'twice_daily', 'every_4_waking', 'weekdays_0800',
      ]);
    });
    test('all built-in configs validate against their own kind', () {
      for (final b in builtinSchedules) {
        expect(() => validateScheduleConfig(b.kind, b.config), returnsNormally,
            reason: b.key);
      }
    });
    test('ebbinghaus ladder matches spec', () {
      expect(seriesOffsets(builtinSchedules.first.config),
          [0.25, 1, 4, 17, 51, 119, 272, 595, 1360, 3060]);
    });
  });

  group('validateScheduleConfig — series', () {
    test('empty offsets rejected', () {
      expect(() => validateScheduleConfig('series', {'offsets_waking_hours': []}),
          throwsA(isA<ScheduleConfigError>()));
    });
    test('non-positive offset rejected', () {
      expect(
          () => validateScheduleConfig('series', {'offsets_waking_hours': [1, 0]}),
          throwsA(isA<ScheduleConfigError>()));
    });
    test('non-increasing rejected', () {
      expect(
          () => validateScheduleConfig('series', {'offsets_waking_hours': [4, 4]}),
          throwsA(isA<ScheduleConfigError>()));
    });
    test('non-finite offset rejected', () {
      expect(
          () => validateScheduleConfig(
              'series', {'offsets_waking_hours': [1, double.nan]}),
          throwsA(isA<ScheduleConfigError>()));
      expect(
          () => validateScheduleConfig(
              'series', {'offsets_waking_hours': [1, double.infinity]}),
          throwsA(isA<ScheduleConfigError>()));
    });
  });

  group('validateScheduleConfig — recurring', () {
    test('both forms rejected', () {
      expect(
          () => validateScheduleConfig('recurring',
              {'times': ['09:00'], 'every_waking_hours': 4}),
          throwsA(isA<ScheduleConfigError>()));
    });
    test('neither form rejected', () {
      expect(() => validateScheduleConfig('recurring', {}),
          throwsA(isA<ScheduleConfigError>()));
    });
    test('bad time string rejected', () {
      expect(() => validateScheduleConfig('recurring', {'times': ['25:00']}),
          throwsA(isA<ScheduleConfigError>()));
    });
    test('bad day rejected', () {
      expect(
          () => validateScheduleConfig(
              'recurring', {'times': ['09:00'], 'days': [0]}),
          throwsA(isA<ScheduleConfigError>()));
    });
    test('days default to all 7, per_fire defaults to 1', () {
      final c = validateScheduleConfig('recurring', {'times': ['09:00']});
      expect(c['days'], [1, 2, 3, 4, 5, 6, 7]);
      expect(c['per_fire'], 1);
    });
    test('unknown kind rejected', () {
      expect(() => validateScheduleConfig('cron', {}),
          throwsA(isA<ScheduleConfigError>()));
    });
  });

  group('parseRecurring', () {
    test('clock-anchored', () {
      final c = parseRecurring({'times': ['09:00', '20:30'], 'days': [1, 5], 'per_fire': 2});
      expect(c.timesMinutes, [540, 1230]);
      expect(c.days, {1, 5});
      expect(c.perFire, 2);
      expect(c.everyWakingHours, isNull);
    });
    test('interval', () {
      final c = parseRecurring({'every_waking_hours': 4, 'per_fire': 1});
      expect(c.everyWakingHours, 4.0);
      expect(c.timesMinutes, isNull);
    });
  });
}
