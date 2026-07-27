# Notifications Plan 1/3: Engine + Storage + Bridge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Schema v7, the pure scheduling engines (waking clock, series/Leitner, recurring), the `NotifDao`, and the `NotifBridge` JS channel — fully tested. After this plan the webpage can create/sync/grade notification lists and read schedules; nothing fires yet (delivery is Plan 2, in-app UI is Plan 3).

**Architecture:** Everything per `docs/superpowers/specs/2026-07-27-notifications-design.md`. New code in `lib/notif/`. Engines are pure functions over `tz.TZDateTime` (deterministic DST tests). `NotifDao` takes a `Database` handle so tests run on `sqflite_common_ffi` in memory. The bridge is a plain class with injected dependencies — tested by feeding it raw JSON strings, no webview.

**Tech Stack:** Flutter/Dart 3.8, sqflite, `timezone` + `flutter_timezone`, `sqflite_common_ffi` (dev). Mirrors the existing `PlaylistBridge` pattern in `main.dart`.

**Conventions for the executor:**
- Repo root for all commands: `Cupitor/`.
- Run tests with `flutter test <path> -r expanded`.
- Append the standard co-author trailer to every commit message.
- The spec is the contract; if plan and spec disagree, stop and say so — don't pick silently.

---

## Task 1: Dependencies + timezone init

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/main.dart` (top of `main()`)

- [ ] **Step 1: Add dependencies**

In `pubspec.yaml` under `dependencies:`, after the `audioplayers` entry, add:

```yaml
  # Notifications feature (spec: docs/superpowers/specs/2026-07-27-notifications-design.md).
  # timezone: waking-hour arithmetic must be DST-correct and testable against a
  # pinned zone — bare DateTime resolves against the host machine.
  # flutter_timezone: device IANA zone name to seed tz.local.
  timezone: ^0.9.4
  flutter_timezone: ^2.1.0
```

Under `dev_dependencies:`, after `flutter_test:`, add:

```yaml
  # In-memory SQLite so NotifDao and the v6→v7 migration are unit-testable
  # without a device (CupitorDb itself needs path_provider).
  sqflite_common_ffi: ^2.3.3
```

- [ ] **Step 2: Fetch**

Run: `flutter pub get`
Expected: resolves without errors. If `flutter_timezone ^2.1.0` fails to resolve, use the latest 2.x. (4.x changed `getLocalTimezone()` to return `TimezoneInfo`; if forced onto it, use `.identifier`.)

- [ ] **Step 3: Initialize tz.local at startup**

In `lib/main.dart`, add imports next to the existing ones:

```dart
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
```

At the top of `main()`, before `runApp` (after `WidgetsFlutterBinding.ensureInitialized()` if present, else add it):

```dart
  // Notifications: waking-hour math and (Plan 2) zonedSchedule both need the
  // device zone. Fallback to UTC keeps the feature alive with shifted windows
  // rather than crashing.
  tzdata.initializeTimeZones();
  try {
    final zoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zoneName));
  } catch (_) {/* tz.local stays UTC */}
```

If `main()` is not `async`, make it `async`.

- [ ] **Step 4: Verify**

Run: `flutter analyze lib/main.dart`
Expected: no new errors (pre-existing infos/warnings are fine).

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/main.dart
git commit -m "feat(notif): add timezone/sqflite_ffi deps, seed tz.local at startup"
```

---

## Task 2: Extract `createSchema` / `runMigrations` from db.dart closures

The v6→v7 migration test (Task 7) needs to call schema code directly; today it's trapped inside `openDatabase` closures reachable only via path_provider.

**Files:**
- Modify: `lib/db.dart:70-263`
- Create: `test/notif/schema_baseline_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/notif/schema_baseline_test.dart`:

```dart
import 'package:cupitor/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('createSchema builds the current schema on a blank database', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await CupitorDb.createSchema(db);
    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toSet();
    expect(
        tables,
        containsAll([
          'profiles', 'tags', 'pages', 'sentences', 'sentence_tags',
          'sentence_media', 'playlists', 'playlist_items',
        ]));
    final profiles = await db.query('profiles');
    expect(profiles, hasLength(1)); // seeded Default profile
    await db.close();
  });
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `flutter test test/notif/schema_baseline_test.dart -r expanded`
Expected: FAIL — `createSchema` isn't defined.

- [ ] **Step 3: Extract the closures**

In `lib/db.dart`, the `_open()` method currently passes inline closures (`onCreate:` at line 70, `onUpgrade:` at line 156). Change the `openDatabase` call to:

```dart
        onCreate: (db, v) => createSchema(db),
        onUpgrade: (db, oldV, newV) => runMigrations(db, oldV, newV),
```

Then add two static methods to `CupitorDb`, directly below `_open()`:

```dart
  /// Full current-version schema. Public + static so tests can build a real
  /// database on sqflite_common_ffi without touching path_provider.
  static Future<void> createSchema(Database db) async {
    // <body: move lines 71–154 (the old onCreate closure body) here, unchanged>
  }

  /// All version-stepped migrations. Public + static for the same reason —
  /// the v6→v7 test drives this directly against an in-memory v6 fixture.
  static Future<void> runMigrations(Database db, int oldV, int newV) async {
    // <body: move lines 157–262 (the old onUpgrade closure body) here, unchanged>
  }
```

Move the two closure bodies **verbatim** — this is a cut-and-paste of existing code (`lib/db.dart:71-154` and `lib/db.dart:157-262`), no edits inside them.

- [ ] **Step 4: Run test + analyze, verify pass**

Run: `flutter test test/notif/schema_baseline_test.dart -r expanded && flutter analyze lib/db.dart`
Expected: PASS, no new analyzer errors.

- [ ] **Step 5: Commit**

```bash
git add lib/db.dart test/notif/schema_baseline_test.dart
git commit -m "refactor(db): extract createSchema/runMigrations statics for testability"
```

---

## Task 3: `waking_clock.dart`

**Files:**
- Create: `lib/notif/waking_clock.dart`
- Create: `test/notif/waking_clock_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/notif/waking_clock_test.dart`. US DST 2026: spring-forward **Sun Mar 8**, fall-back **Sun Nov 1**.

```dart
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
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/waking_clock_test.dart -r expanded`
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Implement**

Create `lib/notif/waking_clock.dart`:

```dart
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
```

- [ ] **Step 4: Run, verify pass**

Run: `flutter test test/notif/waking_clock_test.dart -r expanded`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/notif/waking_clock.dart test/notif/waking_clock_test.dart
git commit -m "feat(notif): waking-hour clock with DST-correct arithmetic"
```

---

## Task 4: `schedules.dart` — built-ins + config validation

**Files:**
- Create: `lib/notif/schedules.dart`
- Create: `lib/notif/recurring_scheduler.dart` (only the `RecurringConfig` class for now — the functions come in Task 6)
- Create: `test/notif/schedules_test.dart`

- [ ] **Step 1: Create `RecurringConfig`**

Create `lib/notif/recurring_scheduler.dart`:

```dart
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
```

- [ ] **Step 2: Write the failing tests**

Create `test/notif/schedules_test.dart`:

```dart
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
```

- [ ] **Step 3: Run, verify fail**

Run: `flutter test test/notif/schedules_test.dart -r expanded`
Expected: FAIL — `schedules.dart` doesn't exist.

- [ ] **Step 4: Implement**

Create `lib/notif/schedules.dart`:

```dart
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
      if (e is! num || e <= 0) throw ScheduleConfigError('bad_offsets');
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
```

- [ ] **Step 5: Run, verify pass**

Run: `flutter test test/notif/schedules_test.dart -r expanded`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/notif/schedules.dart lib/notif/recurring_scheduler.dart test/notif/schedules_test.dart
git commit -m "feat(notif): built-in schedules + config validation"
```

---

## Task 5: `series_scheduler.dart`

**Files:**
- Create: `lib/notif/series_scheduler.dart`
- Create: `test/notif/series_scheduler_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/notif/series_scheduler_test.dart`:

```dart
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
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/series_scheduler_test.dart -r expanded`
Expected: FAIL.

- [ ] **Step 3: Implement**

Create `lib/notif/series_scheduler.dart`:

```dart
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
```

- [ ] **Step 4: Run, verify pass**

Run: `flutter test test/notif/series_scheduler_test.dart -r expanded`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/notif/series_scheduler.dart test/notif/series_scheduler_test.dart
git commit -m "feat(notif): Leitner series scheduler"
```

---

## Task 6: `recurring_scheduler.dart` — fire computation + rotation

**Files:**
- Modify: `lib/notif/recurring_scheduler.dart` (add functions below `RecurringConfig`)
- Create: `test/notif/recurring_scheduler_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/notif/recurring_scheduler_test.dart`:

```dart
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
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/recurring_scheduler_test.dart -r expanded`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement**

Append to `lib/notif/recurring_scheduler.dart` (below `RecurringConfig`), and add the imports at the top of the file:

```dart
import 'package:timezone/timezone.dart' as tz;

import 'waking_clock.dart';
```

```dart
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
```

- [ ] **Step 4: Run, verify pass**

