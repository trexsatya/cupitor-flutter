import 'package:cupitor/notif/series_scheduler.dart';
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
  const offsets = [0.25, 1.0, 4.0, 17.0]; // short ladder, last index 3
  late tz.TZDateTime now;
  setUp(() => now = tz.TZDateTime(ny, 2026, 7, 27, 10));

  SeriesOutcome run({int step = 1, bool done = false, int? grade}) =>
      advanceSeries(
          step: step, done: done, offsetsWakingHours: offsets,
          now: now, grade: grade, window: w);

  test('auto (no grade) advances one step', () {
    final o = run(step: 1);
    expect(o.step, 2);
    expect(o.done, isFalse);
    expect(o.nextDue, addWakingHours(now, 4.0, w));
  });
  test('Good advances one step', () => expect(run(step: 1, grade: gradeGood).step, 2));
  test('Easy advances two steps', () {
    final o = run(step: 0, grade: gradeEasy);
    expect(o.step, 2);
    expect(o.nextDue, addWakingHours(now, 4.0, w));
  });
  test('Again resets to step 0', () {
    final o = run(step: 3, grade: gradeAgain);
    expect(o.step, 0);
    expect(o.nextDue, addWakingHours(now, 0.25, w));
  });
  test('auto past last index graduates', () {
    final o = run(step: 3);
    expect(o.done, isTrue);
    expect(o.step, 3); // stays at last index for display
    expect(o.nextDue, isNull);
  });
  test('Easy jumping past last index graduates', () =>
      expect(run(step: 2, grade: gradeEasy).done, isTrue));
  test('Easy landing exactly on last index stays active', () {
    final o = run(step: 1, grade: gradeEasy);
    expect(o.done, isFalse);
    expect(o.step, 3);
  });
  test('Again on a done item resurrects it', () {
    final o = run(step: 3, done: true, grade: gradeAgain);
    expect(o.done, isFalse);
    expect(o.step, 0);
  });
  test('non-Again grade on a done item is a no-op', () {
    final o = run(step: 3, done: true, grade: gradeGood);
    expect(o.done, isTrue);
    expect(o.nextDue, isNull);
  });
}
