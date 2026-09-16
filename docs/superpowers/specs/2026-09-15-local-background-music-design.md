# Background music from local files — design

The background-music bed plays a track under a recordings playlist. It sources
tracks from YouTube. This design adds a second source: audio files already on
the device, picked through Android's file picker and served to the WebView from
the app's own storage.

Two repos are involved:

- **webapp** — `cupitor/frontend/vue3/cupitor-frontend`, specifically
  `public/language/music-bed.js` (the rules) and `public/language/language.js`
  (the player and the panel).
- **app** — `Cupitor`, specifically `lib/main.dart` (the `AudioBridge`) and
  `android/app/src/main/kotlin/org/satya/cupitor/MainActivity.kt` (serving the
  files to the WebView).

Local tracks work only inside the Cupitor Android app. In a plain browser the
music panel behaves exactly as it does today, YouTube-only, and the controls
for local files are not rendered.

## Scope

In scope: picking audio files from the device, storing them in app storage,
playing them as the bed, and managing them from the existing music panel.

Out of scope: playlists or shuffle across multiple bed tracks (the bed plays one
chosen track on loop); metadata beyond the filename; iOS and macOS, which have
no `AudioBridge`; streaming from a folder the app does not own.

## Track model

`music-bed.js` holds the library in the settings object under
`recMusicTracks`. A track gains a `kind`:

```js
{ kind: 'youtube', id: '<videoId>',    url: 'https://…', name: 'Kalinka' }
{ kind: 'local',   id: 'local:<stem>', url: 'file://…',  name: 'Kalinka' }
```

`kind` is optional on read and defaults to `'youtube'`. A library written before
local tracks existed therefore needs no migration pass and no rewrite on load.

`<stem>` is the filename the app gave the copy, extension included, so `id` and
`url` stay in step and the existing dedupe — which keys on `id` — keeps working
unchanged for both kinds.

The served URL the player uses is derived from `url` by taking its basename:
`file:///data/.../music/kalinka.mp3` becomes
`https://appassets.androidplatform.net/cupitor-music/kalinka.mp3`. `url` stays
the canonical form in settings and in every bridge call; the served URL is built
at play time and never stored.

Settings live in `localStorage` and do not sync between devices, so a `file://`
track cannot arrive on a device that lacks the file.

### New pure functions

| Function | Returns |
|---|---|
| `musicTrackKind(track)` | `'youtube'` or `'local'`, defaulting to `'youtube'` |
| `musicEngineFor(track)` | `'youtube'`, `'local'`, or `'none'` for a null/unusable track |
| `addLocalMusicTrack(tracks, url, name)` | `{tracks, id, added, reason}`, mirroring `addMusicTrack`; `reason` is `'not-local'` for anything that is not a `file://` URL, `'duplicate'` when the url is already saved, `'full'` at `MUSIC_TRACKS_MAX` |

`normalizeMusicTracks` carries `kind` through and defaults it, and drops a
local row that has no usable `file://` url — selection falls back to the first
row, and a row nothing can play must never be that row. `musicSelectedId`,
`musicSelectedTrack`, `musicVolumeFor`, `musicVolumeFieldsFor` and
`removeMusicTrack` are unchanged — none of them inspects what a track is.

`musicShouldPlay` is unchanged. It decides from mode, phase, hush and error
state, none of which depends on where the audio comes from.

`musicVideoIdFromUrl` stays YouTube-only and is not used for local tracks.

## Player

`language.js` drives the bed today by calling `playVideo()`, `pauseVideo()` and
`setVolume()` on a YouTube player held in `_musicPlayer`. Both sources sit
behind one interface:

```
play()              start or resume
pause()             stop sounding, keep position
setVolume(0..100)   the bed's volume scale, unchanged
stop()              release the source entirely
ready               true when play() will be honoured
```

**YouTube engine** — the current implementation, unchanged in behaviour: an
invisible-but-rendered `YT.Player` in `#recMusicHost`, cueing rather than
loading on a track switch, rewinding by hand on `ENDED`, and reporting playback
refusals through `onError`.

**Local engine** — an `<audio loop preload="auto">` element in the same
`#recMusicHost` container, so both engines inherit the off-screen-but-rendered
placement that keeps media playback dependable in an Android WebView. `loop`
replaces the hand-rolled rewind. `setVolume` maps to `element.volume = v / 100`.

`_syncBackgroundMusic` selects the engine with `musicEngineFor` and is otherwise
untouched — the mode/phase/hush decision keeps its single home. Switching to a
track of the other kind stops the engine being left behind, so only one source
can sound at a time.