Run: `flutter test test/notif/recurring_scheduler_test.dart test/notif/schedules_test.dart -r expanded`
Expected: all PASS (schedules_test re-run because the file gained imports).

- [ ] **Step 5: Commit**

```bash
git add lib/notif/recurring_scheduler.dart test/notif/recurring_scheduler_test.dart
git commit -m "feat(notif): recurring scheduler + round-robin rotation"
```

---

## Task 7: Schema v7 + built-in seeds + migration test

**Files:**
- Modify: `lib/db.dart` (`_schemaVersion`, `createSchema`, `runMigrations`, new statics)
- Create: `test/notif/migration_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/notif/migration_test.dart`. The v6 fixture is a **frozen partial copy** of the v6 DDL — deliberately only the tables the assertions touch (`profiles`, `playlists`, `playlist_items`); the v7 block must not touch any pre-existing table, so the untouched ones add nothing to the test:

```dart
import 'package:cupitor/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _createV6Fixture(Database db) async {
  await db.execute('''
    CREATE TABLE profiles (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
      created_at INTEGER NOT NULL
    )''');
  await db.insert('profiles', {'id': 1, 'name': 'Default', 'created_at': 1});
  await db.execute('''
    CREATE TABLE playlists (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      name       TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )''');
  await db.execute('''
    CREATE TABLE playlist_items (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      playlist_id   INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
      sentence_text TEXT NOT NULL,
      book_key      TEXT,
      book_title    TEXT,
      chapter_idx   INTEGER,
      chapter_title TEXT,
      position      INTEGER NOT NULL,
      created_at    INTEGER NOT NULL
    )''');
  await db.insert('playlists', {'id': 1, 'name': 'French', 'created_at': 1});
  await db.insert('playlist_items', {
    'playlist_id': 1, 'sentence_text': 'le dénouement',
    'position': 0, 'created_at': 1,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v6→v7 creates notif tables, seeds built-ins, preserves data', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await _createV6Fixture(db);
    await CupitorDb.runMigrations(db, 6, 7);

    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toSet();
    expect(tables, containsAll(
        ['notif_schedules', 'notif_lists', 'notif_items', 'notif_events']));

    final seeds = await db.query('notif_schedules', orderBy: 'id ASC');
    expect(seeds, hasLength(7));
    expect(seeds.first['builtin_key'], 'ebbinghaus');

    // Pre-existing data untouched.
    expect(await db.query('playlist_items'), hasLength(1));
    await db.close();
  });

  test('seeding is idempotent', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await _createV6Fixture(db);
    await CupitorDb.runMigrations(db, 6, 7);
    await CupitorDb.seedBuiltinSchedules(db); // e.g. a repair pass
    expect(await db.query('notif_schedules'), hasLength(7));
    await db.close();
  });

  test('fresh createSchema also has notif tables and seeds', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await CupitorDb.createSchema(db);
    expect(await db.query('notif_schedules'), hasLength(7));
    await db.close();
  });
}
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/migration_test.dart -r expanded`
Expected: FAIL — v7 block and `seedBuiltinSchedules` don't exist.

- [ ] **Step 3: Implement in `lib/db.dart`**

Add the import at the top:

```dart
import 'notif/schedules.dart' show builtinSchedules;
```

Update the version constant and its comment block (currently `static const int _schemaVersion = 6;` at `lib/db.dart:37`):

```dart
  // v6 → v7: notification feature (spec:
  // docs/superpowers/specs/2026-07-27-notifications-design.md). Four tables:
  // notif_schedules (built-in + custom), notif_lists, notif_items (snapshots
  // with per-item Leitner state), notif_events (fire/response history for
  // dedupe, the catch-up sweep, and the manager's history view). Seeds the
  // seven built-in schedules.
  static const int _schemaVersion = 7;
```

Add two static methods to `CupitorDb` (below `runMigrations`):

```dart
  /// v7 notification tables. Shared by createSchema (fresh install) and the
  /// oldV<7 migration step. Spec: data-model section.
  static Future<void> createNotifTables(Database db) async {
    await db.execute('''
      CREATE TABLE notif_schedules (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        kind        TEXT NOT NULL,
        builtin_key TEXT UNIQUE,
        config      TEXT NOT NULL,
        created_at  INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE notif_lists (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        profile_id    INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
        name          TEXT NOT NULL,
        source        TEXT NOT NULL,
        external_key  TEXT,
        schedule_id   INTEGER REFERENCES notif_schedules(id),
        status        TEXT NOT NULL,
        cursor        INTEGER NOT NULL DEFAULT 0,
        next_fire_at  INTEGER,
        last_fired_at INTEGER,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        UNIQUE(profile_id, external_key)
      )''');
    await db.execute(
        'CREATE INDEX idx_notif_lists_profile ON notif_lists(profile_id)');
    await db.execute('''
      CREATE TABLE notif_items (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        list_id       INTEGER NOT NULL REFERENCES notif_lists(id) ON DELETE CASCADE,
        external_id   TEXT,
        title         TEXT NOT NULL,
        body          TEXT,
        open_url      TEXT,
        payload       TEXT,
        position      INTEGER NOT NULL,
        step          INTEGER NOT NULL DEFAULT 0,
        next_due_at   INTEGER,
        last_fired_at INTEGER,
        last_grade    INTEGER,
        status        TEXT NOT NULL DEFAULT 'active',
        created_at    INTEGER NOT NULL,
        UNIQUE(list_id, external_id)
      )''');
    await db.execute('''
      CREATE INDEX idx_notif_items_due ON notif_items(next_due_at)
        WHERE status = 'active' ''');
    await db.execute('''
      CREATE TABLE notif_events (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id      INTEGER NOT NULL REFERENCES notif_items(id) ON DELETE CASCADE,
        fired_at     INTEGER NOT NULL,
        responded_at INTEGER,
        grade        INTEGER,
        source       TEXT
      )''');
    await db.execute(
        'CREATE INDEX idx_notif_events_item ON notif_events(item_id, fired_at)');
    await seedBuiltinSchedules(db);
  }

  /// Idempotent (INSERT OR IGNORE on the UNIQUE builtin_key): safe to re-run
  /// as a repair pass without duplicating rows.
  static Future<void> seedBuiltinSchedules(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final b in builtinSchedules) {
      await db.rawInsert(
        'INSERT OR IGNORE INTO notif_schedules '
        '(name, kind, builtin_key, config, created_at) VALUES (?, ?, ?, ?, ?)',
        [b.name, b.kind, b.key, jsonEncode(b.config), now],
      );
    }
  }
```

At the end of `createSchema` (after the `playlist_items` index), add:

```dart
    await createNotifTables(db);
```

At the end of `runMigrations` (after the `if (oldV < 6)` block), add:

```dart
    if (oldV < 7) {
      await createNotifTables(db);
    }
```

- [ ] **Step 4: Run, verify pass**

Run: `flutter test test/notif/migration_test.dart test/notif/schema_baseline_test.dart -r expanded`
Expected: all PASS. (`schema_baseline_test` re-run: fresh schema now also contains notif tables — its `containsAll` assertion still holds.)

- [ ] **Step 5: Commit**

```bash
git add lib/db.dart test/notif/migration_test.dart
git commit -m "feat(notif): schema v7 — notif tables + built-in schedule seeds"
```

---

## Task 8: Row models + `NotifDao`

**Files:**
- Create: `lib/notif/notif_dao.dart`
- Modify: `lib/db.dart` (add `notifDao()` accessor)
- Create: `test/notif/notif_dao_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/notif/notif_dao_test.dart`:

