# Notifications delivery — manual device checklist

Run on a real Android device (primary target) after installing a debug build
(`flutter build apk --debug` — verified compiling as of commit `07a1a06`).
Each item maps to spec §Delivery behavior no unit test can cover. None of
these are claimed as verified yet — this is the hand-off list.

## Android
- [ ] First run: from dialog1 devtools, `NotifBridge.postMessage(JSON.stringify({op:'getCapabilities',request_id:'t1'}))`
      reports real permission status; `requestPermission` shows the OS prompt (API 33+).
- [ ] Create a list via the webpage (or a devtools `createList` call) with a custom
      series schedule of short offsets; the notification fires on time.
- [ ] Notification shows Again/Good/Easy. **Tap Good with the APP KILLED** — the
      item updates (verify next launch: step advanced, `source:'action'` event
      recorded) and the app does not open. This exercises the background-isolate
      path that review C1 fixed; it is the single most important manual item.
- [ ] Tapping the body opens dialog1 at the item's open_url and the webpage
      receives `cupitorNotificationOpened`.
- [ ] Reboot the device: pending notifications survive (boot receiver).
- [ ] Deny exact alarms (Settings → Alarms & reminders): capabilities report
      `exact_alarms:false`; fires still arrive (inexact, may drift minutes).
- [ ] Airplane-mode + kill app for > 2 waking hours: on next launch the missed
      item advanced with an `auto` event; no notification burst beyond the
      per-fire cap (default 5).
- [ ] Grouping: 3 items due together → grouped under one list group in the shade.
- [ ] WorkManager safety net: `adb shell dumpsys jobscheduler | grep cupitor`
      shows the periodic job; after force-stopping the app, fires still resume
      within ~30 min of the next due time.

## iOS (blocked in the dev environment: Xcode 16.4 lacks the iOS 18.5 platform
## component; `ios/Podfile` now pins `platform :ios, '15.5'` and pods install)
- [ ] `flutter build ios` once the SDK component is installed.
- [ ] Permission prompt on requestPermission; actions appear on long-press.
- [ ] ≤ 60 armed: create 70+ near-term items, verify pendingNotificationRequests
      stays ≤ 60 (debug print in rearm() or Xcode console).

## macOS (debug build verified compiling)
- [ ] Notification fires while the app is open; actions grade.
- [ ] The 5-minute sweep timer also drains overdue items while open.

## Desktop (Linux/Windows) / Web
- [ ] Linux: due item posts via showNow within one 5-minute tick while the app
      is open (scheduled arming is a no-op on Linux — plugin limitation,
      guarded in rearm()).
- [ ] Windows/web: NoopNotifChannel — state advances silently on the tick;
      `getCapabilities` reports `actions:false`.

## Manager UI (Plan 3 — any platform)
- [ ] Tools sheet (web + EPUB surfaces) shows "Notification manager"; opens.
- [ ] With permission denied, the manager shows the banner; Enable triggers
      the OS prompt and the banner clears after grant.
- [ ] Changing the waking window / per-fire cap re-arms (verify: a pending
      fire inside the new sleep window disappears from the shade schedule).
- [ ] Create an app list with a short-offset custom series; add an item; it
      fires without any webpage involvement.
- [ ] Editing a custom schedule used by a list re-anchors the list's next
      fire; deleting is blocked (disabled trash icon) until reassigned.
- [ ] Manager mutations made while dialog1 is open push fresh
      `cupitorNotifLists` to the webpage on returning from the screen (web
      surface only).
