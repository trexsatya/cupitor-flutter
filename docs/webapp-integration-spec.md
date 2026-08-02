# Cupitor ↔ Language WebApp Integration Spec

**Status**: stable · **Owner**: Cupitor host app · **Audience**: the language webapp developer (Vue3 app under `cupitor-frontend/public/language/`)

This document is the contract between the Cupitor host (Flutter) and the language webapp (dialog1). If you're building a page that runs inside dialog1 and needs to talk to the host, everything you need is here — bridges, events, data shapes, timing rules.

---

## 1. Overview

The language webapp loads inside a **Flutter WebView** the host calls `dialog1`. The host injects polyfills and JavaScript channels on every navigation, then hands over control. From the webapp's point of view:

- **Send a request to the host** → call `Bridge.postMessage(JSON.stringify({...}))` on a named channel.
- **Receive a push from the host** → listen for a `CustomEvent` on `window`.

There is no shared JS runtime — the webapp does not `import` Cupitor code, and the host never `eval`s webapp code. All communication is through the bridges below.

**Where the webapp lives on disk (dev)**: `/Users/satyendra.kumar/Documents/PersonalProjects/cupitor/frontend/vue3/cupitor-frontend/public/language/`

---

## 2. Runtime & Loading

| Property | Value |
|---|---|
| Container | Flutter WebView (`webview_flutter` v4 / Android `webview_flutter_android`) |
| Platforms | Android (primary), iOS/macOS (secondary) |
| JS mode | `JavaScriptMode.unrestricted` |
| Cookies | Third-party enabled |
| User agent | Custom (Cupitor-branded UA — Chromium under the hood on Android) |
| Autoplay | Depending on page — host injects autounmute for YouTube |
| Fetch / XHR | Full network access, no host proxy |
| Storage | localStorage / IndexedDB persist across sessions until app data is cleared |

**Lifecycle**: dialog1 is a WebView that opens on top of the main app for lookups. It may load, unload, and re-load repeatedly during one host session. Bridges rebind on every navigation; **never assume a bridge is available until `onload` (or later) has fired**.

Any code that relies on bridges must guard:
```js
if (window.PlaylistBridge && typeof window.PlaylistBridge.postMessage === 'function') { ... }
```

---

## 3. JS → Dart Channels

Each channel is a global object with a single method: `postMessage(payload: string)`. Payloads are always JSON-encoded strings. Non-JSON payloads are silently dropped.

### 3.1 `PlaylistBridge`

Playlist + book library + full-text search — the highest-value bridge for the language webapp.

**Op: `getPlaylists`**  
Ask the host to (re-)push the current playlist state.
```js
PlaylistBridge.postMessage(JSON.stringify({ op: 'getPlaylists' }));
// → CustomEvent 'cupitorPlaylists' arrives with { playlists, items }
```

**Op: `openEpub`**  
Close dialog1 and open a book in the EPUB reader at a given chapter. The book must already be in the user's library on this device (matched by SHA-1). If it isn't, the host shows a snackbar and stays put.
```js
PlaylistBridge.postMessage(JSON.stringify({
  op: 'openEpub',
  book_key: '3f2c9b…40char sha1',
  chapter_idx: 12,        // 0-based; clamped to book length by host
  match: 'phrase',        // optional — see "Highlight on open" in §5.4
}));
```

**Op: `globalSearch`** *(streams results — see §5)*  
Full-text search across every EPUB in the user's library. Hits are dispatched incrementally as `cupitorGlobalSearchResults` events (delta batches), followed by a final closing event.
```js
PlaylistBridge.postMessage(JSON.stringify({
  op: 'globalSearch',
  query: 'cat|dog',      // see §5 for the query grammar
}));
// Sometime later, many times:
window.addEventListener('cupitorGlobalSearchResults', (ev) => {
  const { query, hits, done, hits_capped, cancelled } = ev.detail;
  // hits is a DELTA — append to your local accumulator
});
```
Starting a new `globalSearch` implicitly cancels any prior one — the client typically ignores stale results by keying on `ev.detail.query`.