```dart
import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/schedules.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late NotifDao dao;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 7,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, v) => CupitorDb.createSchema(d)));
    dao = NotifDao(db);
  });
  tearDown(() => db.close());

  test('listSchedules returns the 7 seeds; scheduleByKey resolves both forms',
      () async {
    expect(await dao.listSchedules(), hasLength(7));
    final eb = await dao.scheduleByKey('ebbinghaus');
    expect(eb!.kind, 'series');
    final custom = await dao.createCustomSchedule(
        name: 'Mine', kind: 'series',
        config: {'offsets_waking_hours': [1, 2, 4]});
    final again = await dao.scheduleByKey('custom:${custom.id}');
    expect(again!.name, 'Mine');
    expect(await dao.scheduleByKey('nope'), isNull);
    expect(await dao.scheduleByKey('custom:zzz'), isNull);
  });

  test('createCustomSchedule rejects invalid config', () async {
    expect(
        () => dao.createCustomSchedule(
            name: 'Bad', kind: 'series', config: {'offsets_waking_hours': []}),
        throwsA(isA<ScheduleConfigError>()));
  });

  test('list + item lifecycle with cascade delete', () async {
    final eb = await dao.scheduleByKey('ebbinghaus');
    final list = await dao.createList(
        profileId: 1, name: 'French', source: 'webpage',
        externalKey: 'fr-1', scheduleId: eb!.id);
    expect((await dao.listByExternalKey(1, 'fr-1'))!.id, list.id);
    expect(await dao.listByExternalKey(1, 'zzz'), isNull);

    final item = await dao.insertItem(
        listId: list.id, externalId: 'c1', title: 'le dénouement',
        position: 0, nextDueAt: 1000);
    expect((await dao.itemsForList(list.id)), hasLength(1));
    expect((await dao.itemByExternalId(list.id, 'c1'))!.id, item.id);

    await dao.updateItem(item.id, {'step': 2, 'next_due_at': 5000});
    expect((await dao.itemByExternalId(list.id, 'c1'))!.step, 2);

    await dao.insertEvent(
        itemId: item.id, firedAt: 1000, respondedAt: 1100,
        grade: 3, source: 'webpage');
    expect((await dao.lastEventForItem(item.id))!.grade, 3);

    await dao.deleteList(list.id);
    expect(await dao.itemsForList(list.id), isEmpty);
    expect(await dao.lastEventForItem(item.id), isNull); // cascaded
  });

  test('updateList bumps updated_at', () async {
    final list = await dao.createList(
        profileId: 1, name: 'L', source: 'app');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await dao.updateList(list.id, {'status': 'paused'});
    final rows = await dao.listsForProfile(1);
    expect(rows.single.status, 'paused');
    expect(rows.single.updatedAt, greaterThan(list.updatedAt));
  });

  test('dueItems: only active items in active lists, due, ordered', () async {
    final eb = await dao.scheduleByKey('ebbinghaus');
    final a = await dao.createList(
        profileId: 1, name: 'A', source: 'app', scheduleId: eb!.id);
    final b = await dao.createList(
        profileId: 1, name: 'B', source: 'app', scheduleId: eb.id);
    await dao.insertItem(listId: a.id, title: 'due-late', position: 0, nextDueAt: 200);
    await dao.insertItem(listId: a.id, title: 'due-early', position: 1, nextDueAt: 100);
    await dao.insertItem(listId: a.id, title: 'future', position: 2, nextDueAt: 9999);
    final suspended = await dao.insertItem(
        listId: a.id, title: 'suspended', position: 3, nextDueAt: 100);
    await dao.updateItem(suspended.id, {'status': 'suspended'});
    await dao.insertItem(listId: b.id, title: 'paused-list', position: 0, nextDueAt: 100);
    await dao.updateList(b.id, {'status': 'paused'});

    final due = await dao.dueItems(500);
    expect(due.map((i) => i.title), ['due-early', 'due-late']);
  });

  test('UNIQUE(list_id, external_id) allows multiple NULLs', () async {
    final list = await dao.createList(profileId: 1, name: 'L', source: 'app');
    await dao.insertItem(listId: list.id, title: 'one', position: 0);
    await dao.insertItem(listId: list.id, title: 'two', position: 1);
    expect(await dao.itemsForList(list.id), hasLength(2));
  });
}
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/notif_dao_test.dart -r expanded`
Expected: FAIL — `notif_dao.dart` doesn't exist.

- [ ] **Step 3: Implement**

Create `lib/notif/notif_dao.dart`:

```dart
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'schedules.dart';

/// Row models mirror the v7 columns 1:1 (spec: data-model section). Times are
/// epoch ms; `config` and `payload` stay raw JSON strings here — parsing is
/// the caller's business.

class NotifScheduleRow {
  final int id;
  final String name;
  final String kind; // 'series' | 'recurring'
  final String? builtinKey;
  final String config; // raw JSON
  final int createdAt;
  const NotifScheduleRow({
    required this.id, required this.name, required this.kind,
    required this.builtinKey, required this.config, required this.createdAt,
  });

  /// The form that crosses the bridge as `schedule_key`.
  String get key => builtinKey ?? 'custom:$id';

  static NotifScheduleRow fromMap(Map<String, Object?> m) => NotifScheduleRow(
        id: m['id'] as int,
        name: m['name'] as String,
        kind: m['kind'] as String,
        builtinKey: m['builtin_key'] as String?,
        config: m['config'] as String,
        createdAt: m['created_at'] as int,
      );
}

class NotifListRow {
  final int id;
  final int profileId;
  final String name;
  final String source; // 'webpage' | 'app'
  final String? externalKey;
  final int? scheduleId;
  final String status; // 'active' | 'paused'
  final int cursor;
  final int? nextFireAt;
  final int? lastFiredAt;
  final int createdAt;
  final int updatedAt;
  const NotifListRow({
    required this.id, required this.profileId, required this.name,
    required this.source, required this.externalKey, required this.scheduleId,
    required this.status, required this.cursor, required this.nextFireAt,
    required this.lastFiredAt, required this.createdAt, required this.updatedAt,
  });

  static NotifListRow fromMap(Map<String, Object?> m) => NotifListRow(
        id: m['id'] as int,
        profileId: m['profile_id'] as int,
        name: m['name'] as String,
        source: m['source'] as String,
        externalKey: m['external_key'] as String?,
        scheduleId: m['schedule_id'] as int?,
        status: m['status'] as String,
        cursor: (m['cursor'] as num?)?.toInt() ?? 0,
        nextFireAt: (m['next_fire_at'] as num?)?.toInt(),
        lastFiredAt: (m['last_fired_at'] as num?)?.toInt(),
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
      );
}

class NotifItemRow {
  final int id;
  final int listId;
  final String? externalId;
  final String title;
  final String? body;
  final String? openUrl;
  final String? payload; // raw JSON, echoed back verbatim
  final int position;
  final int step;
  final int? nextDueAt;
  final int? lastFiredAt;
  final int? lastGrade;
  final String status; // 'active' | 'suspended' | 'done'
  final int createdAt;
  const NotifItemRow({
    required this.id, required this.listId, required this.externalId,
    required this.title, required this.body, required this.openUrl,
    required this.payload, required this.position, required this.step,
    required this.nextDueAt, required this.lastFiredAt, required this.lastGrade,
    required this.status, required this.createdAt,
  });

  static NotifItemRow fromMap(Map<String, Object?> m) => NotifItemRow(
        id: m['id'] as int,
        listId: m['list_id'] as int,
        externalId: m['external_id'] as String?,
        title: m['title'] as String,
        body: m['body'] as String?,
        openUrl: m['open_url'] as String?,
        payload: m['payload'] as String?,
        position: (m['position'] as num?)?.toInt() ?? 0,
        step: (m['step'] as num?)?.toInt() ?? 0,
        nextDueAt: (m['next_due_at'] as num?)?.toInt(),
        lastFiredAt: (m['last_fired_at'] as num?)?.toInt(),
        lastGrade: (m['last_grade'] as num?)?.toInt(),
        status: m['status'] as String,
        createdAt: m['created_at'] as int,
      );
}

class NotifEventRow {
  final int id;
  final int itemId;
  final int firedAt;
  final int? respondedAt;
  final int? grade;
  final String? source; // 'action' | 'webpage' | 'auto'
  const NotifEventRow({
    required this.id, required this.itemId, required this.firedAt,
    required this.respondedAt, required this.grade, required this.source,
  });

  static NotifEventRow fromMap(Map<String, Object?> m) => NotifEventRow(
        id: m['id'] as int,
        itemId: m['item_id'] as int,
        firedAt: m['fired_at'] as int,
        respondedAt: (m['responded_at'] as num?)?.toInt(),
        grade: (m['grade'] as num?)?.toInt(),
        source: m['source'] as String?,
      );
}

/// Takes the handle directly (not CupitorDb) so every test runs on
/// sqflite_common_ffi in memory — CupitorDb._open() needs path_provider,
/// which doesn't exist in a unit test. Production callers get one via
/// CupitorDb.instance.notifDao(), which honours the null-if-unavailable
/// contract.
class NotifDao {
  final Database db;
  NotifDao(this.db);

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  // ── schedules ──────────────────────────────────────────────────────

  Future<List<NotifScheduleRow>> listSchedules() async =>
      (await db.query('notif_schedules', orderBy: 'id ASC'))
          .map(NotifScheduleRow.fromMap)
          .toList(growable: false);

  Future<NotifScheduleRow?> scheduleById(int id) async {
    final r = await db.query('notif_schedules',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : NotifScheduleRow.fromMap(r.first);
  }

  /// Resolves both bridge forms: a builtin_key, or 'custom:<id>'.
  Future<NotifScheduleRow?> scheduleByKey(String key) async {
    if (key.startsWith('custom:')) {
      final id = int.tryParse(key.substring(7));
      return id == null ? null : scheduleById(id);
    }
    final r = await db.query('notif_schedules',
        where: 'builtin_key = ?', whereArgs: [key], limit: 1);
    return r.isEmpty ? null : NotifScheduleRow.fromMap(r.first);
  }

  /// Validates via [validateScheduleConfig]; throws [ScheduleConfigError].
  Future<NotifScheduleRow> createCustomSchedule({
    required String name,
    required String kind,
    required Map<String, Object?> config,
  }) async {
    final normalized = jsonEncode(validateScheduleConfig(kind, config));
    final now = _now();
    final id = await db.insert('notif_schedules', {
      'name': name, 'kind': kind, 'builtin_key': null,
      'config': normalized, 'created_at': now,
    });
    return NotifScheduleRow(
        id: id, name: name, kind: kind, builtinKey: null,
        config: normalized, createdAt: now);
  }

  // ── lists ──────────────────────────────────────────────────────────

  Future<NotifListRow> createList({
    required int profileId,
    required String name,
    required String source,
    String? externalKey,
    int? scheduleId,
    int? nextFireAt,
  }) async {
    final now = _now();
    final id = await db.insert('notif_lists', {
      'profile_id': profileId, 'name': name, 'source': source,
      'external_key': externalKey, 'schedule_id': scheduleId,
      'status': 'active', 'cursor': 0, 'next_fire_at': nextFireAt,
      'created_at': now, 'updated_at': now,
    });
    return NotifListRow(
        id: id, profileId: profileId, name: name, source: source,
        externalKey: externalKey, scheduleId: scheduleId, status: 'active',
        cursor: 0, nextFireAt: nextFireAt, lastFiredAt: null,
        createdAt: now, updatedAt: now);
  }

  Future<NotifListRow?> listByExternalKey(int profileId, String key) async {
    final r = await db.query('notif_lists',
        where: 'profile_id = ? AND external_key = ?',
        whereArgs: [profileId, key], limit: 1);
    return r.isEmpty ? null : NotifListRow.fromMap(r.first);
  }

  Future<List<NotifListRow>> listsForProfile(int profileId) async =>
      (await db.query('notif_lists',
              where: 'profile_id = ?', whereArgs: [profileId],
              orderBy: 'created_at ASC, id ASC'))
          .map(NotifListRow.fromMap)
          .toList(growable: false);

  /// Column-name keyed partial update; updated_at is always bumped.
  Future<void> updateList(int id, Map<String, Object?> fields) async {
    await db.update('notif_lists', {...fields, 'updated_at': _now()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteList(int id) async {
    await db.delete('notif_lists', where: 'id = ?', whereArgs: [id]);
  }

  // ── items ──────────────────────────────────────────────────────────

  Future<NotifItemRow> insertItem({
    required int listId,
    String? externalId,
    required String title,
    String? body,
    String? openUrl,
    String? payloadJson,
    required int position,
    int step = 0,
    int? nextDueAt,
  }) async {
    final now = _now();
    final id = await db.insert('notif_items', {
      'list_id': listId, 'external_id': externalId, 'title': title,
      'body': body, 'open_url': openUrl, 'payload': payloadJson,
      'position': position, 'step': step, 'next_due_at': nextDueAt,
      'status': 'active', 'created_at': now,
    });
    return NotifItemRow(
        id: id, listId: listId, externalId: externalId, title: title,
        body: body, openUrl: openUrl, payload: payloadJson,
        position: position, step: step, nextDueAt: nextDueAt,
        lastFiredAt: null, lastGrade: null, status: 'active', createdAt: now);
  }

  Future<List<NotifItemRow>> itemsForList(int listId) async =>
      (await db.query('notif_items',
              where: 'list_id = ?', whereArgs: [listId],
              orderBy: 'position ASC, id ASC'))
          .map(NotifItemRow.fromMap)
          .toList(growable: false);

  Future<NotifItemRow?> itemByExternalId(int listId, String externalId) async {
    final r = await db.query('notif_items',
        where: 'list_id = ? AND external_id = ?',
        whereArgs: [listId, externalId], limit: 1);
    return r.isEmpty ? null : NotifItemRow.fromMap(r.first);
  }

  Future<void> updateItem(int id, Map<String, Object?> fields) async {
    await db.update('notif_items', fields, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteItem(int id) async {
    await db.delete('notif_items', where: 'id = ?', whereArgs: [id]);
  }

  /// Active items in active lists, due at or before [nowMs]. Fed to the
  /// arming pass and the sweep (Plan 2).
  Future<List<NotifItemRow>> dueItems(int nowMs) async =>
      (await db.rawQuery('''
        SELECT i.* FROM notif_items i
        JOIN notif_lists l ON l.id = i.list_id
        WHERE i.status = 'active' AND l.status = 'active'
          AND i.next_due_at IS NOT NULL AND i.next_due_at <= ?
        ORDER BY i.next_due_at ASC, i.id ASC
      ''', [nowMs]))
          .map(NotifItemRow.fromMap)
          .toList(growable: false);

  // ── events ─────────────────────────────────────────────────────────

  Future<int> insertEvent({
    required int itemId,
    required int firedAt,
    int? respondedAt,
    int? grade,
    String? source,
  }) =>
      db.insert('notif_events', {
        'item_id': itemId, 'fired_at': firedAt,
        'responded_at': respondedAt, 'grade': grade, 'source': source,
      });

  Future<NotifEventRow?> lastEventForItem(int itemId) async {
    final r = await db.query('notif_events',
        where: 'item_id = ?', whereArgs: [itemId],
        orderBy: 'fired_at DESC, id DESC', limit: 1);
    return r.isEmpty ? null : NotifEventRow.fromMap(r.first);
  }
}
```