The local engine's `src` is the served URL described below, never a `file://`
URL: a page loaded over `https` cannot reference `file://` subresources.

### Errors

`_noteMusicError` records a failure against `_musicErrorId`, the track it
belongs to, so the panel warns on the offending row rather than about the
library. The local engine feeds the same path from the element's `error` event,
with its own wording:

An `<audio>` error does not say whether the file is missing or merely
unplayable, so the engine asks: on any local playback error it runs the sweep
described under *Self-heal* below. If the file is gone the track is removed and
the user is told. If the file is still there, the track is reloaded once — the
first failure can be the page asking before the app had wired itself up to
answer — and only a second failure on the same track marks it.

The answer is applied only if the same track is still loaded when it arrives.
The sweep is a bridge round-trip, and a user who switched tracks in the meantime
must not have the old track's verdict pinned on the new one.

| Condition | Result |
|---|---|
| File gone from app storage | track removed from the library, reported by toast |
| File present, first failure | reloaded once, silently |
| File present, second failure | kept, row marked "this device can't play that file" |

`musicShouldPlay` already refuses to play an errored track. Selecting a
different track clears the flag, the same way cueing a new video does.

## Panel

`_openMusicPanel` gains one control: a `🎵 Add from device` button beside the
existing URL row. It renders only when `AudioBridge` is present and the device
is API 26 or newer; otherwise the panel is exactly what it is today.

- Picking is multi-select. Every file picked is added; the last one becomes the
  selection.
- A track's name defaults to the filename without its extension. Renaming works
  through the panel the same way it does for a YouTube track.
- Every row in the track list carries an icon for its kind — `▶` for YouTube,
  `♪` for local — so the two are told apart at a glance.
- The URL box's "that doesn't look like a YouTube link" alert points at the
  device button.
- Deleting a local track deletes the copied file, behind the confirm already in
  place. The copy is private to the app, so leaving it behind would be invisible
  disk.
- The panel shows the library's total size on disk. Nothing else in the app
  reports it, and a thirty-track library is a few hundred megabytes.

### Self-heal

A sweep compares `musicList` against the saved library and removes every local
track whose file is gone, reporting what it removed by toast. It runs when the
panel opens and whenever the local engine reports a playback error, so a
vanished file is cleared away rather than left to fail again.

Only local tracks are swept. A YouTube track is never removed by it — its
playability is YouTube's business and can come back.

Removing the selected track needs no extra handling: `musicSelectedId` already
falls back to the first track in the library when the stored selection is gone.

On API 24–25 the button is replaced by a line reading that local music needs
Android 8 or newer, driven by the `'unsupported'` error described below.
Reading a WebView's current client — which the serving layer requires — is
API 26+, the same floor the ad-blocker and render guard already sit behind.

## AudioBridge operations

The bridge keeps its existing envelope: JS posts a JSON string carrying `op` and
a JS-supplied `rid`, and the app replies through `window.__cupAudio` with the
same `rid`, plus `result` or `error`.

| Op | Request | Reply |
|---|---|---|
| `musicPick` | `{}` | JSON `{picked: [{url, name}], failed: n}` — one entry per file copied, and the count of picks that could not be; `{picked: [], failed: 0}` when the user cancels |
| `musicList` | `{}` | JSON array of `{url, name, size}` for every file in the music directory |
| `musicDelete` | `{url}` | `'ok'`, whether or not the file existed |

`name` seeds a new track's display name and is the filename without its
extension — in `musicPick` the name the user's file had, in `musicList` the name
of the copy. It is not read back afterwards, so renaming a track in the panel
does not rename the file.

`musicPick` opens the native picker with `FileType.audio` and
`allowMultiple: true`, copies each chosen file into `<app_documents>/music/`,
and returns the resulting `file://` URLs. Copying rather than referencing the
picked path is deliberate: the picker's own result lives in a cache directory
the system may reclaim. A copy that fails is counted in `failed` rather than
dropped, so the page can say so instead of treating it as a cancel.

The copy's name is the picked filename with the characters a filesystem or URL
path cannot carry replaced; letters in any script are kept. A name already taken
by a file of the **same size** is treated as the same song picked again and
reused rather than copied, so the library's own dedupe collapses it onto the
existing track. A name taken by a file of a different size gets a counter
appended — two different songs may share a name.

Every `file://` URL the page hands back is confined to the music directory
after collapsing `..` segments, so a URL that only leaves the directory through
a dot segment is refused. The manual-recording ops apply the same check to
their own directory.

When the device cannot serve local music — API 24–25, or a platform other than
Android — every music op replies with the error `'unsupported'`. The panel calls
`musicList` when it opens, so that one reply is what drives the explanatory line
in place of the button. The ops wait for the native attach to have answered
before replying, so a panel opened moments after page load gets the real answer
rather than a premature `'unsupported'`.

