import 'package:timezone/timezone.dart' as tz;

import 'waking_clock.dart';

/// Grade values are the ones that cross the bridge and land in
/// notif_items.last_grade / notif_events.grade. SM-2-style numbering with
/// gaps left deliberately (spec: Leitner on the ladder, no ease factor).
const int gradeAgain = 1;
const int gradeGood = 3;
const int gradeEasy = 5;

class SeriesOutcome {
  final int step;
  final bool done;
  final tz.TZDateTime? nextDue; // null iff done
  const SeriesOutcome({required this.step, required this.done, this.nextDue});
}

/// Leitner-on-the-ladder (spec §Scheduling engine): no response → +1,
/// Again → 0, Good → +1, Easy → +2. Advancing past the last index graduates
/// the item ('done'); Again resurrects a graduated item.
SeriesOutcome advanceSeries({
  required int step,
  required bool done,
  required List<double> offsetsWakingHours,
  required tz.TZDateTime now,
  int? grade, // null = auto-advance (fired, no response)
  required WakingWindow window,
}) {
  assert(grade == null || grade == gradeAgain || grade == gradeGood || grade == gradeEasy);
  final last = offsetsWakingHours.length - 1;
  final int next;
  if (grade == gradeAgain) {
    next = 0;
  } else if (done) {
    // Graduated; only Again brings it back.
    return SeriesOutcome(step: step, done: true);
  } else if (grade == gradeEasy) {
    next = step + 2;
  } else {
    next = step + 1; // auto or Good
  }
  if (next > last) return SeriesOutcome(step: last, done: true);
  return SeriesOutcome(
    step: next,
    done: false,
    nextDue: addWakingHours(now, offsetsWakingHours[next], window),
  );
}
