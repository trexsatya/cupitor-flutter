# Spotify clips in the study playlist

The study page runs in dialog1. Spotify runs in the main browser WebView or a
dialog2 WebView, with its own media clock and Spotify sign-in. Timed playlist
playback uses `SpotifyClipBridge` to control that actual page.

The host reuses an existing Spotify WebView, loading the requested episode when
needed, or opens the normal Spotify dialog when none exists. The study page
sends a unique `sessionId`, the episode URL, and numeric `start`/`end` seconds.
The packaged agent seeks while paused, confirms the observed position, and
then accepts Play. A 50 ms guard inside Spotify pauses at the end independently
of dialog1. Native polling sends playback progress and completion to the queue.
Separate selected passages receive separate sessions; stale commands cannot
seek, resume or stop the next passage.

The packaged adapters observe detached HTML media and MediaSession handlers at
document start on Android. Main-frame injection also retries on page start and
finish. They do not access Spotify account tokens. Their adapter sections mirror
`db/js/src/24-spotify-playback-bridge.js` and `25-spotify-player.js` in the shared
web repository; keep those sections aligned when the shared player changes.

Commands on `SpotifyClipBridge.postMessage(JSON.stringify(...))`:

| Operation | Additional fields |
| --- | --- |
| `cue` | `url`, `start`, `end` |
| `seek` | `time` within the current bounds |
| `play`, `pause`, `stop`, `show` | none |

All commands include `sessionId`. Events use the `cupitorSpotifyClip`
CustomEvent, whose detail includes the same ID and a `type` of `ready`,
`playback_update`, `ended`, `error` or `closed`. Event position/duration values
use milliseconds. Closing Spotify stops the queue; unavailable playback is
reported as an error so the normal queue can skip it. App backgrounding pauses
real playback and excludes background time from seek timeouts. Returning to
the main Spotify page through Show Spotify keeps the managed clip active.

The caption sidebar yields its replay strategy while a managed clip is active.
Taking ownership clears the old capture/lookup hold, so closing that dialog
cannot resume an already-finished passage. Ordinary dialog close, study reload
and host disposal stop managed playback.

## Checks

```sh
dart tool/test_spotify_clip_bridge.dart
dart analyze lib/spotify_clip_bridge.dart tool/test_spotify_clip_bridge.dart tool/spotify_clip_fixture.dart
CUPITOR_JSDOM=/path/to/node_modules/jsdom node --test test/js/spotify_clip.test.mjs
```

For the test that connects the real Dart bridge and both JavaScript sides,
also set `CUPITOR_DART` to the Dart executable and `CUPITOR_WEB_ROOT` to the
shared web repository checkout containing the companion Spotify native adapter.

The automated checks use simulated Spotify media, not a signed-in Android
device. A device check should open episode `317TI86OHwkAxLtwi1VnXN`, load its
matching SRT, capture several separated lines, and play the resulting playlist.
Verify the exact episode, start/end boundaries, passage and card advancement,
Show Spotify, pause/resume, backgrounding, closing and a mixed YouTube queue.
Both the shared web change and a new Cupitor build are required for native
WebView control.
