# Notifications — design

Date: 2026-07-27

## Purpose

Cupitor can already capture sentences and group them into lists. It cannot bring
them back to you. This feature adds scheduled local notifications that resurface
items over time, so review happens without the user remembering to open the app.

The language app inside dialog1 owns the items. Cupitor owns the schedules and the
delivery. The webpage registers a list and picks a schedule from a menu Cupitor
supplies; Cupitor stores a snapshot and notifies from it, independently, even when
the webpage is not loaded and the app is not running.

## Scope

In scope: a new notification item store, a scheduling engine with two schedule
kinds, seven built-in schedules, user-authored custom schedules, a JS bridge for
the webpage, OS-level scheduled delivery with offline grade actions, and an in-app
manager.

Out of scope: server-side push, notifying from the existing `playlists` or
`sentence_tags` stores, and any change to how dialog1 is opened or rendered.

## Terminology

- **Item** — one notifiable unit: title, optional body, optional open URL, and an
  opaque payload the webpage gets back verbatim.
- **List** — a named group of items with exactly one schedule.
- **Schedule** — a reusable config describing when to fire. Two kinds, below.
- **Waking hour** — an hour inside the user's waking window. All series intervals
  are measured in these, never wall-clock hours.
- **Step** — an item's index into its series' offset ladder.
- **Fire** — one moment at which one or more notifications are posted.

## Decisions

These were settled during brainstorming and the rest of the document assumes them.

1. Items are a **new store**, not the existing playlists or tags.
2. The webpage sends **full snapshots** and can **re-sync** them later.
3. Scheduling is **hybrid**: the schedule is chosen per list, but series schedules
   keep per-item state.
4. Series intervals are counted in **waking hours only**, default window
   05:00–22:00 local.
5. **Three series presets ship**, all selectable; Ebbinghaus-anchored is default.
6. A grade moves the item along the ladder (**Leitner on the ladder**); it does not
   switch the item to a different algorithm.
7. Grades come from **notification action buttons and the webpage**.
8. Two schedule kinds: **`recurring`** and **`series`**. Custom schedules are
   user-authored instances of either.
9. A fire posts **one notification per due item, grouped, capped** at 5 per fire.
10. Tap opens **dialog1 at a webpage-supplied URL**, with a fallback sheet.
11. All platforms are targeted. Desktop and web are **best-effort while running**.
12. Delivery is **hybrid**: pre-armed OS alarms everywhere, plus an Android worker
    and a shared catch-up sweep.
13. The in-app UI includes **full list authoring**, not just settings.

## Research basis for the series presets

The ladders are not invented. Sources:

- **Ebbinghaus (1885)** — forgetting is steepest in the first hours, so the first
  review must be soon and later ones can be far apart.
- **Pimsleur (1967), graduated interval recall** — 5s, 25s, 2m, 10m, 1h, 5h, 1d,
  5d, 25d, 4mo, 2y. Ratio ≈ 5×. Validated for vocabulary.
- **Wozniak, SM-0** — 1d, 7d, 16d, 35d. Ratio ≈ 2.2×.
- **Cepeda et al. (2008), "temporal ridgeline of optimal retention"** — the optimal
  gap is roughly 10–30% of the intended retention interval. This is the strongest
  single result to design against.
- **Caveat: Karpicke & Roediger (2007)** found expanding intervals are not reliably
  better than equal intervals once the first retrieval succeeds. The large effect
  is spacing at all, not the exact ratio. The presets are therefore deliberately
  simple and fixed; no adaptive ease factor is modelled.

With the default window, **1 day = 17 waking hours**. All three presets below are
expressed in waking hours.

### Preset: `ebbinghaus` (default)

```
step   waking-h   ≈
  1      0.25     15 min
  2      1        1 hour
  3      4        4 hours
  4     17        1 day
  5     51        3 days
  6    119        7 days
  7    272        16 days
  8    595        35 days
  9   1360        80 days
 10   3060        180 days
```
A Pimsleur-style intraday warm-up followed by the Wozniak day ladder. Ratio settles
around 2.2×. Ten notifications over ~6 months.

### Preset: `pimsleur`

```
0.03, 0.17, 1, 5, 17, 85, 425, 2040
≈ 2m, 10m, 1h, 5h, 1d, 5d, 25d, 4mo
```
Ratio ≈ 5×. Front-loaded; the first two steps fire while the user is likely still
holding the phone.

