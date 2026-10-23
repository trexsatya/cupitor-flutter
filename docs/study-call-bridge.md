# Local study calls

Android-only simulated calls: no SIM call, calling provider, account, or phone
number. The native reminder rings; only an explicit **Answer** opens the question
and speaks its text and numbered alternatives. The user taps an alternative.
Speech recognition is not part of this version.

## Webapp integration

The language webapp exposes **Settings → Study calls** when `CallBridge` exists.
It can compose a question, copy text from a synced study reminder, call now,
schedule a one-off call, cancel a pending call, and view saved answers.

The bridge mirrors `NotifBridge`: JSON over a WebView channel and CustomEvents
back to the page, with one acknowledgement for every request.

```js
window.CallBridge.postMessage(JSON.stringify({
  op: 'schedule',
  request_id: 'example-1',
  title: 'Swedish practice',
  question: 'Which article goes with katt?',
  choices: ['ett', 'en'],
  language: 'sv-SE',
  when_ms: Date.now() + 60000
}));
window.addEventListener('cupitorCallAck', e => console.log(e.detail));
window.addEventListener('cupitorCalls', e => console.log(e.detail.calls));
```

The webapp also supplies `window.cupitorCallRpc(op, payload)`, a Promise API with
timeouts and request correlation. Read `getCalls` after a timed-out mutation
before retrying: timing out does not prove the native operation failed.

Operations:

| Operation | Input | Result in `cupitorCallAck.data` |
| --- | --- | --- |
| `getCapabilities` | — | `supported`, `permission`, `full_screen`, `exact_alarms`, `speech_input:false` |
| `requestPermission` | — | `permission` after the Android notification prompt |
| `openFullScreenSettings` | — | Opens Android special-access settings |
| `openAlarmSettings` | — | Opens exact-alarm settings |
| `getCalls` | — | `{version:1,calls:[...]}`, also emitted as `cupitorCalls` |
| `callNow` | `title,question,choices,language` | `{id,exact}` |
| `schedule` | Same fields plus future `when_ms` | `{id,exact}` |
| `cancel` | `id` | `true` (idempotent for terminal calls) |

Acknowledgements: `{request_id,op,ok,data?,error?}` in `cupitorCallAck`.
Snapshots: `{version:1,calls:[...]}` in `cupitorCalls`, also assigned to
`window.__cupitorCalls`. The host pushes history on page load, app resume,
profile changes, and bridge mutations. Results survive page/process death;
there is no dependency on the WebView staying alive to collect an answer.

Call rows contain `id,title,question,choices,language,when_ms,created_at,status`
and timestamps when available. A completed row adds zero-based `choice_index`
and `choice`. The host injects the active profile; callers cannot choose another
profile. History is scoped to that profile. Copied reminder text is a snapshot;
an answer is saved as a call result and does not change notification grading.

## Delivery and state

`scheduled → ringing → answered → completed`. Decline, cancellation, missed
ringing and interruption are terminal states. Duplicate answers cannot replace
a stored result. Alarms are rearmed after boot/app updates. More than five
minutes late becomes missed rather than ringing unexpectedly. Concurrent calls
do not replace the current question; overlapping fires become missed. Unanswered
ringing ends after 45 seconds. An unanswered active question expires after ten
minutes; a process death during an answered call is recorded as interrupted.

Bounds: 50 pending calls across profiles, last 200 terminal calls across
profiles, 2–9 alternatives (up to 200 characters each), 120-character title,
4000-character question, scheduled within 366 days. UTF-8 text and locale tags
such as `sv-SE` and `en-GB` are supported; the corresponding Android TTS voice
must be installed. The native screen and alternatives scroll for long content.

Notification permission is required. Without full-screen special access, a
scheduled call uses a heads-up notification with Answer/Decline actions. Without
exact-alarm access, Android schedules approximately and can delay delivery.
Android notification channel settings, silent mode and Do Not Disturb apply.
Full-screen access is requested explicitly via Android Settings; it is not
assumed or forced. A force-stopped app cannot receive alarms until reopened.

The Android integration is `cupitor/study_calls` (MethodChannel) and
`StudyCalls.kt`. Native activity speech stops when backgrounded; **Read again**
restarts it. Unsupported/missing voices leave readable text and answer buttons.
Study-call notifications use their own native channel and alarm identities;
the existing review scheduler's cancel-all operation must not remove them.

## Verification

- `flutter test test/study_call_bridge_test.dart`
- `cd android && ./gradlew :app:testReleaseUnitTest`
- Webapp: `node --test public/language/study-calls.test.mjs`
- On device: call now, Answer, hear all choices, select one, check history;
  schedule with app backgrounded/closed and screen locked; test full-screen
  permission off, notification permission denied, silent/DND, reboot,
  cancellation, timeout, missing TTS voice, long text, app process death, and
  switching profiles. No physical-device verification is implied by JVM tests.

Deploy the matching webapp source from `trexsatya/cupitor:music-study-app` and
install the updated Android build. Generated `trexsatya.github.io` app files are
not the source of this feature.
