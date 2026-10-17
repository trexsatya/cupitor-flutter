# Dialog1 host lifecycle signal

The Flutter host sends `cupitorAppLifecycle` CustomEvents on `window` when its
app lifecycle changes. The event is sent only to dialog1's webapp, including
when that dialog is minimized. It does not control a webapp timer itself.

```js
function applyHostLifecycle({state, isForeground}) {
  if (isForeground) {
    resumeStudyTimerIfAppropriate(); // your webapp's timer function
  } else {
    pauseStudyTimer();              // your webapp's timer function
  }
}

window.addEventListener('cupitorAppLifecycle', event => {
  applyHostLifecycle(event.detail);
});

// Optional immediate snapshot, if the initial page-load event already fired.
if (window.CupitorAppLifecycle) {
  applyHostLifecycle(window.CupitorAppLifecycle);
}
// Register the listener first, then request an up-to-date event.
window.AppLifecycleBridge?.postMessage('getState');
```

Each detail and snapshot has this shape:

```json
{"state":"paused","isForeground":false}
```

`state` is Flutter's `resumed`, `inactive`, `hidden`, `paused` or `detached`.
`isForeground` is true only for `resumed`. In particular, `inactive` pauses
promptly when focus is lost (for example, the notification shade, an incoming
call or a native dialog), before the WebView may be suspended. The webapp can
inspect the raw state if it needs different behavior for temporary focus loss.

The host also sends the current state after each page load and in response to
`AppLifecycleBridge.postMessage('getState')`. Handle repeated states
idempotently; a return to foreground should not restart a timer that the user
had already paused. A fresh page receives the current state rather than a
replay of old transitions. Older apps have neither this channel nor snapshot.

This describes the app lifecycle, not whether dialog1 is open. Abrupt process
termination cannot guarantee a final event, and background JavaScript may be
suspended by the OS. The foreground event refreshes state on return. Timer
accounting should therefore store its paused state rather than depend on
background timer ticks.

Validation: `flutter test test/dialog_app_lifecycle_test.dart` checks actual
Flutter lifecycle notifications, current-state requests, failed sends and
disposal. `node --test test/js/app_lifecycle.test.mjs` executes the emitted
JavaScript and checks timer signals and the late-listener snapshot.