**Op: `cancelSearch`**  
Cancel the current in-flight search. The host emits a final event with `done: true, cancelled: true` — no more hits will follow. No payload:
```js
PlaylistBridge.postMessage(JSON.stringify({ op: 'cancelSearch' }));
```

### 3.2 `AudioBridge`

Persist and retrieve manual-card voice recordings. Files live under `<app_documents>/manual_audio/<id>.<ext>` on the device; the host picks the extension based on OS support (Android 10+ writes `.ogg`/Opus, older Androids `.m4a`/AAC-LC — see §7.3).

Every op includes an `rid` (request id) the caller supplies. The host echoes it back so callers can resolve the matching `Promise`. Convention: any short unique string is fine (`Date.now().toString()` works).

```ts
type AudioReply = {
  op: string;         // same as the request
  rid: string;
  result?: string;    // op-specific — a file:// URL, dataUrl, or 'ok'
  error?: string;     // 'not-found' | 'permission-denied' | ...
};
```

Replies arrive via `window.__cupAudio(reply)`. Set that up first:
```js
window.__cupAudio = function(reply) {
  const p = pending[reply.rid];
  if (!p) return;
  delete pending[reply.rid];
  reply.error ? p.reject(reply.error) : p.resolve(reply.result);
};
```

| op | payload | result |
|---|---|---|
| `save` | `{id, dataUrl}` — data URL from a MediaRecorder blob | `file://…` URL |
| `load` | `{url}` — file URL previously returned | `data:audio/<mime>;base64,…` |
| `delete` | `{url}` | `'ok'` (idempotent — missing file is not an error) |
| `ensureMicPerm` | `{}` | `'granted'` or `'denied'` |
| `recordStart` | `{id}` | `file://…` URL where the clip will land |
| `recordStop` | `{}` | `file://…` URL of the finished clip, or `null` if too short |
| `recordCancel` | `{}` | `'ok'` |

Notes:
- Only one native recording at a time — a second `recordStart` while another is live returns `error: 'BUSY'`.
- `save` is the legacy path (JS `MediaRecorder` blob → base64 → host). Prefer `recordStart` / `recordStop` — the host writes directly with `MediaRecorder`, bypasses `getUserMedia`, and uses the smaller Opus codec on Android 10+.
- The host will call `ensureMicPerm` implicitly on `recordStart` — no need to call it first, but you can if you want to know before showing UI.

### 3.3 `NotifBridge`

Manual-card scheduling / reminders. Ops (see [notif_bridge.dart](../lib/notif/notif_bridge.dart) for shapes):
- `getCapabilities` — feature flags (whether notifications are supported, permission state)
- `requestPermission` — trigger the OS permission prompt
- `getSchedules` / `setSchedule` — per-list reminder cadence
- `getLists` / `createList` / `deleteList`
- `syncItems` — hand the host a list snapshot to persist
- `getNotifications` / `ackItem` / `grade` — mark items reviewed / graded
- `setStatus` — pause / resume notifications for a list

Every op is acked via a `cupitorNotifAck` CustomEvent carrying the ack payload.

### 3.4 `TtsBridge`

Polyfill for `window.speechSynthesis` — Android WebView does not implement Web Speech Synthesis natively. The host intercepts `speak()` calls and routes them through the `flutter_tts` plugin. You almost never call this directly — `window.speechSynthesis.speak(...)` just works.

### 3.5 `MediaState`

Report media playback state (playing / paused / current title / artist) so the host can drive the OS MediaSession (lock screen widget, headset controls).
```js
MediaState.postMessage(JSON.stringify({ playing: true, title: 'Track A', artist: 'X' }));
```

### 3.6 `TranslateRequest`

Request an on-device ML Kit translation. The result comes back via `window.__cupTranslated(result)` — the host injects that callback on page finish.
```js
TranslateRequest.postMessage(JSON.stringify({ text, from: 'sv', to: 'en', rid: '...' }));
// → window.__cupTranslated({ rid, text })
```

### 3.7 `LinkLongPress`

Report a long-press on an `<a>` element so the host can show a "Copy link / Open in new dialog" menu. Emitted automatically by injected JS — you don't call it directly.

