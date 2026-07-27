import 'package:cupitor/notif/recurring_scheduler.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late tz.Location ny;
  setUpAll(() {
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });
  const w = WakingWindow.defaults;
  // Mon Jul 27 2026 is a Monday.
  tz.TZDateTime d(int day, int h, [int min = 0]) =>
      tz.TZDateTime(ny, 2026, 7, day, h, min);

  group('nextRecurringFire — clock-anchored', () {
    const daily9 = RecurringConfig(
        timesMinutes: [9 * 60], days: {1, 2, 3, 4, 5, 6, 7});
    test('before the slot → today', () =>
        expect(nextRecurringFire(daily9, d(27, 8), w), d(27, 9)));
    test('after the slot → tomorrow', () =>
        expect(nextRecurringFire(daily9, d(27, 10), w), d(28, 9)));
    test('exactly on the slot → tomorrow (strictly after)', () =>
        expect(nextRecurringFire(daily9, d(27, 9), w), d(28, 9)));
    test('weekday filter skips the weekend', () {
      const weekdays8 = RecurringConfig(
          timesMinutes: [8 * 60], days: {1, 2, 3, 4, 5});
      // Fri Jul 31 09:00 → Mon Aug 3 08:00.
      expect(nextRecurringFire(weekdays8, d(31, 9), w),
          tz.TZDateTime(ny, 2026, 8, 3, 8));
    });
    test('two times picks the earlier upcoming one', () {
      const twice = RecurringConfig(
          timesMinutes: [9 * 60, 20 * 60], days: {1, 2, 3, 4, 5, 6, 7});
      expect(nextRecurringFire(twice, d(27, 12), w), d(27, 20));
    });
    test('slot inside sleep window defers to wake start', () {
      const late23 = RecurringConfig(
          timesMinutes: [23 * 60], days: {1, 2, 3, 4, 5, 6, 7});
      expect(nextRecurringFire(late23, d(27, 12), w), d(28, 5));
    });
  });

  group('nextRecurringFire — interval', () {
    const every4 = RecurringConfig(everyWakingHours: 4);
    test('same day', () =>
        expect(nextRecurringFire(every4, d(27, 10), w), d(27, 14)));
    test('spans the night', () =>
        expect(nextRecurringFire(every4, d(27, 20), w), d(28, 7)));
  });

  group('takeForFire', () {
    bool active(String s) => s != 'x';
    test('round-robin from cursor', () {
      final sel = takeForFire(['a', 'b', 'c'], 1, 1, active);
      expect(sel.items, ['b']);
      expect(sel.newCursor, 2);
    });
    test('wraps around', () {
      final sel = takeForFire(['a', 'b', 'c'], 2, 2, active);
      expect(sel.items, ['c', 'a']);
      expect(sel.newCursor, 1);
    });
    test('skips inactive without consuming a slot', () {
      final sel = takeForFire(['a', 'x', 'b'], 1, 1, active);
      expect(sel.items, ['b']);
      expect(sel.newCursor, 0);
    });
    test('all inactive → empty', () {
      final sel = takeForFire(['x', 'x'], 0, 1, active);
      expect(sel.items, isEmpty);
    });
    test('empty list → empty, cursor unchanged', () {
      final sel = takeForFire(<String>[], 3, 1, active);
      expect(sel.items, isEmpty);
      expect(sel.newCursor, 3);
    });
  });
}
