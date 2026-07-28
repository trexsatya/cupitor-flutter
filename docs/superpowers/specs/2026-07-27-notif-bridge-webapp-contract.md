# NotifBridge — webapp integration contract

Audience: the webpage loaded in dialog1. This is the complete, frozen surface
for driving Cupitor's notification feature from JS. It matches the shipped
implementation (`lib/notif/notif_bridge.dart`, 147 tests) — if this document
and the app disagree, the app wins and this doc has a bug.

## Transport

**JS → Flutter** — one JS channel, message is a JSON *string*:

```js
NotifBridge.postMessage(JSON.stringify({ op: 'getLists', request_id: 'r1' }));
```

**Flutter → JS** — `CustomEvent`s on `window`. Every payload is also assigned
to a `window.__<eventName>` global *before* dispatch, so a listener that
attaches late can read current state immediately:

```js
window.addEventListener('cupitorNotifLists', e => render(e.detail));
// late-attach catch-up:
if (window.__cupitorNotifLists) render(window.__cupitorNotifLists);
```

Every message you send gets exactly one `cupitorNotifAck` back:

```jsonc
{ "request_id": "r1", "op": "getLists", "ok": true }
// or
{ "request_id": "r1", "op": "createList", "ok": false, "error": "duplicate_key" }
// ops that answer with a value use data:
{ "request_id": "r1", "op": "getCapabilities", "ok": true, "data": { ... } }
```

`request_id` is optional and echoed verbatim (string only — anything else is
treated as absent). Unparseable JSON acks `{request_id: null, op: 'unknown',
ok: false, error: 'bad_json'}`. The handler never throws into the channel.

