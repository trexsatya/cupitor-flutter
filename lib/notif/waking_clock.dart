import 'package:timezone/timezone.dart' as tz;

/// The user's waking window, minutes-after-midnight local time. Waking hours
/// (the unit every series offset is measured in) are ABSOLUTE elapsed time
/// while the wall clock sits inside this window — so a DST-skipped hour is
/// simply unavailable to spend and a repeated one is available twice. See the
/// spec's waking-clock section for the worked examples the tests encode.
class WakingWindow {
  final int startMinutes;
  final int endMinutes;
  const WakingWindow({required this.startMinutes, required this.endMinutes});

  static const WakingWindow defaults =
      WakingWindow(startMinutes: 5 * 60, endMinutes: 22 * 60);

  /// start == end is the degenerate "always awake" window (spec: must not
  /// loop forever if the DB holds one; arithmetic becomes plain addition).
  bool get alwaysAwake => startMinutes == endMinutes;

  static WakingWindow fromStrings(String start, String end) => WakingWindow(
      startMinutes: _hhmm(start), endMinutes: _hhmm(end));

  static int _hhmm(String s) =>
      int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(3, 5));
}

bool isAwake(tz.TZDateTime t, WakingWindow w) {
  if (w.alwaysAwake) return true;
  final m = t.hour * 60 + t.minute;
  if (w.startMinutes < w.endMinutes) {
    return m >= w.startMinutes && m < w.endMinutes;
  }
  // Window crosses midnight (e.g. wake 22:00, sleep 06:00).
  return m >= w.startMinutes || m < w.endMinutes;
}

/// Next instant with wall time [minutes], strictly after [t]. TZDateTime's
/// constructor normalises day overflow and maps DST-nonexistent wall times
/// to a valid instant.
tz.TZDateTime _nextWall(tz.TZDateTime t, int minutes) {
  var day = t.day;
  var d = tz.TZDateTime(
      t.location, t.year, t.month, day, minutes ~/ 60, minutes % 60);
  while (!d.isAfter(t)) {
    day += 1;
    d = tz.TZDateTime(
        t.location, t.year, t.month, day, minutes ~/ 60, minutes % 60);
  }
  return d;
}

tz.TZDateTime nextWakingInstant(tz.TZDateTime t, WakingWindow w) =>
    isAwake(t, w) ? t : _nextWall(t, w.startMinutes);

/// Invariant: the result is never inside the sleep window. Landing exactly on
/// the sleep boundary rolls to the next wake start (strict `<` below).
tz.TZDateTime addWakingHours(tz.TZDateTime from, double hours, WakingWindow w) {
  var remainingMs = (hours * 3600 * 1000).round();
  if (w.alwaysAwake) return from.add(Duration(milliseconds: remainingMs));
  var t = nextWakingInstant(from, w);
  while (true) {
    final segEnd = _nextWall(t, w.endMinutes);
    final availMs = segEnd.difference(t).inMilliseconds;
    if (remainingMs < availMs) {
      return t.add(Duration(milliseconds: remainingMs));
    }
    remainingMs -= availMs;
    t = _nextWall(segEnd, w.startMinutes);
  }
}

double wakingHoursBetween(tz.TZDateTime a, tz.TZDateTime b, WakingWindow w) {
  if (!b.isAfter(a)) return 0;
  if (w.alwaysAwake) return b.difference(a).inMilliseconds / 3600000.0;
  var t = nextWakingInstant(a, w);
  var totalMs = 0;
  while (t.isBefore(b)) {
    final segEnd = _nextWall(t, w.endMinutes);
    final end = segEnd.isBefore(b) ? segEnd : b;
    totalMs += end.difference(t).inMilliseconds;
    if (!segEnd.isBefore(b)) break;
    t = _nextWall(segEnd, w.startMinutes);
  }
  return totalMs / 3600000.0;
}