### Preset: `cepeda2x`

```
1, 2, 4, 8, 17, 34, 68, 136, 272, 544, 1088
≈ 1h, 2h, 4h, 8h, 1d, 2d, 4d, 8d, 16d, 32d, 64d
```
Plain doubling, closest to the Cepeda ridgeline. Best retention; roughly twice the
notification volume.

## Data model

Schema version **6 → 7**. The migration statement lives in `lib/db.dart` alongside
the existing version history; the query methods do not (see *Code layout*).

```sql
CREATE TABLE notif_schedules (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL,          -- 'recurring' | 'series'
  builtin_key TEXT UNIQUE,            -- non-null for built-ins, NULL for custom
  config      TEXT NOT NULL,          -- JSON, shape depends on kind
  created_at  INTEGER NOT NULL
);

CREATE TABLE notif_lists (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  profile_id   INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  source       TEXT NOT NULL,         -- 'webpage' | 'app'
  external_key TEXT,                  -- the webpage's own id; NULL for app-authored
  schedule_id  INTEGER REFERENCES notif_schedules(id),
  status       TEXT NOT NULL,         -- 'active' | 'paused'
  cursor       INTEGER NOT NULL DEFAULT 0,   -- round-robin ptr, recurring only
  next_fire_at INTEGER,               -- recurring only; NULL for series lists
  last_fired_at INTEGER,              -- recurring only; anchors interval configs
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  UNIQUE(profile_id, external_key)
);
CREATE INDEX idx_notif_lists_profile ON notif_lists(profile_id);

CREATE TABLE notif_items (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  list_id       INTEGER NOT NULL REFERENCES notif_lists(id) ON DELETE CASCADE,
  external_id   TEXT,                 -- the webpage's item id; NULL for app-authored
  title         TEXT NOT NULL,
  body          TEXT,
  open_url      TEXT,
  payload       TEXT,                 -- opaque JSON, echoed back verbatim
  position      INTEGER NOT NULL,
  step          INTEGER NOT NULL DEFAULT 0,   -- index into the series ladder
  next_due_at   INTEGER,              -- epoch ms; NULL = not scheduled
  last_fired_at INTEGER,
  last_grade    INTEGER,
  status        TEXT NOT NULL DEFAULT 'active',  -- 'active'|'suspended'|'done'
  created_at    INTEGER NOT NULL,
  UNIQUE(list_id, external_id)
);
CREATE INDEX idx_notif_items_due ON notif_items(next_due_at)
  WHERE status = 'active';

CREATE TABLE notif_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id      INTEGER NOT NULL REFERENCES notif_items(id) ON DELETE CASCADE,
  fired_at     INTEGER NOT NULL,
  responded_at INTEGER,
  grade        INTEGER,               -- 1 Again | 3 Good | 5 Easy
  source       TEXT                   -- 'action' | 'webpage' | 'auto'
);
CREATE INDEX idx_notif_events_item ON notif_events(item_id, fired_at);
```

`notif_events` earns its place three ways: dedupe (has this already fired?), the
catch-up sweep (what did we miss?), and the manager's per-item history.

`UNIQUE(list_id, external_id)` permits multiple NULL `external_id` rows in SQLite,
which is exactly what app-authored items need.

### `config` JSON by kind

```jsonc
// kind = 'series'
{ "offsets_waking_hours": [0.25, 1, 4, 17, 51, 119, 272, 595, 1360, 3060] }

// kind = 'recurring', clock-anchored
{ "times": ["09:00", "20:00"], "days": [1,2,3,4,5,6,7], "per_fire": 1 }

// kind = 'recurring', interval-based
{ "every_waking_hours": 4, "per_fire": 1 }
```

`days` uses ISO-8601 weekday numbering, Monday = 1. A `recurring` config carries
either `times`+`days` or `every_waking_hours`, never both; a config with both is
rejected at write time.

**Two different caps, do not confuse them.** `per_fire` is a property of one
recurring schedule: how many items that list pulls off its rotation each time it
fires. The global **per-fire cap** (default 5, in settings) is a device-wide ceiling
on how many notifications may be posted at one instant across *all* lists. A
recurring list with `per_fire: 8` still yields at most 5 notifications in that
moment if nothing else is competing; the remainder is not dropped, it is left
unarmed and picked up by the next `rearm()`.

### Built-in schedules

Seeded on migration, identified by `builtin_key`, never deleted by the user.