- [ ] **Step 4: Add the accessor to `CupitorDb`**

In `lib/db.dart`, add the import:

```dart
import 'notif/notif_dao.dart';
```

(this is a second import line alongside Task 7's `import 'notif/schedules.dart' show builtinSchedules;` — keep both). Below `rawDb()` (`lib/db.dart:44`), add:

```dart
  /// Notification DAO, or null when the DB is unavailable — same
  /// null-if-unavailable contract as [rawDb]. The DAO takes the raw handle
  /// so its tests run on sqflite_common_ffi (see notif_dao.dart).
  Future<NotifDao?> notifDao() async {
    final db = await _open();
    return db == null ? null : NotifDao(db);
  }
```

- [ ] **Step 5: Run, verify pass**

Run: `flutter test test/notif/ -r expanded && flutter analyze lib/notif lib/db.dart`
Expected: all PASS, no analyzer errors.

- [ ] **Step 6: Commit**

```bash
git add lib/notif/notif_dao.dart lib/db.dart test/notif/notif_dao_test.dart
git commit -m "feat(notif): row models + NotifDao + CupitorDb.notifDao accessor"
```

---

## Task 9: Bridge core — dispatch, acks, capabilities, getSchedules

**Files:**
- Create: `lib/notif/notif_bridge.dart`
- Create: `test/notif/notif_bridge_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/notif/notif_bridge_test.dart`. The `setUp` block here is shared by Tasks 9–11; write it once now:

```dart
import 'dart:convert';

import 'package:cupitor/db.dart';
import 'package:cupitor/notif/notif_bridge.dart';
import 'package:cupitor/notif/notif_dao.dart';
import 'package:cupitor/notif/waking_clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late tz.Location ny;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  late Database db;
  late NotifDao dao;
  late List<(String, Map<String, Object?>)> events;
  late NotifBridge bridge;
  late tz.TZDateTime now;
  var daoAvailable = true;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 7,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, v) => CupitorDb.createSchema(d)));
    dao = NotifDao(db);
    events = [];
    daoAvailable = true;
    now = tz.TZDateTime(ny, 2026, 7, 27, 10);
    bridge = NotifBridge(
      dao: () async => daoAvailable ? dao : null,
      activeProfileId: () => 1,
      emit: (e, d) => events.add((e, d)),
      capabilities: () async => const NotifCapabilities(
          supported: true, permission: 'unknown', exactAlarms: false,
          actions: false, platform: 'test'),
      requestPermission: () async => 'unknown',
      window: () => WakingWindow.defaults,
      now: () => now,
    );
  });
  tearDown(() => db.close());

  Map<String, Object?> lastAck() =>
      events.lastWhere((e) => e.$1 == 'cupitorNotifAck').$2;
  Map<String, Object?>? lastEvent(String name) {
    final hits = events.where((e) => e.$1 == name);
    return hits.isEmpty ? null : hits.last.$2;
  }

  // Used from Task 10 onward; defined here so every task's tests share it.
  Future<void> createFrenchList({String scheduleKey = 'ebbinghaus'}) =>
      bridge.handle(jsonEncode({
        'op': 'createList', 'request_id': 'r-create',
        'external_key': 'fr-1', 'name': 'French idioms',
        'schedule_key': scheduleKey,
        'items': [
          {'external_id': 'c1', 'title': 'le dénouement',
           'body': 'the outcome', 'open_url': 'https://x/1',
           'payload': {'deck': 7}},
          {'external_id': 'c2', 'title': 'tomber dans les pommes'},
        ],
      }));

  group('dispatch + acks', () {
    test('malformed JSON → bad_json ack', () async {
      await bridge.handle('{nope');
      expect(lastAck()['ok'], false);
      expect(lastAck()['error'], 'bad_json');
    });
    test('missing op → unknown_op', () async {
      await bridge.handle('{"request_id":"r1"}');
      expect(lastAck()['error'], 'unknown_op');
      expect(lastAck()['request_id'], 'r1');
    });
    test('unknown op → unknown_op, echoes op', () async {
      await bridge.handle('{"op":"frobnicate","request_id":"r2"}');
      expect(lastAck()['op'], 'frobnicate');
      expect(lastAck()['error'], 'unknown_op');
    });
    test('dao unavailable → unsupported, nothing emitted besides ack',
        () async {
      daoAvailable = false;
      await bridge.handle('{"op":"getSchedules","request_id":"r3"}');
      expect(lastAck()['error'], 'unsupported');
      expect(lastEvent('cupitorNotifSchedules'), isNull);
    });
  });

  group('getCapabilities / requestPermission', () {
    test('capabilities returned in ack data', () async {
      await bridge.handle('{"op":"getCapabilities","request_id":"r4"}');
      final ack = lastAck();
      expect(ack['ok'], true);
      final data = ack['data'] as Map<String, Object?>;
      expect(data['supported'], true);
      expect(data['permission'], 'unknown');
      expect(data['platform'], 'test');
    });
    test('requestPermission answers via ack data', () async {
      await bridge.handle('{"op":"requestPermission","request_id":"r5"}');
      expect((lastAck()['data'] as Map)['permission'], 'unknown');
    });
  });

  group('getSchedules', () {
    test('emits the 7 built-ins with keys and configs', () async {
      await bridge.handle('{"op":"getSchedules","request_id":"r6"}');
      expect(lastAck()['ok'], true);
      final payload = lastEvent('cupitorNotifSchedules')!;
      final schedules = payload['schedules'] as List;
      expect(schedules, hasLength(7));
      final first = schedules.first as Map;
      expect(first['key'], 'ebbinghaus');
      expect(first['builtin'], true);
      expect((first['config'] as Map)['offsets_waking_hours'], isA<List>());
    });
  });
}
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/notif_bridge_test.dart -r expanded`
Expected: FAIL — `notif_bridge.dart` doesn't exist.

- [ ] **Step 3: Implement the bridge skeleton**

Create `lib/notif/notif_bridge.dart`. This file grows in Tasks 10–11; the `switch` already routes every spec op — the ones not yet implemented fall to `unknown_op` until their task lands (their cases are added by later tasks):

```dart
import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'notif_dao.dart';
import 'recurring_scheduler.dart';
import 'schedules.dart';
import 'series_scheduler.dart';
import 'waking_clock.dart';

/// What the webpage learns from getCapabilities before offering the feature.
/// In Plan 1 permission/exactAlarms/actions are stubs — Plan 2's delivery
/// layer supplies real values through the same injected callback.
class NotifCapabilities {
  final bool supported;
  final String permission; // 'unknown' | 'granted' | 'denied'
  final bool exactAlarms;
  final bool actions;
  final String platform;
  const NotifCapabilities({
    required this.supported, required this.permission,
    required this.exactAlarms, required this.actions, required this.platform,
  });
  Map<String, Object?> toJson() => {
        'supported': supported, 'permission': permission,
        'exact_alarms': exactAlarms, 'actions': actions, 'platform': platform,
      };
}

typedef EmitEvent = void Function(String event, Map<String, Object?> detail);

/// The NotifBridge JS-channel handler (spec §Bridge). Mirrors PlaylistBridge:
/// JS→Flutter via the channel, Flutter→JS via CustomEvents — plus acks,
/// because these ops can genuinely fail. All dependencies are injected so
/// tests feed raw JSON and capture emitted events with no webview.
///
/// Failure posture (spec): never throw into the channel; every path acks.
class NotifBridge {
  final Future<NotifDao?> Function() dao;
  final int Function() activeProfileId;
  final EmitEvent emit;
  final Future<NotifCapabilities> Function() capabilities;
  final Future<String> Function() requestPermission;
  final WakingWindow Function() window;
  final tz.TZDateTime Function() now;

  /// Plan 2 hooks rearm() here; null until then.
  final Future<void> Function()? onMutated;

  NotifBridge({
    required this.dao,
    required this.activeProfileId,
    required this.emit,
    required this.capabilities,
    required this.requestPermission,
    required this.window,
    required this.now,
    this.onMutated,
  });

  void _ack(String? requestId, String op, bool ok,
      {String? error, Map<String, Object?>? data}) {
    emit('cupitorNotifAck', {
      'request_id': requestId,
      'op': op,
      'ok': ok,
      if (error != null) 'error': error,
      if (data != null) 'data': data,
    });
  }

  Future<NotifDao?> _daoOrAck(String? reqId, String op) async {
    final d = await dao();
    if (d == null) _ack(reqId, op, false, error: 'unsupported');
    return d;
  }

  Future<void> handle(String raw) async {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _ack(null, 'unknown', false, error: 'bad_json');
      return;
    }
    final op = m['op'] as String?;
    final reqId = m['request_id'] as String?;
    if (op == null) {
      _ack(reqId, 'unknown', false, error: 'unknown_op');
      return;
    }
    try {
      switch (op) {
        case 'getCapabilities':
          _ack(reqId, op, true, data: (await capabilities()).toJson());
        case 'requestPermission':
          _ack(reqId, op, true, data: {'permission': await requestPermission()});
        case 'getSchedules':
          await _getSchedules(reqId);
        // Task 10 adds: createList, syncItems, getLists.
        // Task 11 adds: grade, setSchedule, setStatus, deleteList.
        default:
          _ack(reqId, op, false, error: 'unknown_op');
      }
    } catch (e) {
      // Nothing may escape into the channel.
      _ack(reqId, op, false, error: 'internal');
    }
  }

  // ── payload builders ───────────────────────────────────────────────

  Map<String, Object?> _schedulesPayload(List<NotifScheduleRow> rows) => {
        'version': 1,
        'schedules': [
          for (final s in rows)
            {
              'key': s.key,
              'name': s.name,
              'kind': s.kind,
              'builtin': s.builtinKey != null,
              'config': jsonDecode(s.config),
            }
        ],
      };

  Future<void> _getSchedules(String? reqId) async {
    const op = 'getSchedules';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    emit('cupitorNotifSchedules', _schedulesPayload(await d.listSchedules()));
    _ack(reqId, op, true);
  }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `flutter test test/notif/notif_bridge_test.dart -r expanded`
Expected: PASS. (The analyzer will flag the not-yet-used engine imports — that resolves in Task 10; if `flutter analyze` is run at this step, `unused_import` infos are expected and acceptable until then.)

- [ ] **Step 5: Commit**

```bash
git add lib/notif/notif_bridge.dart test/notif/notif_bridge_test.dart
git commit -m "feat(notif): bridge skeleton — dispatch, acks, capabilities, getSchedules"
```

---

## Task 10: Bridge lists — createList, syncItems, getLists

**Files:**
- Modify: `lib/notif/notif_bridge.dart`
- Modify: `test/notif/notif_bridge_test.dart`

- [ ] **Step 1: Add the failing tests**

Append inside `main()` in `test/notif/notif_bridge_test.dart`:

```dart
  group('createList', () {
    test('series list: items at step 0, due at offsets[0], events pushed',
        () async {
      await createFrenchList();
      expect(lastAck()['ok'], true);
      final lists = lastEvent('cupitorNotifLists')!['lists'] as List;
      final l = lists.single as Map;
      expect(l['external_key'], 'fr-1');
      expect(l['schedule_key'], 'ebbinghaus');
      expect(l['status'], 'active');
      final items = l['items'] as List;
      expect(items, hasLength(2));
      final c1 = items.first as Map;
      expect(c1['external_id'], 'c1');
      expect(c1['step'], 0);
      expect(c1['payload'], {'deck': 7});
      // ebbinghaus offsets[0] = 0.25 wh from Mon 10:00 → 10:15.
      final expected = tz.TZDateTime(ny, 2026, 7, 27, 10, 15)
          .millisecondsSinceEpoch;
      expect(c1['next_due_at'], expected);
      // No internal row ids cross the bridge.
      expect(c1.containsKey('id'), isFalse);
      expect(l.containsKey('id'), isFalse);
    });
    test('recurring list: items undue, list gets next_fire_at', () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      final l = (lastEvent('cupitorNotifLists')!['lists'] as List).single as Map;
      expect((l['items'] as List).first['next_due_at'], isNull);
      // Mon 10:00 is past 09:00 → Tue 09:00.
      expect(l['next_fire_at'],
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
    });
    test('duplicate external_key → duplicate_key', () async {
      await createFrenchList();
      await createFrenchList();
      expect(lastAck()['error'], 'duplicate_key');
    });
    test('unknown schedule → unknown_schedule', () async {
      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'x', 'name': 'X',
        'schedule_key': 'nope', 'items': [],
      }));
      expect(lastAck()['error'], 'unknown_schedule');
    });
    test('item missing title → bad_payload, nothing created', () async {
      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'x', 'name': 'X',
        'schedule_key': 'ebbinghaus',
        'items': [{'external_id': 'c1'}],
      }));
      expect(lastAck()['error'], 'bad_payload');
      expect(await dao.listByExternalKey(1, 'x'), isNull);
    });
    test('duplicate external_id within payload → bad_payload', () async {
      await bridge.handle(jsonEncode({
        'op': 'createList', 'external_key': 'x', 'name': 'X',
        'schedule_key': 'ebbinghaus',
        'items': [
          {'external_id': 'c1', 'title': 'a'},
          {'external_id': 'c1', 'title': 'b'},
        ],
      }));
      expect(lastAck()['error'], 'bad_payload');
    });
  });

  group('syncItems', () {
    test('merge: updates content, preserves SRS state, inserts new', () async {
      await createFrenchList();
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      final c1 = (await dao.itemByExternalId(list.id, 'c1'))!;
      await dao.updateItem(c1.id, {'step': 4, 'next_due_at': 123456});

      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'request_id': 'r-sync', 'external_key': 'fr-1',
        'items': [
          {'external_id': 'c1', 'title': 'le dénouement (fixed)'},
          {'external_id': 'c3', 'title': 'quoi qu\'il en soit'},
        ],
      }));
      expect(lastAck()['ok'], true);

      final c1After = (await dao.itemByExternalId(list.id, 'c1'))!;
      expect(c1After.title, 'le dénouement (fixed)');
      expect(c1After.step, 4); // three weeks of progress survives a typo fix
      expect(c1After.nextDueAt, 123456);
      // c2 absent from payload: merge leaves it alone.
      expect(await dao.itemByExternalId(list.id, 'c2'), isNotNull);
      // c3 inserted fresh at step 0.
      expect((await dao.itemByExternalId(list.id, 'c3'))!.step, 0);
    });
    test('replace: absent items are deleted', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'external_key': 'fr-1', 'mode': 'replace',
        'items': [{'external_id': 'c1', 'title': 'le dénouement'}],
      }));
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(await dao.itemByExternalId(list.id, 'c2'), isNull);
      expect(await dao.itemByExternalId(list.id, 'c1'), isNotNull);
    });
    test('unknown list → unknown_list', () async {
      await bridge.handle(jsonEncode(
          {'op': 'syncItems', 'external_key': 'zzz', 'items': []}));
      expect(lastAck()['error'], 'unknown_list');
    });
    test('bad mode → bad_payload', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'syncItems', 'external_key': 'fr-1', 'mode': 'upsert',
        'items': [],
      }));
      expect(lastAck()['error'], 'bad_payload');
    });
  });

  group('getLists', () {
    test('pushes cupitorNotifLists and acks', () async {
      await createFrenchList();
      events.clear();
      await bridge.handle('{"op":"getLists","request_id":"r-gl"}');
      expect(lastAck()['ok'], true);
      expect(lastEvent('cupitorNotifLists'), isNotNull);
    });
  });
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/notif_bridge_test.dart -r expanded`
Expected: new groups FAIL with `unknown_op` acks.

- [ ] **Step 3: Implement**

In `lib/notif/notif_bridge.dart`, add to the `switch`:

```dart
        case 'createList':
          await _createList(reqId, m);
        case 'syncItems':
          await _syncItems(reqId, m);
        case 'getLists':
          await _getLists(reqId);
