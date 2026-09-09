# Caption capture from video players

## Why

When a video plays with captions in the main WebView, there is no way to keep
the lines. The user wants to collect them, keep them in order, pick the ones
worth keeping, and send those to the language webapp as a manual playlist item.

Most of the machinery already exists. `snippet.js` (served from
`trexsatya.github.io`, `gh-pages`, at `db/js/snippet.js`) contains
`createSubtitleUI(opts)` — a self-contained in-page sidebar that holds a
timestamped cue list with translation, seek-to-cue, auto-scroll, copy and
clear. It is fed by `svtPlaySubs()`, which harvests cues three ways:

1. native `video.textTracks` + `cuechange` (`pumpTextTracks` / `harvestTrack`),
   forcing `mode = 'hidden'` so cues populate without the player's own overlay;
2. XHR / fetch response sniffing for `WEBVTT` bodies (`parseAndPushVtt`);
3. a DOM observer mirroring the on-screen cue container.

Three things are missing: `svtPlaySubs()` is gated to `svtplay.se` / `svt.se`,
the sidebar has no per-line selection, and there is no path from the sidebar to
the webapp.

## Scope

This spans two repositories:

| Repo | Change | In this workspace |
|---|---|---|
| `trexsatya.github.io` (`gh-pages`) | `db/js/snippet.js` — site table, selection UI, send button | yes |
| `Cupitor` | one JavaScript channel, and the event it forwards to dialog1 | yes |
| language webapp (`cupitor-frontend`) | listen for `cupitorCaptionCapture`, create the manual item(s) | **no** |

`snippet.js` is fetched at runtime by every device, so a change there is live on
next page load with no app release. There is no staging copy — treat a push as a
deploy.

The webapp's source is not checked out on this machine — `trexsatya.github.io`
carries only the minified build — so the third row is out of scope here. What
this spec delivers for it is the contract in §3, and the feature degrades
cleanly until that half exists: the host fires an event nobody listens to.

## Design

### 1. Un-gate the installer

`svtPlaySubs()` returns early unless the host matches SVT. Replace that gate
with a site table resolved in order:

```js
const CAPTION_SITES = [
  { id: 'svt',    host: /(^|\.)svtplay\.se$|(^|\.)svt\.se$/, opts: { /* existing SVT opts */ } },
  { id: 'urplay', host: /(^|\.)urplay\.se$/,  domSelector: '.jw-text-track-display' },
  { id: 'jw',     domProbe: '.jw-text-track-display' },   // any JW Player page
  { id: 'yt',     host: /(^|\.)youtube\.com$/, domSelector: '.ytp-caption-segment' },
  { id: 'native' },                                        // TextTracks only
];
```

Three distinct fields, easy to conflate:

| Field | Means |
|---|---|
| `host` | match this site by domain |
| `domProbe` | match this site by the presence of this element, whatever the domain |
| `domSelector` | where the caption text lives, once matched |

An entry needs `host` or `domProbe` to match at all; `domSelector` is only
needed for the DOM-observer strategy. For a player identified by its own markup
the same selector serves as both — `jw` probes for `.jw-text-track-display` and
reads from it.

Resolution: host match first, then a DOM probe for players identifiable by
markup regardless of domain, then a generic entry that installs the TextTrack
and VTT strategies with no DOM observer. The three harvest strategies become a
shared core; SVT keeps its own `opts` (shrink selectors, `data-rt` handles)
rather than those being baked into the core.

The install token (`window.__cupSvtInstalled`) and its version constant become
generic, keeping the existing teardown-previous-install behaviour so a bumped
version replaces a stale sidebar cleanly.

This table is the remote configuration the feature needs: a changed layout or a
new player is an edit here.

### 2. Per-line selection

Two buttons join the sidebar header (`.cup-sub-head`), which currently holds
split / auto-scroll / translate / settings / prev / next / copy / clear:

- **select mode** — enters selection and doubles as select-all / select-none
- **send** — hands the selection to the app

In select mode each cue row in `.cup-sub-list` gains a checkbox and the status
span reads "N selected". Out of select mode the sidebar is unchanged.

**Word lookup keeps working, in every mode.** `tokenize()` already wraps each
word in `<span class="cup-w" data-w="…">` and `attachWordClicks()` posts it to
`CaptionHandler`, which opens dialog1 on that word. This lives in
`createSubtitleUI`, so every newly-supported site inherits it.