| builtin_key | kind | config |
|---|---|---|
| `ebbinghaus` | series | ladder above (default for new lists) |
| `pimsleur` | series | ladder above |
| `cepeda2x` | series | ladder above |
| `daily_0900` | recurring | `times:["09:00"], days:[1..7], per_fire:1` |
| `twice_daily` | recurring | `times:["09:00","20:00"], days:[1..7], per_fire:1` |
| `every_4_waking` | recurring | `every_waking_hours:4, per_fire:1` |
| `weekdays_0800` | recurring | `times:["08:00"], days:[1..5], per_fire:1` |

## Scheduling engine

Three pure modules with no Flutter binding and no I/O. This is where the bugs will
be, so they are isolated and directly unit-testable.

### `waking_clock.dart`

```dart
tz.TZDateTime addWakingHours(tz.TZDateTime from, double hours, WakingWindow w);
double        wakingHoursBetween(tz.TZDateTime a, tz.TZDateTime b, WakingWindow w);
bool          isAwake(tz.TZDateTime t, WakingWindow w);
tz.TZDateTime nextWakingInstant(tz.TZDateTime t, WakingWindow w);
```

The functions take `TZDateTime` from the `timezone` package, not bare `DateTime`.
Bare `DateTime` resolves local time against the host machine's zone, which would
make every DST test pass or fail depending on where it runs. `TZDateTime` carries
its `Location`, so a test can pin `America/New_York` and assert real DST behaviour
deterministically. The package is a dependency of `zonedSchedule` anyway.

Persisted times are absolute epoch milliseconds; conversion happens at the DB
boundary via `TZDateTime.fromMillisecondsSinceEpoch(location, ms)`.

The window is stored in prefs as `notifWakeStart` (default `05:00`) and
`notifWakeEnd` (default `22:00`), interpreted in the device's local timezone.

**Invariant: `addWakingHours` never returns an instant inside the sleep window.**
Deferring an overnight fire to morning therefore falls out of the arithmetic rather
than needing its own rule.

Required behaviour at the edges:

- **DST forward** — with the default window the transition (typically 02:00–03:00)
  falls inside the sleep window, so it consumes no waking hours at all: 20:00 the
  evening before plus 4 waking hours is 2h to the 22:00 boundary, then 2h from the
  05:00 resumption, landing at 07:00 wall-clock. With a window that *does* contain
  the transition, the skipped wall-clock hour is simply not available to spend.
- **DST backward** — the repeated wall-clock hour is available twice, so a fixed
  number of waking hours lands one wall-clock hour earlier than on a normal day.
- **Window crossing midnight** — e.g. wake 22:00, sleep 06:00. Supported.
- **Zero-length or inverted window** — treated as "always awake"; `addWakingHours`
  degenerates to plain addition. The settings UI prevents authoring one, but the
  function must not loop forever if the DB holds one.
- **Interval longer than one waking day** — the walk spans as many nights as needed.

### `series_scheduler.dart`

```dart
SeriesOutcome nextDue(NotifItem item, List<double> offsets,
                      DateTime now, int? grade, WakingWindow w);
```

| input | new step |
|---|---|
| no grade (auto-advance on fire with no response) | `step + 1` |
| grade 1 — Again | `0` |
| grade 3 — Good | `step + 1` |
| grade 5 — Easy | `step + 2` |

The new step clamps to `offsets.length - 1`. Advancing *past* the last index sets
`status = 'done'` and `next_due_at = NULL` — the item has graduated and stops
firing. `Again` on a graduated item resurrects it to step 0 and `status = 'active'`.

`next_due_at = addWakingHours(now, offsets[newStep], w)`.

The offsets ladder is the single source of truth for all three presets and for any
custom series; there is no second scheduling algorithm.

### `recurring_scheduler.dart`

```dart
DateTime nextFire(RecurringConfig cfg, DateTime after, WakingWindow w);
List<NotifItem> takeForFire(List<NotifItem> items, int cursor, int perFire);
```

Clock-anchored configs resolve to the next matching `times` × `days` slot strictly
after `after`. Interval configs resolve to `addWakingHours(after, every_waking_hours)`.

A clock-anchored time that falls inside the sleep window is a user authoring error;
the editor prevents it, and the engine defers such a fire to `nextWakingInstant`.

`takeForFire` returns `perFire` items starting at `cursor`, wrapping modulo the
active item count, and the caller advances the stored cursor by the number taken.
Items with `status != 'active'` are skipped without consuming a slot.