### 3.8 `GitHubProxy`

Send an authenticated GitHub API request through the host (avoids CORS for gh:// endpoints). Used by the dictionary lookup flow — not typically consumed by webapp code.

---

## 4. Dart → JS Events

The host pushes state changes as `CustomEvent`s on `window`. Every event also stashes its detail on a `window.__cupitor…` global so listeners that attach late can still read the last value.

| Event | Global mirror | Fires when |
|---|---|---|
| `cupitorPlaylists` | `window.__cupitorPlaylistsPayload` | Playlist mutated · dialog1 page finish · `getPlaylists` op |
| `cupitorGlobalSearchResults` | `window.__cupitorGlobalSearchResults` | `globalSearch` op completed |
| `cupitorDialog1Closed` | — | Dialog1 was dismissed (webapp about to be torn down) |
| `cupitorMediaKey` | — | Headset/media key pressed (`{ detail: { key: 'play' \| 'pause' \| 'next' \| 'prev' } }`) |
| `cupitorNotifAck` | payload-dependent | Response to a `NotifBridge` op |
| `capturedSubtitle` | — | Host has a subtitle chunk to inject into your current view |

Idempotency: a `cupitor*` event may fire multiple times with the same content — always render off `event.detail`, never off transient state.

**Read the last known value on load** (fixes late-attach race):
```js
if (window.__cupitorPlaylistsPayload) {
  render(window.__cupitorPlaylistsPayload);
}
window.addEventListener('cupitorPlaylists', (ev) => render(ev.detail));
```

---

## 5. Global Search — Query Grammar & Data

### Query grammar

Deliberately small. No regex, no wildcards, no field:value syntax.

- `phrase` → word / prefix match on the last token (e.g. `cat` → cat, cats, cathedral, but not concatenate)
- `phrase1|phrase2` → OR — a chapter matches if it contains **any** phrase
- `foo bar|baz qux` → spaces inside a phrase are literal token boundaries; only `|` splits phrases
- Whitespace around `|` is trimmed. Empty phrases (from stray pipes) are dropped.
- **Single-word phrases shorter than 3 chars are dropped** (`a`, `of`, `is`). Multi-word phrases are exempt — `is of` is honored.
- Case and diacritics are folded by the tokenizer (`unicode61 remove_diacritics 2`).

Examples:
```
cat|dog
apple pie
apple pie|orange juice
över|hem|kom
```

**Backend**: on-disk SQLite FTS5 index. Books get indexed lazily on first search that visits them; subsequent searches hit the index. Users can configure the on-disk index size cap (with LRU eviction) or disable the index entirely — see §5.6.

### 5.1 Result payload — delta stream

Results **stream**: the host dispatches one event per book-scan boundary while a search runs, plus a final closing event. Each event's `hits` array is a **delta** — the client accumulates.

```ts
// window.addEventListener('cupitorGlobalSearchResults', ev => …)
type GlobalSearchPayload = {
  query: string;                 // the query that produced these hits
  hits: GlobalSearchHit[];       // DELTA — hits found since the previous event
  done: boolean;                 // false while streaming, true on the closing event
  hits_capped: boolean;          // true if the 200-total-hit cap was reached
  cancelled?: boolean;           // present + true only when closed via cancelSearch
                                 // or superseded by a new globalSearch
};

type GlobalSearchHit = {
  book_key: string;              // SHA-1 hex — usable with the `openEpub` op
  book_title: string;
  chapter_idx: number;           // 0-based
  chapter_title: string;         // TOC label; may be empty → render as "Chapter N"
  snippets: GlobalSearchSnippet[];  // up to 3 per chapter
};

type GlobalSearchSnippet = {
  phrase: string;                // lowercased phrase that matched
  offset: number;                // character offset in the extracted chapter text
  before: string;                // ~48 chars of context on the left
  match: string;                 // the matched substring, preserving original casing
  after: string;                 // ~48 chars of context on the right
};
```

**Delta ordering guarantees**:
- Delta events carrying the same `query` arrive in scan order.
- The closing `done: true` event always comes last for that query. Its `hits` may be empty (all hits were already streamed).
- Ignore any event whose `query` doesn't match the one you last sent — it's from a superseded search.

### 5.2 Caps

| Limit | Value | Reason |
|---|---|---|
| Max total hits | 200 | Prevent runaway payloads |
| Max snippets per chapter | 3 | High-frequency words don't dominate |
| Snippet context | 48 chars each side | Enough to disambiguate |

### 5.3 Cancellation

Two ways a search closes early:
- **Client-initiated**: send `{op: 'cancelSearch'}`. Host emits a final event with `done: true, cancelled: true`.
- **Superseded**: send a new `{op: 'globalSearch', query: '...'}`. The prior search is silently cancelled — its final event still fires with `cancelled: true` for the OLD query, and new events for the new query stream immediately after.

Clients should ignore stale events by matching `ev.detail.query` against the query they last requested. Anything else is either superseded or from a bug.

### 5.4 Highlight on open

`openEpub` accepts an optional `match` parameter. When present the EPUB reader opens with:
- The find bar visible.
- The phrase pre-filled and applied via the in-chapter find machinery.
- The first match centred on screen (browser `scrollIntoView` with `block: 'center'`).

The reader takes the first pipe-separated phrase from `match` — so passing your original query (`'cat|dog'`) works, and the reader jumps to the first phrase that a chapter hit contained.

### 5.5 Minimal usage — delta accumulator + open with highlight

```js
let currentQuery = '';
let hits = [];

window.addEventListener('cupitorGlobalSearchResults', (ev) => {
  const d = ev.detail;
  if (d.query !== currentQuery) return;             // stale — ignore
  hits = hits.concat(d.hits);
  render(hits, { streaming: !d.done, capped: d.hits_capped });
  if (d.done) {
    if (d.cancelled) console.log('search cancelled');
    // finalise UI (spinner off, "no more results" chip, etc.)
  }
});

function search(q) {
  currentQuery = q;
  hits = [];
  PlaylistBridge.postMessage(JSON.stringify({ op: 'globalSearch', query: q }));
}

function cancel() {
  PlaylistBridge.postMessage(JSON.stringify({ op: 'cancelSearch' }));
}

function openHit(hit) {
  PlaylistBridge.postMessage(JSON.stringify({
    op: 'openEpub',
    book_key: hit.book_key,
    chapter_idx: hit.chapter_idx,
    match: currentQuery,                            // → reader lands with find bar open
  }));
}
```

### 5.6 Index configuration

The full-text index is user-configurable via the Global Search screen (app-bar → "Search index"):

| Setting | Effect |
|---|---|
| Cap size (0 / 32 / 128 / 512 MB / 2 GB) | Soft cap on the on-disk index. Books evict LRU when the cap is reached. `0` disables the index entirely — every search falls back to a linear parse of every book. |
| Clear index | Drop every row, keep the cap unchanged. |

Persisted in SharedPreferences under `searchIndexCapacityBytes`. Default: 128 MB. The webapp does not currently control this — it's a device-local setting the user manages through the Cupitor app UI. If the language webapp needs to surface its state, that's a future addition.

Performance note: cold first-search on a fresh install pays the parse cost — expect a few seconds for a library of 30 books. Every subsequent search hits the index directly and returns near-instantly. Streaming ordering doesn't change: books that finish first still emit their hits first, indexed or not.

---

## 6. Playlists — Data Shape

Emitted by `cupitorPlaylists` events.

```ts
type PlaylistsPayload = {
  active_id: number | null;      // currently-selected playlist, or null
  playlists: Playlist[];
};

type Playlist = {
  id: number;                    // stable across sessions
  name: string;                  // user-editable
  created_at: number;            // epoch ms
  items: PlaylistItem[];         // ordered
};

type PlaylistItem = {
  id: number;
  text: string;                  // the captured sentence
  book_key: string | null;       // SHA-1 — non-null when captured from an EPUB
  book_title: string | null;
  chapter_idx: number | null;
  chapter_title: string | null;
  position: number;              // 0-based, contiguous per playlist
  created_at: number;
};
```

Ordering: items are already sorted by `position`, so `.map` in order works.

---

## 7. Operational Notes

### 7.1 Bridge availability timing

- Bridges are (re)bound by the host on **every navigation**, not just page load.
- Bridges are available synchronously by the time your inline `<script>` runs, but calling `postMessage` before the host has finished attaching its event listeners is safe — the WebView queues messages.
- Do **not** call `PlaylistBridge.postMessage` from a `beforeunload` handler — the host may have already unbound the channel.

### 7.2 Error handling

Bridges never throw JS-side. Any host-side failure surfaces as:
- Missing / empty `result` in the corresponding `__cupAudio` / `__cupTranslated` callback, OR
- A CustomEvent with an `error` field in its detail (`cupitorNotifAck`), OR
- No event at all (silent failure — treat this as timeout after ~5–10 s).

Guard every long-running op with a timeout. There is no per-op ack for `getPlaylists` or `globalSearch` — the CustomEvent is your only signal.

### 7.3 Voice recording formats

New recordings created after the AudioBridge switch:
- Android 10+ (API 29+): OGG / Opus, mono, 16 kHz, 24 kbps
- Android 7–9 (API 24–28): MPEG-4 / AAC-LC, mono, 16 kHz, 32 kbps

Existing older `.m4a` files at 44.1 kHz / 64 kbps still play — MediaPlayer handles both containers. Any playback in the webapp should treat the returned `file://…` URL as an opaque handle — don't infer container from extension for anything but display.

### 7.4 URL / EPUB opening

`openEpub` matches by SHA-1 of the file bytes, not by title / path. This is intentional — books survive rename / move on disk. If a hit came from a device where the book has since been deleted, `openEpub` reports "not in library" via a snackbar and stays on dialog1.

### 7.5 Lookup exclusions

The host maintains a user-managed list of URL substrings for which word-lookup / sentence-tagging JS is NOT injected into the main WebView. This does **not** affect dialog1 or the language webapp — dialog1 is a separate WebView and its scripts run unconditionally. Just noted here so you don't chase a phantom bug when the main WebView goes silent on an excluded URL.

---

## 8. Getting Started — Minimal Vue 3 Composable

```ts
// composables/useCupitorBridge.ts
import { onMounted, onUnmounted, ref } from 'vue';

const pendingAudio = new Map<string, { resolve: (v: any) => void; reject: (e: any) => void }>();

if (typeof window !== 'undefined') {
  (window as any).__cupAudio = (reply: any) => {
    const p = pendingAudio.get(reply.rid);
    if (!p) return;
    pendingAudio.delete(reply.rid);
    reply.error ? p.reject(reply.error) : p.resolve(reply.result);
  };
}

let ridSeq = 0;
const nextRid = () => `r${++ridSeq}_${Date.now()}`;

export function useCupitorBridge() {
  const playlists = ref<any | null>((window as any).__cupitorPlaylistsPayload ?? null);
  const searchHits = ref<any[]>([]);
  const searchDone = ref(true);
  const searchCancelled = ref(false);
  const searchCapped = ref(false);
  let currentQuery = '';

  const onPlaylists = (ev: any) => { playlists.value = ev.detail; };
  const onSearch = (ev: any) => {
    const d = ev.detail;
    if (d.query !== currentQuery) return;    // stale — ignore
    searchHits.value = searchHits.value.concat(d.hits);
    searchCapped.value = d.hits_capped;
    if (d.done) {
      searchDone.value = true;
      searchCancelled.value = !!d.cancelled;
    }
  };

  onMounted(() => {
    window.addEventListener('cupitorPlaylists', onPlaylists);
    window.addEventListener('cupitorGlobalSearchResults', onSearch);
    getPlaylists();
  });
  onUnmounted(() => {
    window.removeEventListener('cupitorPlaylists', onPlaylists);
    window.removeEventListener('cupitorGlobalSearchResults', onSearch);
  });

  function post(channel: string, msg: any) {
    const b = (window as any)[channel];
    if (b && typeof b.postMessage === 'function') b.postMessage(JSON.stringify(msg));
  }

  const getPlaylists = () => post('PlaylistBridge', { op: 'getPlaylists' });
  const openEpub = (bookKey: string, chapterIdx = 0, match?: string) =>
    post('PlaylistBridge', {
      op: 'openEpub',
      book_key: bookKey,
      chapter_idx: chapterIdx,
      ...(match ? { match } : {}),
    });
  const searchLibrary = (query: string) => {
    currentQuery = query;
    searchHits.value = [];
    searchDone.value = false;
    searchCancelled.value = false;
    searchCapped.value = false;
    post('PlaylistBridge', { op: 'globalSearch', query });
  };
  const cancelSearch = () => post('PlaylistBridge', { op: 'cancelSearch' });

  const recordStart = () => new Promise<string>((resolve, reject) => {
    const rid = nextRid();
    const id = nextRid();
    pendingAudio.set(rid, { resolve, reject });
    post('AudioBridge', { op: 'recordStart', rid, id });
  });
  const recordStop = () => new Promise<string | null>((resolve, reject) => {
    const rid = nextRid();
    pendingAudio.set(rid, { resolve, reject });
    post('AudioBridge', { op: 'recordStop', rid });
  });

  return {
    playlists,
    searchHits, searchDone, searchCancelled, searchCapped,
    getPlaylists, openEpub, searchLibrary, cancelSearch,
    recordStart, recordStop,
  };
}
```

Then in a component:
```vue
<script setup lang="ts">
import { watch } from 'vue';
import { useCupitorBridge } from '@/composables/useCupitorBridge';

const {
  playlists,
  searchHits, searchDone, searchCancelled, searchCapped,
  searchLibrary, cancelSearch, openEpub,
} = useCupitorBridge();

let lastQuery = '';
function onSubmit(q: string) { lastQuery = q; searchLibrary(q); }

// Open a hit with highlight — reader lands at the chapter with the
// find bar open and the first match scrolled into view.
function open(hit: any) { openEpub(hit.book_key, hit.chapter_idx, lastQuery); }

watch(searchDone, (d) => {
  if (d) console.log('search finished', {
    hits: searchHits.value.length,
    capped: searchCapped.value,
    cancelled: searchCancelled.value,
  });
});
</script>
```

---

## 9. Change Log

| Date | Change |
|---|---|
| 2026-08-02 | Initial spec — playlists, EPUB open, audio bridge, notif bridge, media state. Added: `globalSearch` op + `cupitorGlobalSearchResults` event. |
| 2026-08-02 | `globalSearch` now streams: per-book delta events with `done: false`, final `done: true`. Added: `cancelSearch` op, `cancelled` flag on the closing event, `match` param on `openEpub` (highlight-on-open — reader lands with find bar prefilled and first match scrolled into view). |
| 2026-08-02 | Added on-disk full-text index (SQLite FTS5) as the search backend. Query semantics shifted from case-insensitive substring to word / prefix match with case + diacritic folding (`cat` matches "cat"/"cats"/"cathedral"). Single-word phrases under 3 chars are dropped. Configurable via the app UI (0-2 GB cap with LRU eviction). Falls back to linear scan when the index is disabled or unavailable. |

---

## 10. Open Questions / Future Work

- **Snippet-precise highlight**: `openEpub` today highlights the phrase via the in-chapter find machinery. Threading `snippet.offset` through so the reader lands exactly on the matched occurrence (rather than the first find hit in the chapter) is a possible refinement — only matters when a chapter has many matches and the user tapped a specific snippet.
- **Streaming pagination**: `hits_capped: true` means we stopped at 200 hits. A "keep going" op that resumes from where the previous scan stopped could let power users page through unbounded result sets. Not needed today.
- **Webapp-controlled index config**: today the FTI cap / clear / disable UI lives only in the Cupitor app. If the language webapp wants to expose the same controls (e.g. a "Rebuild search index" button on its settings page), an `indexControl` op could be added — mostly a copy of `SearchIndex.setCapacity` / `SearchIndex.clear`.