On dialog load the app warm-pushes `cupitorNotifSchedules` and
`cupitorNotifLists` unprompted (with harmless stray acks that carry no
`request_id` you issued — ignore acks whose `request_id` you don't recognise).

## Operations

| op | payload fields | ok reply |
|---|---|---|
| `getCapabilities` | — | ack `data: {supported, permission, exact_alarms, actions, platform}` |
| `requestPermission` | — | ack `data: {permission}` (triggers the OS prompt) |
| `getSchedules` | — | `cupitorNotifSchedules` event, then ack |
| `getLists` | — | `cupitorNotifLists` event, then ack |
| `createList` | `external_key`, `name`, `schedule_key?` (default `'ebbinghaus'`), `intro_schedule_key?`, `open_url?`, `items[]` | ack, then `cupitorNotifLists` push |
| `syncItems` | `external_key`, `items[]`, `mode?` (`'merge'` default \| `'replace'`), `open_url?` | ack, then push |
| `setSchedule` | `external_key`, `schedule_key`, `intro_schedule_key?` | ack, then push |
| `setStatus` | `external_key`, `status` (`'active'` \| `'paused'`) | ack, then push |
| `deleteList` | `external_key` | ack, then push |
| `grade` | `external_key`, `item_external_id`, `grade` (literal int 1\|3\|5) | ack, then `cupitorNotifGraded` + push |
| `getNotifications` | `limit?` (int 1–200, default 50) | `cupitorNotifFeed` event, then ack |
| `ackItem` | `external_key`, `item_external_id` | ack (marks ALL of the item's unread fires as seen, no grading; idempotent) |

An entry in `items[]`:

```jsonc
{
  "external_id": "card-4711",   // REQUIRED, non-empty, unique within the list
  "title":       "le dénouement", // REQUIRED, non-empty
  "body":        "the outcome",             // optional
  "open_url":    "https://…?card=4711",     // optional — where the app opens dialog1 on tap
  "payload":     { "any": "json" }          // optional, stored and echoed verbatim
}
```

`items[]` is validated **atomically**: one missing/empty `external_id` or
`title`, or one duplicate `external_id`, rejects the whole op with
`bad_payload` and changes nothing.

**Text length:** the app stores `title`/`body` unlimited (SQLite TEXT), but
the OS truncates what a notification shows — Android caps each field at
1024 chars and displays far less (title ~1 line, body 1–2 lines collapsed);
iOS banners show ~1–2 lines. Recommended: title ≤ 50 chars, body ≤ 240.
Full text is always visible in the app's manager UI regardless.

### Identity rules

You address everything by your own `external_key` (list) and `external_id`
(item). Internal row ids never cross the bridge. Keys are scoped to the
active profile. `createList` on an existing `external_key` acks
`duplicate_key` — use `syncItems` to update.

### `grade` semantics

1 = Again (back to step 0; also resurrects a `done` item), 3 = Good (+1
step), 5 = Easy (+2 steps). Grading past the last ladder rung sets the item
to `done`. `grade` must be a literal JSON integer — `3.5` or `"3"` is
`bad_grade`. Grading a list on a recurring schedule acks `not_series`.

### `syncItems` semantics

- **merge** (default): items matched by `external_id` update `title`, `body`,
  `open_url`, `payload`, `position` and **keep** `step`, `next_due_at`,
  `status`, and history — a typo fix never wipes SRS progress. Unknown
  `external_id`s are inserted at step 0. Items absent from the payload stay.
- **replace**: as merge, plus items absent from the payload are deleted (their
  pending notifications are cancelled).

Item order in `items[]` becomes `position`.

### Intro cadence (`intro_schedule_key`, optional)

A series list may additionally carry a recurring **introduction schedule**:
items then fire for the FIRST time on that cadence (in `position` order,
`per_fire` at a time) instead of all together, and each item's
spaced-repetition ladder starts at its own introduction. Example:
`schedule_key: 'ebbinghaus'` + `intro_schedule_key: 'daily_0900'` introduces
one new item every morning; each introduced item then repeats at
+0.25, +1, +4… waking hours from its introduction.

Rules:
- `intro_schedule_key` must reference a **recurring** schedule and the main
  `schedule_key` must be a **series** — anything else acks `bad_intro`.
- With an intro set, new items (from `createList` or `syncItems`) arrive
  with `next_due_at: null` — that state means "queued for introduction".
- The cadence goes dormant when every item has been introduced and wakes
  automatically when `syncItems` adds new ones.
- `setSchedule` sets the list's FULL scheduling: omitting
  `intro_schedule_key` **clears** any existing intro (remaining queued items
  are then seeded immediately, i.e. the no-intro behavior).
- `grade` on a not-yet-introduced item is allowed and introduces it early.
- `getLists` exposes the current value as `intro_schedule_key` (null when
  none).

### `setSchedule` semantics (lossless round trip)

- → recurring: per-item SRS state stays in place, unread.
- → series: only items with **no** series state (`next_due_at == null`) are
  initialised to step 0; items carrying state keep it.

Pausing keeps everything frozen; resuming a recurring list re-anchors its
next fire to now.

## Events (Flutter → JS)

| event | detail | when |
|---|---|---|
| `cupitorNotifSchedules` | `{version: 1, schedules: [...]}` | `getSchedules`, dialog warm-push |
| `cupitorNotifLists` | `{version: 1, lists: [...]}` | `getLists`, after **every** successful mutation (yours or the in-app manager UI's), dialog warm-push |
| `cupitorNotifAck` | `{request_id, op, ok, error?, data?}` | once per message you send |
| `cupitorNotifGraded` | `{external_key, item_external_id, grade, source}` | any grade: `source` ∈ `'webpage'` \| `'action'` (notification button) \| `'auto'` |
| `cupitorNotificationOpened` | `{external_key, item_external_id, payload}` | user tapped a notification body; dialog1 is opened at the item's `open_url` first |
| `cupitorNotifFeed` | `{version: 1, notifications: [...]}` | `getNotifications`, dialog warm-push, and refreshed after every sweep while the page is open |

Deep-link resolution on tap: the item's own `open_url` wins, else the
**list-level `open_url`** (set it once on `createList`, or via `syncItems` —
present-string updates it, explicit `null` clears it, absent leaves it), else
no navigation. Prefer the list-level field when the link is the same for
every item — don't repeat it per item.

When a tap navigates (any `open_url` resolved), the page reloads —
`cupitorNotificationOpened` is delivered again AFTER the new page finishes
loading, so you can rely on the event in both patterns; with `open_url` you
can also read your own URL params. With no `open_url` at all, no reload
happens and the live page just gets the event — best for SPA view switching.

`cupitorNotifGraded` with `source:'action'` is how you learn about grades made
from notification buttons while your page wasn't looking; a grade made while
the app was killed arrives via the warm-push state on next launch instead.

### Schedule menu shape

```jsonc
{ "version": 1, "schedules": [
  { "key": "ebbinghaus", "name": "Ebbinghaus-anchored", "kind": "series",
    "builtin": true,
    "config": { "offsets_waking_hours": [0.25,1,4,17,51,119,272,595,1360,3060] } },
  { "key": "daily_0900", "name": "Daily 09:00", "kind": "recurring",
    "builtin": true,
    "config": { "times": ["09:00"], "days": [1,2,3,4,5,6,7], "per_fire": 1 } },
  { "key": "custom:12", "name": "My ladder", "kind": "series", "builtin": false,
    "config": { "offsets_waking_hours": [1,4,17] } }
] }
```

Pass any `key` back as `schedule_key` — you never need to distinguish builtin
from custom. The 7 built-ins: `ebbinghaus`, `pimsleur`, `cepeda2x` (series);
`daily_0900`, `twice_daily`, `every_4_waking`, `weekdays_0800` (recurring).
Series offsets are **waking hours** (sleep window excluded; default waking
window 05:00–22:00, user-configurable in the app). Custom schedules are
authored in the app's UI, not over the bridge.

### Lists payload shape

```jsonc
{ "version": 1, "lists": [
  { "external_key": "deck-fr-1", "name": "French B2", "source": "webpage",
    "schedule_key": "ebbinghaus", "intro_schedule_key": null,
    "status": "active", "next_fire_at": null,
    "items": [
      { "external_id": "card-4711", "title": "le dénouement", "body": "…",
        "open_url": "…", "payload": { }, "position": 0,
        "step": 2, "next_due_at": 1785157465135, "status": "active" }
    ] }
] }
```

- `next_due_at` / `next_fire_at` are epoch **milliseconds** (or null).
- item `status`: `active` | `suspended` | `done` (`done` = ladder finished;
  grade 1 resurrects).
- Lists created in the app's own UI have `source: 'app'` and
  `external_key: null` — show or ignore them as you like; you can't address
  them by key.

### Notification feed (`cupitorNotifFeed`)

A flat, newest-first stream of fire events — build a YouTube-style bell
inbox from it (group by `external_key`/`list_name` client-side if you like;
this also sidesteps OS notification grouping entirely). An entry with
`responded_at: null` is **unacknowledged** — the OS notification may have
been missed or dismissed, so surface it in the page.

```jsonc
{ "version": 1, "notifications": [
  { "external_key": "deck-fr-1", "list_name": "French B2",
    "item_external_id": "card-4711", "title": "le dénouement",
    "body": "the outcome", "step": 2, "item_status": "active",
    "fired_at": 1785157465135,
    "responded_at": null,          // null ⇒ unacknowledged
    "grade": null,                 // 1|3|5 when the response was a grade
    "source": null }               // null = posted fire | 'auto' (silent
                                   // catch-up advance — never shown by the
                                   // OS, i.e. a MISSED review) | 'action'
                                   // (notification button) | 'webpage'
] }
```

Acknowledging: a `grade` op, a notification tap, or an explicit `ackItem`
(mark-read without grading) all stamp `responded_at` — on EVERY entry of
that item that is still unread, not just the latest, so one response can
never leave an older entry permanently unread. The feed is pushed
unprompted on dialog load and after every sweep, so new fires appear while
the page is open without polling. Entries from app-authored lists have
`external_key: null` — display-only (they can't be addressed by `ackItem`).

## Error codes

`bad_json`, `unknown_op`, `bad_payload`, `unknown_list`, `unknown_item`,
`unknown_schedule`, `duplicate_key`, `bad_grade`, `not_series`,
`bad_intro` (intro on a recurring main schedule, or a series schedule used
as intro), `unsupported` (SQLite unavailable on this platform — also
visible as `getCapabilities → supported:false`), `internal` (nothing
committed). Failed ops change nothing.

## Capabilities

```jsonc
{ "supported": true,        // false ⇒ hide the whole feature
  "permission": "granted",  // 'granted' | 'denied' | 'unknown'
  "exact_alarms": true,     // Android: false ⇒ timing is approximate
  "actions": true,          // false (Windows/web) ⇒ no grade buttons on notifications
  "platform": "android" }
```

Recommended boot sequence: `getCapabilities` → if `supported` and permission
not `granted`, offer a button that sends `requestPermission` → rely on the
warm-pushed `cupitorNotifSchedules`/`cupitorNotifLists` (or request them).

## Minimal wrapper

```js
const notif = (() => {
  let n = 0;
  const pending = new Map();
  window.addEventListener('cupitorNotifAck', e => {
    const a = e.detail;
    const p = pending.get(a.request_id);
    if (!p) return;                    // stray warm-push ack — ignore
    pending.delete(a.request_id);
    a.ok ? p.resolve(a.data ?? true) : p.reject(new Error(a.error));
  });
  return (op, payload = {}) => new Promise((resolve, reject) => {
    const request_id = `wa-${++n}`;
    pending.set(request_id, { resolve, reject });
    NotifBridge.postMessage(JSON.stringify({ op, request_id, ...payload }));
  });
})();

// usage
await notif('createList', {
  external_key: 'deck-fr-1', name: 'French B2', schedule_key: 'ebbinghaus',
  items: [{ external_id: 'card-4711', title: 'le dénouement' }],
});
await notif('grade', { external_key: 'deck-fr-1',
                       item_external_id: 'card-4711', grade: 3 });
```
