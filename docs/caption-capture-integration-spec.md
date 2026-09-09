# Caption Capture — Integration Spec

**Event:** `cupitorCaptionCapture` · **Channel:** `CaptionCollector`

Companion to [webapp-integration-spec.md](webapp-integration-spec.md) §4 (Dart → JS Events). Design rationale lives in [specs/2026-09-06-caption-capture-design.md](superpowers/specs/2026-09-06-caption-capture-design.md).

---

## 1. Overview

Two kinds of text reach the language webapp through this one path, told apart by a `source` field:

- **`caption`** — a video plays with captions in Cupitor's **main** WebView, `snippet.js` harvests the cues into a timestamped sidebar, and the user ticks the lines worth keeping.
- **`page`** — the user picks sentences off a web page, including inside a same-origin reader iframe, and collects them in a basket.

Either way the block arrives in the webapp (dialog1) as an ordered list of lines, flagged so the webapp knows it is neither a book-derived item nor, in the `page` case, timed.

Three parts, in two repositories plus one that is not checked out here:

| Part | Where |
|---|---|
| Harvest, sidebar, selection, send | `trexsatya.github.io` → `db/js/src/*.js`, bundled into `db/js/snippet.js` |
| Receive, normalise, forward to dialog1 | `Cupitor` → [lib/caption_capture.dart](../lib/caption_capture.dart), [lib/main.dart](../lib/main.dart) |
| Listen for `cupitorCaptionCapture`, create manual playlist item(s) | language webapp → `public/language/caption-capture.js` (normalisation), `public/language/language.js` (dialog, de-dupe, card write) |

All three are live. A capture opens a dialog asking which playlist the block goes to and which face of the card the text lands on; the choice of face is remembered, since someone collecting from one source sends repeatedly and wants the same orientation each time.

`snippet.js` is fetched at runtime by every device from `gh-pages`. A push there is a deploy — there is no staging copy.

It is **generated**: edit `db/js/src/*.js` and run `db/js/build.sh`, which checks every source parses before writing the bundle. The sources are numbered because concatenation order is load order — `70-caption-capture.js` reads what `20` and `30` publish on `window.__cupShared`. One delivered file is not a preference: the host injects it with `runJavaScript`, and a `<script src>` pointing at `gh-pages` is blocked by the content-security policy on the very sites this targets. `build.sh --check` fails if the committed bundle is stale.

`db/js/frame-boot.js` is not part of the bundle. It has its own URL because the host registers it as a document-start script on the WebView rather than injecting it per page.

---

## 2. Flow

**Given** captions are playing in the main WebView and `window.CaptionCollector` exists,
**when** the user enters select mode, ticks lines and taps send,
**then** the page posts the selection to the host, the host normalises it, dialog1 opens or comes to the front, and `window` receives a `cupitorCaptionCapture` event carrying the block.

**Given** any web page, including a book inside a same-origin iframe,
**when** the user collects sentences — by selecting text, or by tapping while the app's capture chip is armed — and taps send,
**then** the same thing happens, with `source: 'page'` and no timestamps.

```
snippet.js sidebar
   │  CaptionCollector.postMessage(JSON.stringify(payload))
   ▼
Cupitor host — _handleCaptionCollector
   │  buildCaptionCaptureDetail(raw, fallbackLang: <app language>)
   ▼
dialog1 WebView
   │  window.dispatchEvent(new CustomEvent('cupitorCaptionCapture', { detail }))
   ▼
language webapp  ← you are here
```

Outside Cupitor the channel is absent, the send and select buttons hide themselves, and the sidebar behaves as it always has.

---

## 3. Page → Host (`CaptionCollector`)

Documented so the shape is traceable end to end. The webapp never sees this — only §4.

Both sources post to the same channel, and the host shapes both with the same function.

**Captions** — timed cues from the subtitle sidebar:

```js
window.CaptionCollector.postMessage(JSON.stringify({
  source: 'caption',                           // omitted by older scripts; defaults to this
  title: (document.title || '').trim(),
  url:   location.href,
  lang:  state.translationSource || '',        // sidebar's source-language field
  lines: [ { start, end, text, translation? }, … ],
}));
```