```

Add below `_getSchedules`:

```dart
  // ── item input parsing ─────────────────────────────────────────────

  /// Returns null on any invalid item (missing/empty external_id or title,
  /// duplicate external_id) — the whole op is rejected atomically.
  List<_ItemInput>? _parseItems(Object? raw) {
    if (raw is! List) return null;
    final out = <_ItemInput>[];
    final seen = <String>{};
    for (final e in raw) {
      if (e is! Map) return null;
      final id = e['external_id'] as String?;
      final title = e['title'] as String?;
      if (id == null || id.isEmpty || title == null || title.isEmpty) {
        return null;
      }
      if (!seen.add(id)) return null;
      out.add(_ItemInput(
        externalId: id,
        title: title,
        body: e['body'] as String?,
        openUrl: e['open_url'] as String?,
        payloadJson: e['payload'] == null ? null : jsonEncode(e['payload']),
      ));
    }
    return out;
  }

  /// Series offsets when the schedule is a series, else null. The null form
  /// doubles as "items get no per-item due time" (recurring lists).
  Future<List<double>?> _offsetsFor(NotifDao d, int? scheduleId) async {
    if (scheduleId == null) return null;
    final s = await d.scheduleById(scheduleId);
    if (s == null || s.kind != 'series') return null;
    return seriesOffsets(jsonDecode(s.config) as Map<String, dynamic>);
  }

  // ── list payloads ──────────────────────────────────────────────────

  Future<Map<String, Object?>> _listsPayload(NotifDao d) async {
    final lists = await d.listsForProfile(activeProfileId());
    final out = <Map<String, Object?>>[];
    for (final l in lists) {
      final schedule =
          l.scheduleId == null ? null : await d.scheduleById(l.scheduleId!);
      final items = await d.itemsForList(l.id);
      out.add({
        // Identity rule (spec): external ids only, internal row ids never
        // cross the bridge.
        'external_key': l.externalKey,
        'name': l.name,
        'source': l.source,
        'schedule_key': schedule?.key,
        'status': l.status,
        'next_fire_at': l.nextFireAt,
        'items': [
          for (final i in items)
            {
              'external_id': i.externalId,
              'title': i.title,
              'body': i.body,
              'open_url': i.openUrl,
              'payload': i.payload == null ? null : jsonDecode(i.payload!),
              'position': i.position,
              'step': i.step,
              'next_due_at': i.nextDueAt,
              'status': i.status,
            }
        ],
      });
    }
    return {'version': 1, 'lists': out};
  }

  Future<void> _pushLists(NotifDao d) async {
    emit('cupitorNotifLists', await _listsPayload(d));
  }

  Future<void> _afterMutation(NotifDao d) async {
    await _pushLists(d);
    await onMutated?.call();
  }

  // ── ops ────────────────────────────────────────────────────────────

  Future<void> _createList(String? reqId, Map<String, dynamic> m) async {
    const op = 'createList';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final key = m['external_key'] as String?;
    final name = m['name'] as String?;
    final items = _parseItems(m['items']);
    if (key == null || key.isEmpty || name == null || name.isEmpty ||
        items == null) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final profileId = activeProfileId();
    if (await d.listByExternalKey(profileId, key) != null) {
      _ack(reqId, op, false, error: 'duplicate_key');
      return;
    }
    final schedule =
        await d.scheduleByKey((m['schedule_key'] as String?) ?? 'ebbinghaus');
    if (schedule == null) {
      _ack(reqId, op, false, error: 'unknown_schedule');
      return;
    }
    final w = window();
    final t = now();
    final config = jsonDecode(schedule.config) as Map<String, dynamic>;
    int? nextFireAt;
    List<double>? offsets;
    if (schedule.kind == 'recurring') {
      nextFireAt =
          nextRecurringFire(parseRecurring(config), t, w).millisecondsSinceEpoch;
    } else {
      offsets = seriesOffsets(config);
    }
    final list = await d.createList(
        profileId: profileId, name: name, source: 'webpage',
        externalKey: key, scheduleId: schedule.id, nextFireAt: nextFireAt);
    var pos = 0;
    for (final it in items) {
      await d.insertItem(
        listId: list.id, externalId: it.externalId, title: it.title,
        body: it.body, openUrl: it.openUrl, payloadJson: it.payloadJson,
        position: pos++,
        nextDueAt: offsets == null
            ? null
            : addWakingHours(t, offsets[0], w).millisecondsSinceEpoch,
      );
    }
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _syncItems(String? reqId, Map<String, dynamic> m) async {
    const op = 'syncItems';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final key = m['external_key'] as String?;
    final items = _parseItems(m['items']);
    final mode = (m['mode'] as String?) ?? 'merge';
    if (key == null || items == null || (mode != 'merge' && mode != 'replace')) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final list = await d.listByExternalKey(activeProfileId(), key);
    if (list == null) {
      _ack(reqId, op, false, error: 'unknown_list');
      return;
    }
    final offsets = await _offsetsFor(d, list.scheduleId);
    final existing = await d.itemsForList(list.id);
    final byExt = {
      for (final i in existing)
        if (i.externalId != null) i.externalId!: i
    };
    final w = window();
    final t = now();
    final seen = <String>{};
    var pos = 0;
    for (final it in items) {
      seen.add(it.externalId);
      final cur = byExt[it.externalId];
      if (cur == null) {
        await d.insertItem(
          listId: list.id, externalId: it.externalId, title: it.title,
          body: it.body, openUrl: it.openUrl, payloadJson: it.payloadJson,
          position: pos,
          nextDueAt: offsets == null
              ? null
              : addWakingHours(t, offsets[0], w).millisecondsSinceEpoch,
        );
      } else {
        // Merge semantics (spec): content updates, SRS state (step,
        // next_due_at, status, history) survives.
        await d.updateItem(cur.id, {
          'title': it.title, 'body': it.body, 'open_url': it.openUrl,
          'payload': it.payloadJson, 'position': pos,
        });
      }
      pos++;
    }
    if (mode == 'replace') {
      for (final i in existing) {
        if (i.externalId != null && !seen.contains(i.externalId)) {
          await d.deleteItem(i.id);
        }
      }
    }
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _getLists(String? reqId) async {
    const op = 'getLists';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    await _pushLists(d);
    _ack(reqId, op, true);
  }
```

Add the private class at the bottom of the file:

```dart
class _ItemInput {
  final String externalId;
  final String title;
  final String? body;
  final String? openUrl;
  final String? payloadJson;
  const _ItemInput({
    required this.externalId, required this.title,
    this.body, this.openUrl, this.payloadJson,
  });
}
```

- [ ] **Step 4: Run, verify pass**

Run: `flutter test test/notif/notif_bridge_test.dart -r expanded`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/notif/notif_bridge.dart test/notif/notif_bridge_test.dart
git commit -m "feat(notif): bridge list ops — createList, syncItems, getLists"
```

---

## Task 11: Bridge mutations — grade, setSchedule, setStatus, deleteList

**Files:**
- Modify: `lib/notif/notif_bridge.dart`
- Modify: `test/notif/notif_bridge_test.dart`

- [ ] **Step 1: Add the failing tests**

Append inside `main()` in `test/notif/notif_bridge_test.dart`:

```dart
  group('grade', () {
    test('Good advances step, records event, emits cupitorNotifGraded',
        () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'grade', 'request_id': 'r-g', 'external_key': 'fr-1',
        'item_external_id': 'c1', 'grade': 3,
      }));
      expect(lastAck()['ok'], true);
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      final c1 = (await dao.itemByExternalId(list.id, 'c1'))!;
      expect(c1.step, 1);
      expect(c1.lastGrade, 3);
      // offsets[1] = 1 wh from Mon 10:00 → 11:00.
      expect(c1.nextDueAt,
          tz.TZDateTime(ny, 2026, 7, 27, 11).millisecondsSinceEpoch);
      final ev = (await dao.lastEventForItem(c1.id))!;
      expect(ev.grade, 3);
      expect(ev.source, 'webpage');
      final graded = lastEvent('cupitorNotifGraded')!;
      expect(graded['item_external_id'], 'c1');
      expect(graded['grade'], 3);
      expect(graded['source'], 'webpage');
    });
    test('grade on recurring list → not_series', () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      await bridge.handle(jsonEncode({
        'op': 'grade', 'external_key': 'fr-1',
        'item_external_id': 'c1', 'grade': 3,
      }));
      expect(lastAck()['error'], 'not_series');
    });
    test('grade outside {1,3,5} → bad_grade', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'grade', 'external_key': 'fr-1',
        'item_external_id': 'c1', 'grade': 2,
      }));
      expect(lastAck()['error'], 'bad_grade');
    });
    test('unknown item → unknown_item', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'grade', 'external_key': 'fr-1',
        'item_external_id': 'zzz', 'grade': 3,
      }));
      expect(lastAck()['error'], 'unknown_item');
    });
  });

  group('setSchedule', () {
    test('recurring → series inits only items without series state',
        () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      final list = (await dao.listByExternalKey(1, 'fr-1'))!;
      // Simulate c1 having prior series state from an earlier stint.
      final c1 = (await dao.itemByExternalId(list.id, 'c1'))!;
      await dao.updateItem(c1.id, {'step': 5, 'next_due_at': 777});

      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'external_key': 'fr-1',
        'schedule_key': 'ebbinghaus',
      }));
      expect(lastAck()['ok'], true);

      final after = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(after.nextFireAt, isNull);
      final c1After = (await dao.itemByExternalId(list.id, 'c1'))!;
      expect(c1After.step, 5); // lossless: prior state kept
      expect(c1After.nextDueAt, 777);
      final c2After = (await dao.itemByExternalId(list.id, 'c2'))!;
      expect(c2After.step, 0); // no prior state: initialised
      expect(c2After.nextDueAt,
          tz.TZDateTime(ny, 2026, 7, 27, 10, 15).millisecondsSinceEpoch);
    });
    test('series → recurring sets next_fire_at, leaves item state', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'external_key': 'fr-1',
        'schedule_key': 'daily_0900',
      }));
      final after = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(after.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 28, 9).millisecondsSinceEpoch);
      final c1 = (await dao.itemByExternalId(after.id, 'c1'))!;
      expect(c1.nextDueAt, isNotNull); // unread but preserved
    });
    test('unknown schedule → unknown_schedule', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode({
        'op': 'setSchedule', 'external_key': 'fr-1', 'schedule_key': 'nope',
      }));
      expect(lastAck()['error'], 'unknown_schedule');
    });
  });

  group('setStatus', () {
    test('pause and resume; resume recomputes recurring next_fire_at',
        () async {
      await createFrenchList(scheduleKey: 'daily_0900');
      await bridge.handle(jsonEncode(
          {'op': 'setStatus', 'external_key': 'fr-1', 'status': 'paused'}));
      expect((await dao.listByExternalKey(1, 'fr-1'))!.status, 'paused');

      now = tz.TZDateTime(ny, 2026, 7, 30, 12); // resume days later
      await bridge.handle(jsonEncode(
          {'op': 'setStatus', 'external_key': 'fr-1', 'status': 'active'}));
      final l = (await dao.listByExternalKey(1, 'fr-1'))!;
      expect(l.status, 'active');
      expect(l.nextFireAt,
          tz.TZDateTime(ny, 2026, 7, 31, 9).millisecondsSinceEpoch);
    });
    test('bad status → bad_payload', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode(
          {'op': 'setStatus', 'external_key': 'fr-1', 'status': 'zzz'}));
      expect(lastAck()['error'], 'bad_payload');
    });
  });

  group('deleteList', () {
    test('deletes and pushes updated lists', () async {
      await createFrenchList();
      await bridge.handle(jsonEncode(
          {'op': 'deleteList', 'external_key': 'fr-1'}));
      expect(lastAck()['ok'], true);
      expect(await dao.listByExternalKey(1, 'fr-1'), isNull);
      expect(lastEvent('cupitorNotifLists')!['lists'], isEmpty);
    });
    test('unknown key → unknown_list', () async {
      await bridge.handle(jsonEncode(
          {'op': 'deleteList', 'external_key': 'zzz'}));
      expect(lastAck()['error'], 'unknown_list');
    });
  });
```

- [ ] **Step 2: Run, verify fail**

Run: `flutter test test/notif/notif_bridge_test.dart -r expanded`
Expected: new groups FAIL with `unknown_op`.

- [ ] **Step 3: Implement**

Add to the `switch` in `handle`:

```dart
        case 'grade':
          await _grade(reqId, m);
        case 'setSchedule':
          await _setSchedule(reqId, m);
        case 'setStatus':
          await _setStatus(reqId, m);
        case 'deleteList':
          await _deleteList(reqId, m);
```

Add the implementations (below `_getLists`):

```dart
  /// Shared list lookup with unknown_list ack.
  Future<NotifListRow?> _listOrAck(
      NotifDao d, String? reqId, String op, Object? key) async {
    final k = key as String?;
    if (k == null || k.isEmpty) {
      _ack(reqId, op, false, error: 'bad_payload');
      return null;
    }
    final list = await d.listByExternalKey(activeProfileId(), k);
    if (list == null) _ack(reqId, op, false, error: 'unknown_list');
    return list;
  }

  Future<void> _grade(String? reqId, Map<String, dynamic> m) async {
    const op = 'grade';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final itemExt = m['item_external_id'] as String?;
    final grade = (m['grade'] as num?)?.toInt();
    if (itemExt == null || itemExt.isEmpty) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    if (grade != gradeAgain && grade != gradeGood && grade != gradeEasy) {
      _ack(reqId, op, false, error: 'bad_grade');
      return;
    }
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    final schedule =
        list.scheduleId == null ? null : await d.scheduleById(list.scheduleId!);
    if (schedule == null || schedule.kind != 'series') {
      _ack(reqId, op, false, error: 'not_series');
      return;
    }
    final item = await d.itemByExternalId(list.id, itemExt);
    if (item == null) {
      _ack(reqId, op, false, error: 'unknown_item');
      return;
    }
    final offsets =
        seriesOffsets(jsonDecode(schedule.config) as Map<String, dynamic>);
    final t = now();
    final o = advanceSeries(
        step: item.step, done: item.status == 'done',
        offsetsWakingHours: offsets, now: t, grade: grade, window: window());
    await d.updateItem(item.id, {
      'step': o.step,
      'status': o.done ? 'done' : 'active',
      'next_due_at': o.nextDue?.millisecondsSinceEpoch,
      'last_grade': grade,
    });
    final nowMs = t.millisecondsSinceEpoch;
    // A webpage grade is review-without-fire; fired_at = responded_at keeps
    // the event usable for dedupe and the sweep (spec: notif_events).
    await d.insertEvent(
        itemId: item.id, firedAt: nowMs, respondedAt: nowMs,
        grade: grade, source: 'webpage');
    emit('cupitorNotifGraded', {
      'external_key': list.externalKey,
      'item_external_id': itemExt,
      'grade': grade,
      'source': 'webpage',
    });
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _setSchedule(String? reqId, Map<String, dynamic> m) async {
    const op = 'setSchedule';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    final schedule = await d.scheduleByKey((m['schedule_key'] as String?) ?? '');
    if (schedule == null) {
      _ack(reqId, op, false, error: 'unknown_schedule');
      return;
    }
    final w = window();
    final t = now();
    final config = jsonDecode(schedule.config) as Map<String, dynamic>;
    if (schedule.kind == 'recurring') {
      // Series → recurring: per-item state stays in place, unread (spec:
      // lossless round trip).
      await d.updateList(list.id, {
        'schedule_id': schedule.id,
        'next_fire_at': nextRecurringFire(parseRecurring(config), t, w)
            .millisecondsSinceEpoch,
      });
    } else {
      final offsets = seriesOffsets(config);
      await d.updateList(list.id, {'schedule_id': schedule.id, 'next_fire_at': null});
      for (final i in await d.itemsForList(list.id)) {
        // Only items with no series state get initialised — items that
        // carry state from an earlier stint keep it (spec: lossless).
        if (i.status == 'active' && i.nextDueAt == null) {
          await d.updateItem(i.id, {
            'step': 0,
            'next_due_at':
                addWakingHours(t, offsets[0], w).millisecondsSinceEpoch,
          });
        }
      }
    }
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _setStatus(String? reqId, Map<String, dynamic> m) async {
    const op = 'setStatus';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final status = m['status'] as String?;
    if (status != 'active' && status != 'paused') {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    final fields = <String, Object?>{'status': status};
    if (status == 'active' && list.scheduleId != null) {
      final schedule = await d.scheduleById(list.scheduleId!);
      if (schedule != null && schedule.kind == 'recurring') {
        // Resuming a recurring list re-anchors its fire time to now — the
        // stale pre-pause slot may be long past.
        fields['next_fire_at'] = nextRecurringFire(
                parseRecurring(jsonDecode(schedule.config) as Map<String, dynamic>),
                now(), window())
            .millisecondsSinceEpoch;
      }
    }
    await d.updateList(list.id, fields);
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _deleteList(String? reqId, Map<String, dynamic> m) async {
    const op = 'deleteList';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    await d.deleteList(list.id);
    _ack(reqId, op, true);
    await _afterMutation(d);
  }
```

- [ ] **Step 4: Run everything, verify pass**

Run: `flutter test test/notif/ -r expanded && flutter analyze lib/notif`
Expected: all PASS, no analyzer errors (the Task 9 unused imports are now used).

- [ ] **Step 5: Commit**

```bash
git add lib/notif/notif_bridge.dart test/notif/notif_bridge_test.dart
git commit -m "feat(notif): bridge mutations — grade, setSchedule, setStatus, deleteList"
```

---

## Task 12: `NotifSettings` + wiring into main.dart

**Files:**
- Create: `lib/notif/notif_settings.dart`
- Modify: `lib/main.dart` (init sequence near `PlaylistService.init()` at `lib/main.dart:365`; channel registration next to `PlaylistBridge` at `lib/main.dart:6592`; warm-push next to `_pushPlaylistsToDialog()` call at `lib/main.dart:6647`; helpers near `_pushPlaylistsToDialog` at `lib/main.dart:7747`)

- [ ] **Step 1: Create `NotifSettings`**

Create `lib/notif/notif_settings.dart`:

```dart
import 'package:shared_preferences/shared_preferences.dart';

import 'waking_clock.dart';

/// Global notification settings (spec: waking window default 05:00–22:00,
/// per-fire cap default 5). Cached statics because the bridge and (Plan 2)
/// the scheduler need synchronous reads; init() runs in the same startup
/// sequence as PlaylistService.init(). Prefs-unavailable → defaults stand,
/// matching the feature's self-disable posture.
class NotifSettings {
  NotifSettings._();
  static const _kWakeStart = 'notifWakeStart';
  static const _kWakeEnd = 'notifWakeEnd';
  static const _kPerFireCap = 'notifPerFireCap';

  static WakingWindow window = WakingWindow.defaults;
  static int perFireCap = 5;

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      window = WakingWindow.fromStrings(
        prefs.getString(_kWakeStart) ?? '05:00',
        prefs.getString(_kWakeEnd) ?? '22:00',
      );
      perFireCap = prefs.getInt(_kPerFireCap) ?? 5;
    } catch (_) {/* defaults stand */}
  }

  static Future<void> setWindow(String start, String end) async {
    window = WakingWindow.fromStrings(start, end);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kWakeStart, start);
      await prefs.setString(_kWakeEnd, end);
    } catch (_) {/* best effort */}
  }

  static Future<void> setPerFireCap(int cap) async {
    perFireCap = cap;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPerFireCap, cap);
    } catch (_) {/* best effort */}
  }
}
```

- [ ] **Step 2: Wire into `lib/main.dart`**

Add imports (the `tz`/`tzdata` ones exist since Task 1):

```dart
import 'notif/notif_bridge.dart';
import 'notif/notif_settings.dart';
```

In the init sequence containing `await PlaylistService.init();` (`lib/main.dart:365`), add directly after it:

```dart
    await NotifSettings.init();
```

Add the bridge field and helpers to the same `State` class that owns `dialogController` and `_handlePlaylistBridge`. Field, near the other dialog1 fields:

```dart
  // Language-app ↔ Cupitor bridge for the notification feature (spec:
  // docs/superpowers/specs/2026-07-27-notifications-design.md §Bridge).
  // Permission/exact-alarm/action capabilities are stubbed until the
  // delivery layer (Plan 2) supplies real ones through these callbacks.
  late final NotifBridge _notifBridge = NotifBridge(
    dao: () => CupitorDb.instance.notifDao(),
    activeProfileId: () => ProfileService.currentId,
    emit: _emitNotifEvent,
    capabilities: () async => NotifCapabilities(
      supported: await CupitorDb.instance.isReady(),
      permission: 'unknown',
      exactAlarms: false,
      actions: false,
      platform: defaultTargetPlatform.name,
    ),
    requestPermission: () async => 'unknown',
    window: () => NotifSettings.window,
    now: () => tz.TZDateTime.now(tz.local),
  );
```

Helpers, next to `_pushPlaylistsToDialog` (`lib/main.dart:7747`):

```dart
  /// Dispatch a notification-bridge CustomEvent into dialog1. Same
  /// global-then-dispatch pattern as _pushPlaylistsToDialog so a listener
  /// that attaches late can still read the current state.
  void _emitNotifEvent(String event, Map<String, Object?> detail) {
    final ctrl = dialogController;
    if (ctrl == null) return;
    final payload = jsonEncode(detail);
    final js = "window.__$event = $payload;"
        "window.dispatchEvent(new CustomEvent('$event', { detail: window.__$event }));";
    ctrl.runJavaScript(js).catchError((_) {/* dialog1 not loaded yet */});
  }

  /// Warm the language app with schedules + lists on page load, mirroring
  /// the playlist warm-push. Routed through the bridge's own ops so the
  /// payloads stay single-sourced; the stray acks are harmless.
  Future<void> _pushNotifStateToDialog() async {
    await _notifBridge.handle('{"op":"getSchedules"}');
    await _notifBridge.handle('{"op":"getLists"}');
  }
```

Register the channel, directly after the `PlaylistBridge` registration (`lib/main.dart:6592-6593`):

```dart
        // Language-app ↔ Cupitor bridge for the notification feature.
        // Ops + events: spec §Bridge. Acks via cupitorNotifAck.
        ..addJavaScriptChannel('NotifBridge',
            onMessageReceived: (msg) => _notifBridge.handle(msg.message))
```

Warm-push on page load — in `onPageFinished`, directly after the `_pushPlaylistsToDialog();` call (`lib/main.dart:6647`):

```dart
              _pushNotifStateToDialog();
```

If `defaultTargetPlatform` is unresolved, add `import 'package:flutter/foundation.dart';` (it's likely already imported).

- [ ] **Step 3: Full verification**

Run: `flutter analyze && flutter test test/notif/ -r expanded`
Expected: no new analyzer errors; all notif tests PASS. (Do not run `test/widget_test.dart` — pre-existing scaffold, untouched by this plan.)

- [ ] **Step 4: Manual smoke (only if a device/emulator is at hand — otherwise skip; Plan 2 exercises this end-to-end)**

Launch the app, open dialog1, and from the language page's console run:
`NotifBridge.postMessage(JSON.stringify({op:'getSchedules', request_id:'t1'}))`
Expected: a `cupitorNotifSchedules` CustomEvent with 7 schedules and a `cupitorNotifAck` with `ok:true`.

- [ ] **Step 5: Commit**

```bash
git add lib/notif/notif_settings.dart lib/main.dart
git commit -m "feat(notif): NotifBridge channel + settings wired into dialog1"
```

---

## Done — definition of complete for Plan 1

- `flutter test test/notif/` green: waking clock (incl. DST), schedules, series, recurring, v6→v7 migration, DAO, bridge (every op, every error code).
- `flutter analyze` clean of new issues.
- The webpage can: read capabilities + schedules, create/sync/re-schedule/pause/delete lists, grade items, and receives `cupitorNotifSchedules` / `cupitorNotifLists` / `cupitorNotifGraded` / `cupitorNotifAck` events.
- Nothing fires. Plan 2 (delivery: `notification_channel`, `notification_service.rearm()`, sweep, workmanager, platform manifests) and Plan 3 (manager UI) build on exactly these seams: `NotifDao.dueItems`, `NotifBridge.onMutated`, the capability callbacks, and `NotifSettings`.