A `musicList` that fails for any other reason puts the panel in a third state:
the device button stays available (the app is there), a line says the files
could not be read just now, and **no sweep runs** — a failed listing is not an
empty disk.

`music/` is a sibling of the existing `manual_audio/` and gets its own resolver
mirroring `_resolveAudioUrl`, which refuses any path outside its directory.
Neither op set can reach the other's files: `save`/`load`/`delete` stay confined
to `manual_audio/`, and the three music ops stay confined to `music/`.

## Serving the files

The WebView reaches the files over an intercepted HTTPS request.

`LocalMediaWebViewClient` is a new chained client following the
`ChainedWebViewClient` / `chainHas` pattern already in `MainActivity.kt`. It is
its own client rather than a branch inside `AdBlockWebViewClient`, because that
client returns to its delegate as its first act when ad-blocking is switched
off, and background music must not depend on an unrelated setting.

It answers requests for:

```
https://appassets.androidplatform.net/cupitor-music/<name>
```

`appassets.androidplatform.net` is Android's reserved domain for app-served
content and never resolves publicly, so a request this client does not answer
fails closed rather than leaving the device.

`<name>` is resolved against `<app_documents>/music/` only. A name containing a
path separator, a `..` segment, or a leading `/` is refused with a 404 — the
resolver joins nothing it has not first proven to be a bare filename.

Responses carry the content type derived from the extension and
`Accept-Ranges: bytes`. A request with a `Range` header is answered `206` with
`Content-Range`; anything else is answered `200` with the whole file. Range
support is what lets `<audio>` loop and seek without refetching, and
`shouldInterceptRequest` runs off the main thread, so streaming from disk there
is safe.

The client is attached through a new `attachLocalMedia` call on the existing
`cupitor/perms` method channel — the one that already carries
`installRenderGuard`, the other WebView-wrapping op — invoked from Dart when
dialog1 finishes loading a page. Dart passes the music directory's path with the
call, so Kotlin never has to guess where path_provider put it. Wrapping nothing
is not success: when no WebView is in the tree yet the call answers
`no-webview` and Dart retries, the same contract `installRenderGuard` uses. Attachment is idempotent — `chainHas` short-circuits a view
already wrapped — and independent of the ad-blocker's own attach.

## Testing

**`music-bed.test.js`** extends the existing suite:

- `kind` defaults to `'youtube'` on a track saved without one, and
  `normalizeMusicTracks` carries an explicit `kind` through.
- `addLocalMusicTrack` rejects a non-`file://` url, reports a duplicate url
  without adding, honours `MUSIC_TRACKS_MAX`, and names a track from its
  argument.
- `musicEngineFor` over all four inputs: a YouTube track, a local track, a track
  with no usable url, and null.
- `musicServedUrl` builds the served URL from a local track's basename and
  returns `''` for a YouTube track.
- `pruneMissingLocalTracks` removes local tracks whose url is absent from the
  on-disk list, keeps local tracks that are present, never removes a YouTube
  track — including when the on-disk list is empty — and removes nothing at all
  when given no list.

**Dart** gets `lib/local_music.dart`, pure helpers with `test/local_music_test.dart`:
the copy's safe filename (scripts kept, separators and URL-hostile characters
replaced, hidden and dot names refused), the display name, and
`filePathInsideDir`, which must refuse an escape that only appears after
collapsing `..`.
- A mixed library: selection falls through to the first track when the stored
  selection was deleted, regardless of the kinds involved.
- `musicShouldPlay`'s existing decision table re-run against a local track,
  proving the decision is independent of the source.

**Kotlin** gets a JUnit test file — the first in this repo, adding
`testImplementation` to `android/app/build.gradle.kts` — covering the two pieces
of logic worth proving rather than eyeballing:

- The name resolver: a bare filename resolves; `../`, a nested path, a leading
  slash, an empty name and a name that escapes by encoding are all refused.
- The `Range` parser: `bytes=0-`, `bytes=0-0`, `bytes=100-199`, `bytes=-500`,
  a range past the end of the file, and a malformed header.
- The range stream, against a real temp file: it hands over exactly the window
  it was given and no more, for bulk and single-byte reads.

**Manual verification on device**, captured before and after:

- A local track plays under a playlist in each of the three modes, at the right
  volume for the phase.
- Ad-blocking switched off does not stop the music.
- A track whose file has been deleted outside the app disappears from the list
  with a toast saying so, and the bed hands over to the next track.
- The bed loops without a gap at the end of the file.