Recurring lists keep no per-item `step` or `next_due_at`; the fire time lives on the
list, in `next_fire_at`. Clock-anchored configs can recompute it from wall-clock
alone, but interval configs need an anchor, which is what `last_fired_at` provides —
without it, `every_4_waking_hours` would restart its count on every `rearm()`.

Switching a list from `recurring` to `series` initialises each active item that has
**no series state yet** (`next_due_at IS NULL`) to step 0 with
`next_due_at = addWakingHours(now, offsets[0])`; items that already carry series
state keep it. Switching from `series` to `recurring` leaves the per-item state in
place, unread. Together these make a round trip lossless — a blanket
reset-on-switch would contradict that.

## Bridge

Channel name `NotifBridge`, registered next to `PlaylistBridge` in `main.dart`. The
existing pattern — JS→Flutter over the channel, Flutter→JS via `CustomEvent` — is
followed exactly, with acks added because these operations can genuinely fail.

### Operations (JS → Flutter)

Every message is JSON with an `op` and an optional `request_id`.

| op | payload | notes |
|---|---|---|
| `getCapabilities` | — | replies `{supported, permission, exact_alarms, actions, platform}` |
| `requestPermission` | — | triggers the OS prompt |
| `getSchedules` | — | the schedule menu: 7 built-ins plus any custom |
| `createList` | `{external_key, name, schedule_key, items[]}` | |
| `syncItems` | `{external_key, items[], mode}` | `mode` = `merge` (default) or `replace` |
| `setSchedule` | `{external_key, schedule_key}` | |
| `setStatus` | `{external_key, status}` | `active` or `paused` |
| `deleteList` | `{external_key}` | |
| `grade` | `{external_key, item_external_id, grade}` | grade ∈ {1,3,5} |
| `getLists` | — | includes per-item `step` and `next_due_at` |

An item in `items[]`:

```jsonc
{
  "external_id": "card-4711",   // required, unique within the list
  "title":       "le dénouement",
  "body":        "the outcome, the unravelling",   // optional
  "open_url":    "https://…/review?card=4711",     // optional
  "payload":     { "any": "json" }                 // optional, echoed verbatim
}
```

`schedule_key` is a `builtin_key` for built-ins, or `custom:<id>` for user-authored
ones — both forms appear in the `getSchedules` payload, so the webpage never needs
to know the difference.

### Events (Flutter → JS)

| event | detail |
|---|---|
| `cupitorNotifSchedules` | the schedule menu |
| `cupitorNotifLists` | lists + items + due state; also pushed unprompted on any mutation |
| `cupitorNotificationOpened` | `{external_key, item_external_id, payload}` |
| `cupitorNotifGraded` | `{external_key, item_external_id, grade, source}` |
| `cupitorNotifAck` | `{request_id, op, ok, error?, data?}` |

`data` carries the reply for ops that return a value rather than push a payload
event: `getCapabilities` and `requestPermission` answer through it.

`cupitorNotifGraded` exists so an action-button grade does not silently desync the
webpage's own view of the item.

Unprompted pushes mirror `_pushPlaylistsToDialog`: the payload is assigned to a
`window.__cupitorNotif*` global and then dispatched, so a listener that attaches
late can still read the current state.

### Identity

The webpage addresses everything by `external_key` and `external_id`. Internal row
ids never cross the bridge — the same rule `PlaylistService.buildPayload` already
follows.

### `syncItems` semantics

- **`merge`** (default) — items matched by `external_id` have `title`, `body`,
  `open_url`, `payload` and `position` updated, and **keep `step`, `next_due_at`,
  `status` and their event history**. Correcting a typo must not wipe three weeks of
  spaced-repetition progress. Unknown `external_id`s are inserted at step 0 with
  `next_due_at = addWakingHours(now, offsets[0])`. Items absent from the payload are
  left untouched.
- **`replace`** — as merge, plus items absent from the payload are deleted and their
  pending notifications cancelled.

### Failure posture

Malformed JSON, an unknown `op`, an unknown `external_key`, an unknown
`schedule_key`, or a grade outside {1,3,5} produces an ack with `ok:false` and a
machine-readable `error` code, and changes nothing. The full code set:
`bad_json`, `unknown_op`, `bad_payload`, `unknown_list`, `unknown_item`,
`unknown_schedule`, `duplicate_key` (`createList` on an `external_key` that
already exists — use `syncItems` to update), `bad_grade`, `not_series` (`grade`
against a list whose schedule is `recurring`), `unsupported`, `internal`. The handler never throws into
the channel. If SQLite is unavailable the whole feature answers
`getCapabilities` with `supported:false` — the self-disable contract `CupitorDb`
already uses.