A send only happens when at least one cue is ticked. On success the sidebar leaves select mode and clears the selection; the harvested cues stay in the list, so the same lines can be sent again.

**Page sentences** — no `start` / `end` at all:

```js
window.CaptionCollector.postMessage(JSON.stringify({
  source: 'page',
  title: (document.title || '').trim(),
  url:   location.href,
  lang:  '',                                   // host falls back to the app language
  lines: [ { text: 'Han gick hem.' }, … ],     // order is what the user picked
}));
```

Two ways to collect them, because one is not enough:

- **Selecting** text shows an "+ Add sentence" chip in a fixed corner — fixed rather than anchored to the selection, so it never fights Android's own Copy/Share menu.
- **Armed tapping** exists because e-book readers routinely disable selection to keep long-press for their own page-turn gestures, so dragging to select fails in exactly the place this feature is most wanted. The app's existing capture chip calls `window.__cupitorSetCaptureMode(true)`; each tap then resolves the sentence under the finger with `Selection.modify` at sentence granularity, falling back to splitting the tapped text node. A tap is swallowed only when a sentence was actually collected, so an armed tap on empty margin still turns the page. `snippet.js` also injects a `user-select: text` override, which re-enables dragging on many readers.

Both paths install into the top document **and** every same-origin frame, so a book rendered inside an iframe is reachable. A cross-origin frame is not, and cannot be made so from JavaScript — that would need WebView-level injection. `window.cupFrameReport()` lists each frame and whether it could be reached.

---

## 4. Host → WebApp (`cupitorCaptionCapture`)

```ts
type CaptionCapture = {
  source: 'caption' | 'page';   // never a book-derived item either way
  title: string;                // video / page title, '' when unknown
  url: string;                  // page the text came from, '' when unknown
  lang: string;                 // advisory source language, see §6
  lines: CaptionLine[];         // never empty, ordered
};

type CaptionLine = {
  start: number;            // seconds into the media; always 0 for source 'page'
  end: number;              // seconds, always >= start; always 0 for 'page'
  text: string;             // plain text, may contain '\n' for a multi-line cue
  translation?: string;     // present only when that line has one
};
```

`source` is the only field whose meaning differs between the two, and it is worth branching on: a `caption` block is a timed extract from one video, while a `page` block is a set of sentences a reader chose by hand and has no media time at all.

Listen for it:

```js
window.addEventListener('cupitorCaptionCapture', (ev) => {
  const cap = ev.detail;
  if (!cap) return;
  if (cap.source === 'caption') {
    addManualCards(cap);          // timed lines from one video
  } else if (cap.source === 'page') {
    addManualCards(cap);          // hand-picked sentences, start/end both 0
  }
});
```

Register the listener **at app root**, not on the manual-card page. The event can arrive whatever route the webapp is showing.

---

## 5. What the host guarantees

The page scrapes a third-party player whose markup changes without notice, so the host normalises everything before it reaches the webapp. Implemented in [caption_capture.dart](../lib/caption_capture.dart) and covered by [test/caption_capture_test.dart](../test/caption_capture_test.dart).

| Guarantee | Detail |
|---|---|
| `source` is `'caption'` or `'page'` | Always present and always one of those two. Anything unrecognised from the page — including a missing field, as older page scripts send none — is normalised to `'caption'`. |
| `lines` is non-empty | An empty or all-blank selection fires no event at all. |
| `lines` is ordered | Ascending by `start`, whatever order the page collected them in, with ties resolved to the order they arrived. That tiebreak is what makes `page` blocks — where every `start` is 0 — come out in the order the user picked them, since Dart's sort is not stable on its own. Array order is safe to rely on for both sources. |
| Times are numbers | Strings are parsed; missing or unparsable becomes `0`. |
| `end >= start` | An end before its start is clamped up to the start. Duration is never negative. |
| `text` is non-blank | Trimmed, and blank cues are dropped rather than forwarded. |
| `translation` is meaningful | Trimmed, and omitted entirely when blank. It is never `''` or whitespace. |
| `title` / `url` are strings | Missing values become `''`, never `null` or `undefined`. |
| `lang` is non-empty | Falls back to the app's language setting. |
| Malformed input is silent | Non-JSON, a non-object payload, or a non-list `lines` produces no event and no error. |

