# YouTube controls in dialog1 (Android)

The Android host injects a small script into dialog1 and its YouTube embed
frames **before the first navigation**. The language webapp can then hide or
restore YouTube's overlays without recreating the `YT.Player`, changing the
video, seeking, or interrupting playback:

```js
// Check support: absent in regular browsers, other dialogs, and WebViews
// without Android's DOCUMENT_START_SCRIPT support.
const controls = window.CupitorYouTubeControls;
if (controls) {
  controls.setVisible(false); // Hide YouTube's title/channel, buttons and bars.
  controls.setVisible(true);  // Show YouTube's controls until hidden again.
  console.log(controls.visible); // Last requested visibility (a boolean).
}
```

`setVisible` requires a boolean. The object is available before the page's
scripts execute. Start the embed with `playerVars: {controls: 1}` (the default):
restoring visibility does not create controls omitted with `controls: 0`.

For example, connect it to the study player's existing tap/idle UI:

```js
function setStudyControlsVisible(visible) {
  // Update the webapp's own controls here too.
  window.CupitorYouTubeControls?.setVisible(visible);
}
// On tap/reveal:
setStudyControlsVisible(true);
// On the webapp's idle timer:
setStudyControlsVisible(false);
```

The webapp owns tap detection, reveal behavior and idle timers. This bridge
only applies the requested visibility; it installs no tap handlers or timers.

An explicit `setVisible(true)` holds the top and bottom control bars visible
until the next hide call. Before the first call, YouTube keeps its normal
automatic visibility behavior. Captions and playback are unaffected.

Optional notification in the main document:

```js
window.addEventListener('cupitorYouTubeControlsChanged', event => {
  console.log(event.detail.visible);
});
```

The requested state defaults to visible on each top-level page load. It is
sent to existing YouTube iframes immediately and to new/reloaded iframes when
their injected script announces readiness. Both `youtube.com/embed/…` and
`youtube-nocookie.com/embed/…` are supported, including their `www` hosts.

Only YouTube embed frames in **dialog1** receive the style override. Video,
poster images, captions, loading indicators and error messages are preserved.
The style uses YouTube's internal `ytp-*` classes; a YouTube markup change may
require updating the selector list. Ordinary browsers cannot perform this
cross-origin injection; they can use YouTube's initial `controls` parameter.

Run the self-contained bridge protocol tests with:

```sh
node --test test/js/youtube_controls.test.mjs
```