## Delivery

### Packages

- `flutter_local_notifications` — Android, iOS, macOS, Linux, including action
  buttons that work while the app is killed.
- `timezone` — required by `zonedSchedule`, and by the waking-hour engine above.
  Added in the first slice, not the delivery slice.
- `sqflite_common_ffi` (dev) — in-memory SQLite for DAO and migration tests.
- `workmanager` — the Android safety net.
- Windows and web get a shim over an in-process timer; lowest-priority slice.

### `notification_channel.dart`

The only file that imports a notification package. Surface: `init()`,
`permissionStatus()`, `requestPermission()`, `arm(fire)`, `cancel(id)`,
`cancelAll()`, plus the tap and action callbacks. Everything above it is testable
against a fake implementation of this interface.

### Arming — `notification_service.dart`

One entry point, `rearm()`:

1. Cancel all feature-owned pending notifications.
2. Select items whose `next_due_at` falls inside the window, plus computed fire
   times for active `recurring` lists.
3. Bucket by minute and apply the per-fire cap (default 5). Overflow is not dropped;
   it simply is not armed, and the next `rearm()` picks it up.
4. `zonedSchedule` each one with a **stable notification id derived from the item
   id**, which makes cancel-and-re-arm idempotent.

Window: the next 48 hours, capped at **60 armed notifications on iOS** — headroom
under the platform's hard limit of 64 — and 200 on Android.

Re-arm triggers: app resume, `BOOT_COMPLETED`, any fire, any grade, any bridge
mutation, a waking-window or cap settings change, and each worker tick.

### The sweep

```dart
Future<void> sweep(DateTime now);
```

Finds items whose `next_due_at` has passed with no `notif_events` row at or after
it. Each is either posted immediately, if within a **2-waking-hour grace window**,
or auto-advanced along the ladder with an event recorded as `source:'auto'` and
`responded_at:null` if staler than that.

One function, three callers: the Android worker, app launch, and the desktop/web
timer. The per-fire cap applies here too, so returning after a long absence
produces a handful of notifications rather than a hundred.

### Platform specifics

**Android.** Requires `POST_NOTIFICATIONS` (API 33+) and
`SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` (API 31+). If exact alarms are denied, fall
back to `AndroidScheduleMode.inexactAllowWhileIdle` and report
`exact_alarms:false`, so the UI can honestly say "timing approximate" instead of
drifting silently. Notifications carry a per-list group key plus a summary row. A
`BOOT_COMPLETED` receiver re-arms after reboot. Action buttons use
`showsUserInterface:false` with a `@pragma('vm:entry-point')` background handler, so
grading never opens the app. A periodic `workmanager` job re-arms and sweeps.

**iOS / macOS.** A `UNNotificationCategory` carries the three actions. The
60-notification arming window respects the 64-pending cap. No background worker —
`BGAppRefreshTask` is too opportunistic to rely on; app-launch sweep covers it.

**Windows / web.** A `Timer` to the nearest `next_due` runs the sweep and posts.
No action buttons; `getCapabilities` reports `actions:false`. Grading happens only
via the webpage or the in-app UI.

**Linux.** Covered by `flutter_local_notifications`, but with the same
best-effort-while-running caveat as Windows: no OS wake.

## In-app UI

Reached from the same Tools surface as `playlist_screen.dart`.

- **`notification_manager.dart`** — global settings (waking window, per-fire cap,
  link to custom schedules) and the list index showing each list's schedule, item
  count, next fire, and active/paused state.
- **`notif_list_screen.dart`** — items with step and next-due, reset-to-step-1,
  add/edit/remove items, pause, change schedule, delete list. This screen is also
  where app-authored lists are created, so the feature is usable without the
  webpage.
- **`schedule_editor.dart`** — custom schedule authoring: pick a kind, then either
  times + days, or an interval, or an offsets ladder. Validation blocks a
  clock-anchored time inside the sleep window, an empty ladder, non-increasing
  offsets, and an inverted waking window.

Built-in schedules are visible and clonable but not editable; cloning produces a
custom schedule.

## Error handling

The governing rule is the existing one: **self-disable, never crash.**

