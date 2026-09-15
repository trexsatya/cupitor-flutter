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

`<stem>` is the filename-safe stem the app assigned when it copied the file, so
`id` and `url` stay in step and the existing dedupe — which keys on `id` — keeps
working unchanged for both kinds.

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

`normalizeMusicTracks` carries `kind` through and defaults it. `musicSelectedId`,
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

| Condition | Message |
|---|---|
| File missing from app storage | that file is no longer on the device |
| `MEDIA_ERR_DECODE` / `SRC_NOT_SUPPORTED` | this device can't play that file |
| anything else | that file could not be played |

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
- The track list marks each row with its kind so the two are told apart.
- The URL box's "that doesn't look like a YouTube link" alert points at the
  device button.
- Deleting a local track deletes the copied file, behind the confirm already in
  place. The copy is private to the app, so leaving it behind would be invisible
  disk.
- The panel shows the library's total size on disk. Nothing else in the app
  reports it, and a thirty-track library is a few hundred megabytes.

On open, the panel calls `musicList` and compares it against the saved tracks. A
track whose file is gone is shown as broken rather than failing at play time.

On API 24–25 the button is replaced by a line reading that local music needs
Android 8 or newer, driven by the `'needs-android-8'` error described below.
Reading a WebView's current client — which the serving layer requires — is
API 26+, the same floor the ad-blocker and render guard already sit behind.

## AudioBridge operations

The bridge keeps its existing envelope: JS posts a JSON string carrying `op` and
a JS-supplied `rid`, and the app replies through `window.__cupAudio` with the
same `rid`, plus `result` or `error`.

| Op | Request | Reply |
|---|---|---|
| `musicPick` | `{}` | JSON array of `{url, name}`, one per file picked; `[]` when the user cancels |
| `musicList` | `{}` | JSON array of `{url, name, size}` for every file in the music directory |
| `musicDelete` | `{url}` | `'ok'`, whether or not the file existed |

`name` in both replies is the file's own name on disk, without its extension. It
seeds a new track's display name; it is not read back afterwards, so renaming a
track in the panel does not rename the file.

`musicPick` opens the native picker with `FileType.audio` and
`allowMultiple: true`, copies each chosen file into `<app_documents>/music/`
under a filename-safe stem, and returns the resulting `file://` URLs. Copying
rather than referencing the picked path is deliberate: the picker's own result
lives in a cache directory the system may reclaim.

The stem comes from the picked filename, with a counter appended when that stem
is already taken. Picking the same file twice therefore produces two copies and
two tracks rather than one — deduplicating would mean hashing file contents,
which is not worth it when the panel lists the library and removing a duplicate
is one tap. `addLocalMusicTrack`'s url check guards against the same url being
added twice, which is what the panel's self-heal pass can produce.

On API 24–25 every music op replies with the error `'needs-android-8'`. The
panel calls `musicList` when it opens, so that one reply is what drives the
explanatory line in place of the button.

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
`cupitor/adblock` method channel, invoked from Dart when dialog1 finishes
loading a page. Attachment is idempotent — `chainHas` short-circuits a view
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
- A mixed library: selection falls through to the first track when the stored
  selection was deleted, regardless of the kinds involved.
- `musicShouldPlay`'s existing decision table re-run against a local track,
  proving the decision is independent of the source.

**Kotlin** gets a JUnit test file — the first in this repo, adding
`testImplementation` to `android/app/build.gradle.kts` — covering the two pieces
of logic worth proving rather than eyeballing:

- The name resolver: a bare filename resolves; `../`, a nested path, a leading
  slash, an empty name and a name that escapes by encoding are all refused.
- The `Range` parser: `bytes=0-`, `bytes=100-199`, `bytes=-500`, a range past
  the end of the file, and a malformed header.

**Manual verification on device**, captured before and after:

- A local track plays under a playlist in each of the three modes, at the right
  volume for the phase.
- Ad-blocking switched off does not stop the music.
- A track whose file has been deleted outside the app reports the missing-file
  message and marks its row.
- The bed loops without a gap at the end of the file.
