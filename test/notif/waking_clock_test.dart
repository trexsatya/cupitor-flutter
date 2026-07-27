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
  const w = WakingWindow.defaults; // 05:00–22:00
  tz.TZDateTime d(int mo, int day, int h, [int min = 0]) =>
      tz.TZDateTime(ny, 2026, mo, day, h, min);

  group('isAwake', () {
    test('inside window', () => expect(isAwake(d(7, 27, 12), w), isTrue));
    test('sleep window', () => expect(isAwake(d(7, 27, 23), w), isFalse));
    test('start boundary is awake', () => expect(isAwake(d(7, 27, 5), w), isTrue));
    test('end boundary is asleep', () => expect(isAwake(d(7, 27, 22), w), isFalse));
    test('midnight-crossing window', () {
      const night = WakingWindow(startMinutes: 22 * 60, endMinutes: 6 * 60);
      expect(isAwake(d(7, 27, 23), night), isTrue);
      expect(isAwake(d(7, 27, 12), night), isFalse);
    });
    test('degenerate window is always awake', () {
      const always = WakingWindow(startMinutes: 300, endMinutes: 300);
      expect(isAwake(d(7, 27, 3), always), isTrue);
    });
  });

  group('addWakingHours', () {
    test('same day', () =>
        expect(addWakingHours(d(7, 27, 10), 4, w), d(7, 27, 14)));
    test('spans one night', () =>
        expect(addWakingHours(d(7, 27, 20), 4, w), d(7, 28, 7)));
    test('starts inside sleep window', () =>
        expect(addWakingHours(d(7, 27, 23), 1, w), d(7, 28, 6)));
    test('exact boundary rolls to next morning', () =>
        expect(addWakingHours(d(7, 27, 18), 4, w), d(7, 28, 5)));
    test('multi-night walk', () =>
        // 2h to 22:00, then 17h day, then 1h into day after.
        expect(addWakingHours(d(7, 27, 20), 20, w), d(7, 29, 6)));
    test('fractional hours', () =>
        expect(addWakingHours(d(7, 27, 10), 0.25, w), d(7, 27, 10, 15)));
    test('DST spring forward: transition inside sleep costs nothing', () {
      // Sat Mar 7 20:00 + 4wh: 2h → 22:00, sleep (02:00→03:00 skipped),
      // resume 05:00 EDT + 2h → 07:00 EDT. Absolute elapsed 10h.
      final out = addWakingHours(d(3, 7, 20), 4, w);
      expect(out, d(3, 8, 7));
      expect(out.difference(d(3, 7, 20)).inHours, 10);
    });
    test('DST fall back: repeated hour inside sleep', () {
      final out = addWakingHours(d(10, 31, 20), 4, w);
      expect(out, d(11, 1, 7));
      expect(out.difference(d(10, 31, 20)).inHours, 12);
    });
    test('DST fall back inside an always-awake window is absolute time', () {
      const always = WakingWindow(startMinutes: 0, endMinutes: 0);
      final from = tz.TZDateTime(ny, 2026, 11, 1, 0, 30); // EDT
      final out = addWakingHours(from, 2, always);
      expect(out.difference(from).inMinutes, 120);
      expect(out.hour, 1); // 01:30 EST — wall clock repeated
      expect(out.minute, 30);
    });
    test('result is never inside the sleep window', () {
      for (final h in [0.03, 0.25, 1.0, 4.0, 17.0, 51.0, 119.0, 3060.0]) {
        expect(isAwake(addWakingHours(d(7, 27, 21, 50), h, w), w), isTrue,
            reason: 'offset $h');
      }
    });
  });

  group('wakingHoursBetween', () {
    test('inverse of addWakingHours across DST', () =>
        expect(wakingHoursBetween(d(3, 7, 20), d(3, 8, 7), w), closeTo(4, 1e-9)));
    test('b before a is zero', () =>
        expect(wakingHoursBetween(d(7, 27, 12), d(7, 27, 10), w), 0));
  });

  group('nextWakingInstant / parse', () {
    test('asleep → next wake start', () =>
        expect(nextWakingInstant(d(7, 27, 23), w), d(7, 28, 5)));
    test('awake → identity', () =>
        expect(nextWakingInstant(d(7, 27, 12), w), d(7, 27, 12)));
    test('fromStrings', () {
      final p = WakingWindow.fromStrings('05:00', '22:00');
      expect(p.startMinutes, 300);
      expect(p.endMinutes, 1320);
    });
  });
}