| condition | behaviour |
|---|---|
| SQLite unavailable | `supported:false`; UI shows a notice; bridge acks fail cleanly |
| Notification permission denied | Lists persist, nothing arms. Manager shows a banner with a settings deep-link; `getCapabilities` reports it |
| Exact-alarm permission denied (Android) | Fall back to inexact; report `exact_alarms:false` |
| Item deleted while armed | Cancelled by stable id on delete; the sweep also reaps orphans |
| Timezone or clock change | `rearm()` on app resume recomputes from stored `next_due_at`, which is absolute epoch ms and therefore unaffected |
| Schedule deleted while lists use it | Blocked; the editor requires reassigning those lists first |
| Ladder exhausted | `status='done'`, stops firing, remains visible in the manager |

## Testing

Most of this needs no Flutter binding, which is the point of keeping the engines
pure.

**Unit — `waking_clock`.** DST forward and backward, a window crossing midnight, a
zero-length and an inverted window, instants exactly on a boundary, and intervals
spanning several nights.

**Unit — `series_scheduler`.** Every grade path, clamping at the last index,
transition to `done`, and resurrection of a `done` item by `Again`.

**Unit — `recurring_scheduler`.** Clock anchoring, day filters, cursor wraparound,
skipping non-active items, and a configured time inside the sleep window.

**DAO — `sqflite_common_ffi` in memory.** CRUD, cascade deletes, and **the v6→v7
migration run against a real v6 fixture database**, asserting existing playlist and
sentence data survives and the built-ins are seeded exactly once.

**Bridge.** Raw JSON strings fed to the handler; assert the ack and the resulting DB
state. Covers every failure code. No webview involved.

**Service.** A fake `NotificationChannel`; assert exactly which ids are armed at
which instants, that the cap holds, that `rearm()` twice in a row is idempotent, and
that `sweep` posts inside the grace window and auto-advances outside it.

**Manual only.** Permission prompts, reboot re-arm, Doze behaviour, action buttons
while the app is killed, and the iOS 64-notification ceiling under load.

## Code layout

```
lib/notif/
  waking_clock.dart          pure
  schedules.dart             built-in defs, config parse + validate
  series_scheduler.dart      pure
  recurring_scheduler.dart   pure
  notif_dao.dart             class NotifDao(Database) — no path_provider
  notification_service.dart  rearm / fire / sweep
  notification_channel.dart  the only file importing a notification package
  notif_bridge.dart          JS channel handler
  notification_manager.dart  UI: settings + list index
  notif_list_screen.dart     UI: list detail + authoring
  schedule_editor.dart       UI: custom schedules
```

The v6→v7 migration statement goes in `lib/db.dart`, where the schema version and
its history already live. The roughly 400 lines of new queries do not: `db.dart` is
already 1684 lines, so the DAO lives in its own file.

`NotifDao` takes a `Database` in its constructor rather than being an extension on
`CupitorDb`. `CupitorDb._open()` calls `getApplicationDocumentsDirectory()`, which
does not exist in a unit test; a DAO that reaches through it could only be tested
under a widget-test harness with a mocked path_provider channel. Taking the handle
directly lets every DAO test run against `sqflite_common_ffi` in memory.
`CupitorDb` exposes one accessor, `Future<NotifDao?> notifDao()`, honouring the same
null-if-unavailable contract as `rawDb()`.

For the same reason, `db.dart`'s inline `onCreate` and `onUpgrade` closures are
extracted to `static Future<void> createSchema(Database)` and
`static Future<void> runMigrations(Database, int oldV, int newV)`. Without that, the
v6→v7 migration cannot be tested at all — the logic is unreachable except through a
real device path. This is a targeted refactor of code the feature is modifying
anyway, not a general restructuring of `db.dart`.

A subdirectory is used rather than the flat `lib/` root because this is eleven new
files.

## Build order

1. Schema v7 + the three pure engines + their tests. No UI, no OS calls.
2. DAO + bridge + acks. The webpage can drive the whole model; nothing fires yet.
3. `flutter_local_notifications` wiring: arm, cancel, tap → dialog1. Android first.
4. Action buttons + the background grading handler.
5. Android `workmanager` + `sweep`; the desktop/web timer path.
6. Manager UI, list screen, schedule editor.
7. iOS/macOS pass: categories, the 60-notification window, permission flow.

Each slice is independently shippable; the feature is inert but harmless until
slice 3.