That constrains how selection is driven. A word click must never toggle
selection, and toggling must never fire a lookup — so **selection is driven by
the checkbox and the timestamp gutter, never by the words themselves**. The word
spans already call `stopPropagation()`, which keeps a lookup from bubbling into
a row toggle; the timestamp gutter gives a tap target big enough to be usable
without competing with the text.

The alternative — making a row tap toggle while in select mode — would mean the
same tap does different things depending on a mode the user has to remember, and
would take word lookup away exactly when they are reading lines to decide which
to keep. Keeping tap meanings fixed is worth the smaller target.

Selection is by cue index into `state.cues` and is cleared by the existing
`clear` action and whenever the cue list is rebuilt.

Select mode is left only by pressing the toggle — emptying the selection does
*not* drop out of it. Deselecting your last line while still picking through a
transcript should not make the checkboxes disappear from under you.

**Select-all means every harvested cue, not every visible one.** On SVT the VTT
sniffing populates the whole track ahead of the playhead, so select-all yields
the full transcript immediately. On DOM-observed players the list fills as the
video plays, so the same action yields what has played so far. The UI must not
assume either.

### 3. Send to the webapp

The send button posts the selected cues on a new JavaScript channel. It
feature-detects that channel and hides itself when absent, so `snippet.js` stays
harmless in a plain browser — the same trick the language webapp uses for its
dictation buttons.

Payload from the page to the host:

```js
{ title, url, lang, lines: [ { start, end, text, translation? }, ... ] }
```

`lines` are ordered by `start`.

Flutter registers the channel on the main WebView `_controller`, alongside
`CaptionHandler`, and re-emits it to dialog1 as a **new** `cupitorCaptionCapture`
CustomEvent:

```ts
type CaptionCapture = {
  source: 'caption';   // distinguishes this from a book-derived item
  title: string;       // video / page title
  url: string;         // page the captions came from
  lang: string;        // source language, from _selectedLanguage
  lines: { start: number; end: number; text: string; translation?: string }[];
};
```

`start` / `end` are seconds. Lines are ordered by `start`, so the webapp can
rely on array order.

**The webapp decides how this becomes manual playlist item(s)** — one per line,
one for the block, with or without the timestamps rendered into the text. The
host's job ends at delivering an ordered, timed, flagged block.

Delivery mirrors `_sendCapturedSubtitleToDialog1`: dispatch directly when
`dialogController` exists, otherwise stash the payload and fire it from
`onPageFinished` once the listener is alive. It needs its own pending slot
rather than sharing `_pendingCapturedSubtitle`, since the two events are
independent.

This is deliberately **not** `capturedSubtitle`. That event drives the existing
YouTube and filmot subtitle-study flows, and reusing it would put a branch in
the middle of a working path. A separate event also lets the two halves ship
independently: with no listener registered, sending is simply inert.

It is also not `PlaylistService.addToActive` — that writes host-side playlist
items for captured EPUB sentences, which is a different store from the webapp's
manual cards.

## Error handling

- No caption source on the page — nothing installs, no sidebar, no cost.
- Channel missing (plain browser) — send button hidden.
- Empty selection — send disabled.
- Malformed payload reaching Dart — dropped silently, matching the other
  channels.
- `snippet.js` fetch failure — the existing cache-and-retry path in
  `_injectRemoteSnippet` / `_warmRemoteSnippetCache` already covers it.

## Testing

**Flutter.** Converting a received channel payload into a `cupitorCaptionCapture`
detail is pure and gets unit tests: ordering by `start`, carrying translations
through including the ragged case where only some cues have one, and rejecting
empty or malformed input without throwing.

**snippet.js.** That repo has no test harness, so verification is manual:
`urplay.se` for the JW / DOM-observer path and `svtplay.se` for the TextTrack +
VTT path. Checks that matter:

- select-all on SVT yields the whole transcript, not just what has played
- word click opens a lookup in *both* modes, and never toggles a checkbox
- checkbox and timestamp-gutter taps toggle, and never fire a lookup
- with select mode off the sidebar behaves exactly as it does today
- the send button is absent outside Cupitor (no channel)

Page-side logging goes through the existing `SnippetLogChannel` shim, so it is
readable from the app's log.

## Out of scope

- Editing caption text before sending.
- Persisting collected cues across a page reload — the sidebar is per-page.
- The webapp's `cupitorCaptionCapture` listener and its item-shaping decision;
  its source is not in this workspace. The contract in §3 is what it builds to.
- Replacing the yt-dlp caption-download flow, which serves a different purpose
  (whole tracks for a known YouTube video, rather than what is on screen now).
- Writing to the host-side playlist store via `PlaylistService` — that holds
  captured EPUB sentences, not the webapp's manual cards.