---

## 6. What the host does not guarantee

Handle these in the webapp — they will happen in normal use.

- **Duplicates.** Nothing dedupes across sends. Send the same lines twice and the event fires twice with identical content. Decide whether to append, or to key on `url` + `start` + `text`.
- **Size.** There is no cap. Select-all on a feature-length film is thousands of lines in one event. Batch or paginate on your side if that would stall the UI.
- **`lang` accuracy.** It is the sidebar's *translation source* field — free text the user can edit, defaulting to `sv`. Treat it as a hint for display or defaulting, never as a key for logic.
- **Ragged translations.** Translation is opt-in and backfills asynchronously, so one selection routinely mixes lines that have one with lines that do not.
- **Zero-length lines.** `end == start` is legitimate: a clamped or unknown end time. So is `start == 0` for a cue harvested without timing.
- **Multi-line text.** A two-line on-screen cue arrives with an embedded `\n`. Normalise for display if a single line is wanted.
- **Ordering across events.** Lines are ordered *within* one event. Two sends from the same video are two independent blocks.

---

## 7. Delivery and timing

**Given** dialog1 has a live controller (the usual case),
**when** a capture arrives,
**then** the event dispatches immediately and dialog1 is brought to the front — un-minimised if it was minimised.

**Given** dialog1 has never been opened this session,
**when** a capture arrives,
**then** the host stashes it, opens dialog1, and dispatches once the page finishes loading.

Two consequences worth designing for:

1. **Sending puts the webapp on screen, over the playing video.** The user's next sight is whatever route the webapp was last showing. Give the event visible feedback — a toast, a highlighted new card, a jump to the manual-card list — or the send looks like it did nothing.
2. **The event fires before the dialog is visible** in the first case. Do not gate the listener on a visibility or focus event.

---

## 8. Known gap — no global mirror

Every other host event stashes its payload on a `window.__cupitor…` global so a late-attaching listener can read the last value ([webapp-integration-spec.md](webapp-integration-spec.md) §4). **`cupitorCaptionCapture` does not.**

The consequence is narrow but real: if dialog1's controller exists while its page is mid-navigation, the event dispatches into a document whose listener has not attached yet, and it is lost with no trace. The webapp cannot recover from this on its own.

The webapp side is already in place: it reads `window.__cupitorCaptionCapture` once its playlists have loaded, clears it so a reload cannot re-add the block, and otherwise ignores it. Closing the gap is a one-line host change — set the global before dispatching:

```dart
window.__cupitorCaptionCapture = detail;   // then dispatch as now
```

Until that lands, treat a lost capture as "the user taps send again".

---

## 9. Verification

Host and page halves, on device:

1. Play a captioned video on `urplay.se`, open the sidebar, tick two lines, send → dialog1 opens with a block of exactly those two lines, in playback order.
2. Same on `svtplay.se` → unchanged harvesting behaviour, plus selection.
3. Tick lines out of order (a late one first) → they arrive ordered by time.
4. Turn translation on, let some lines fill in, select a mix → lines without a translation carry no `translation` key.
5. Select-all on a fully-fetched transcript → one event with every harvested line.
6. Send, then send the same lines again → two events, identical content, no host-side complaint.
7. Send with dialog1 minimised → it comes to the front.
8. Send before dialog1 has ever been opened → it opens and the block still arrives.
9. Open the same page in a desktop browser → no select or send buttons; the sidebar is unchanged.

Webapp half:

10. A `page` block → the dialog reads "Captured sentences", and the card holds them in the order they were picked.
11. A 2000-line event → the UI stays responsive.
12. Listener attached at app root → capture arrives while on a non-playlist route.
13. Send the same block into the same playlist twice → the second send adds nothing and says so.
14. Send a block, edit that card's captured face by hand, send the same block again → the lines come back as a fresh card rather than being suppressed by a card that no longer holds them.
15. Send with no playlist that can take cards (only virtual and app-owned ones exist) → a message saying to create one, not a silent drop.
