# Local study calls

Android-only simulated calls: no SIM call, calling provider, account, or phone
number. The native reminder rings; only an explicit **Answer** opens the question
and speaks its question. Answers can be multiple choice (spoken number/label or
tapped button) or free response (spoken or typed). Voice replies are enabled by
default when a system speech recognizer is available.

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
  response_type: 'choice',
  correct_choice_index: 1, // zero-based: en
  max_retries: 3,         // initial answer + up to 3 retries
  match_threshold: 0.8,  // fuzzy matching, 0.7–1.0
  voice_response: true,
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
| `getCapabilities` | — | `supported`, `permission`, `full_screen`, `exact_alarms`, `speech_input`, `answer_types`, `default_retries` |
| `requestPermission` | — | `permission` after the Android notification prompt |
| `openFullScreenSettings` | — | Opens Android special-access settings |
| `openAlarmSettings` | — | Opens exact-alarm settings |
| `getCalls` | — | `{version:1,calls:[...]}`, also emitted as `cupitorCalls` |
| `callNow` | `title,question,language`, answer fields below | `{id,exact}` |
| `schedule` | Same fields plus future `when_ms` | `{id,exact}` |
| `cancel` | `id` | `true` (idempotent for terminal calls) |

Acknowledgements: `{request_id,op,ok,data?,error?}` in `cupitorCallAck`.
Snapshots: `{version:1,calls:[...]}` in `cupitorCalls`, also assigned to
`window.__cupitorCalls`. The host pushes history on page load, app resume,
profile changes, and bridge mutations. Results survive page/process death;
there is no dependency on the WebView staying alive to collect an answer.

Call rows contain `id,title,question,choices,language,when_ms,created_at,status`
and timestamps when available. A completed row adds zero-based `choice_index`
and `choice` for multiple choice. All final responses include `answer`,
`response_mode` (`voice`, `typed`, or `tap`), `correct` and an `attempts` array.
Voice answers include `spoken_response`; attempts retain the text, marking,
mode, timestamp and a reason for missing/unrecognized speech. The host injects the active profile; callers cannot choose another
profile. History is scoped to that profile. Copied reminder text is a snapshot;
an answer is saved as a call result and does not change notification grading.

## Questions, marking and retries

- `response_type: 'choice'`: 2–9 `choices` and zero-based
  `correct_choice_index`. The web composer requires a correct alternative.
  Older bridge callers that omit the correct index retain ungraded behavior.
- `response_type: 'text'`: `accepted_answers`, 1–20 spellings/phrases of up to
  500 characters each. `choices` can be omitted. For example:

  ```js
  await window.cupitorCallRpc('callNow', {
    title: 'Geografi', question: 'Vad heter Sveriges huvudstad?',
    response_type: 'text', accepted_answers: ['Stockholm', 'Stockholms stad'],
    language: 'sv-SE', voice_response: true, max_retries: 3,
    match_threshold: 0.8
  });
  ```

- `max_retries` defaults to **3 retries after the first attempt** (4 answers in
  total), configurable from 0 to 10. A correct answer stops immediately. Wrong
  answers, ambiguous/unrecognized speech, silence and transient recognition
  errors consume attempts, repeat the question and listen again automatically
  within the same call. After the last attempt the call becomes `failed`.
  Missing speech services, unsupported language or denied microphone permission
  leave the on-screen fallback available instead of looping permission prompts.
- `match_threshold` defaults to 0.8 (range 0.7–1.0). Matching normalizes case,
  Unicode and whitespace, discounts accent errors and tolerates small character
  errors/word spacing. Changed numbers and English/Swedish negations are rejected;
  short words stay exact because one letter can change their meaning. Add accepted
  variants for short words or different phrasings. This is approximate text
  matching, not semantic/AI grading of arbitrary essays.
- Spoken alternatives accept English/Swedish number words, digits, explicit
  phrases such as “option two” / “alternativ nummer två”, and fuzzy label text.
  An exact label takes precedence over a number alias (for `[ett, en]`, “en” is
  the second label). Competing close label matches or conflicting recognition
  hypotheses cause a retry rather than guessing a choice.
- Free speech is graded from the recognizer's first final nonblank transcript;
  partial transcripts never submit. The native screen displays attempt count,
  provides an explicit voice retry/stop button, and keeps choice buttons or a
  typed answer field available. Completion shows correct/saved/exhausted feedback.

## Voice lifecycle

Recognition starts only after the question has finished speaking and only while
its answered native screen is resumed. `voice_response:false` disables the
microphone for that question. Android requests `RECORD_AUDIO` when needed; denial
keeps the on-screen fallback. Reading again first cancels recognition. Listening
first stops TTS and releases its audio focus, avoiding recognition of the app's
own prompt. Each recognition attempt has a 15-second watchdog.

Pause, close, cancellation, selecting a button and completing an answer cancel
and destroy the recognizer. Per-attempt generation tokens reject late results
and duplicate callbacks. Question retries share the durable attempt budget; a
cancelled listening session never counts as a wrong answer. The phone's installed
recognition service may require a network connection; this does not place a SIM
or paid telephone call.

## Delivery and state

`scheduled → ringing → answered → completed` (correct) or `failed` (budget used).
An incorrect attempt remains `answered` while the question is retried. Decline, cancellation, missed
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
must be installed. Free responses need no alternative buttons. The native screen and alternatives scroll for long content.

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
  switching profiles. Also check microphone denial, automatic listening after
  TTS, fuzzy matches, ambiguous choices, free speech/typing, silence/transient
  errors, wrong→correct retries, retry exhaustion, and late callbacks after
  backgrounding. No physical-device verification is implied by JVM tests.

Deploy the matching webapp source from `trexsatya/cupitor:music-study-app` and
install the updated Android build. Generated `trexsatya.github.io` app files are
not the source of this feature.
