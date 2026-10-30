# Downloaded YouTube tracks in the page subtitle sidebar

The remote caption module exposes **⤓CC** only when the host provides
`window.YouTubeSubtitles.postMessage`. Clicking it sends:

```json
{"op":"download"}
```

The native floating **CC** button opens the caption-track list directly on
every press. It does not call the page's panel launcher or toggle visibility.
The page's **SRT · Capture** launcher remains the panel visibility control.

Both CC download buttons read the video URL from the actual main WebView controller, then
reuses `_startYouTubeSubtitleDownload` with that controller as `sidebarTarget`.
The existing yt-dlp track list, language picker, busy/error dialogs and JSON3 /
VTT parsing are shared with the standalone CC download flow. That flow keeps
its existing full-file dialog when no sidebar target is supplied.

After downloading, the host calls `window.__cupImportYouTubeSubtitles(payload)`
with this shape (timing is in seconds):

```json
{
  "videoId":"abcdefghijk",
  "lang":"sv",
  "lines":[{"start":1.5,"end":4.0,"text":"En mening."}]
}
```

The sidebar validates that the current YouTube video still matches, replaces
the live transcript and uses the selected track's language for translation
and captures. It returns `true` when accepted and `false` for a changed video,
invalid payload or empty usable track. The host reports a declined attachment.
There is one active download flow at a time. No URL supplied by page JavaScript
is used for the download.

Live DOM/TextTrack/VTT harvesting is suspended for the downloaded video's
timeline so approximate painted captions cannot duplicate downloaded lines.
Native video events still drive highlighting, seeking and replay strategies.
Select-lines sends the existing `CaptionCollector` payload, which takes the
unchanged validated `cupitorCaptionCapture` route into dialog1.

The remote module remembers up to five tracks in `sessionStorage`. The list
is restored on reload or SPA navigation back to a downloaded video. Clear
removes the saved track too. Storage failure does not stop the current loaded
transcript from working; this is a tab-session cache, not a permanent library.

Deploy the remote sidebar update and rebuild the app. Refresh a YouTube page
to pick up the new script. Older app versions expose no download button.

Tests:

```sh
flutter test test/youtube_sidebar_subtitles_test.dart test/stable_dialog_chrome_test.dart
```

The remote sidebar has separate integration coverage in
`db/js/youtube-download.test.mjs`, plus the existing caption and link tests.
