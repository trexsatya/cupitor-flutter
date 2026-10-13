# Multi-user Cupitor — App Sign-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Cupitor app signs a user in to GitHub with the OAuth device flow (no secret, scope `public_repo`), stores the token where it already keeps `githubToken`, and answers the language webapp's sign-in / sign-out / status requests over a new `AccountBridge` JS channel.

**Architecture:** Three focused files under `lib/account/`. `github_device_signin.dart` is the pure device flow over an injected `http.Client` (request a code, poll for the token honouring `slow_down`, map `expired_token` / `access_denied`). `device_signin_dialog.dart` is the native dialog that shows the code, opens `github.com/login/device`, and resolves to a token. `account_bridge.dart` mirrors `NotifBridge`: injected callbacks, one ack event per message, nothing escapes into the channel. `main.dart` wires the channel on the dialog1 WebView, adds a "Sign in with GitHub" entry beside the existing paste-token dialog (which stays as the fallback), and routes token storage through one helper.

**Tech Stack:** Flutter/Dart 3.8, `http` (+ `package:http/testing.dart` `MockClient` for tests), `shared_preferences`, `url_launcher` (already a dependency), `webview_flutter`.

**Spec:** `docs/superpowers/specs/2026-10-13-multi-user-design.md` §Flutter app changes. The spec is the contract; if plan and spec disagree, stop and say so.

---

## Conventions for the executor

- Repo root: `/Users/satyendra.kumar/Documents/PersonalProjects/flutter/Cupitor`, branch `main`.
- Flutter is not on PATH: `export PATH=/Users/satyendra.kumar/Documents/PersonalProjects/flutter/flutter/bin:$PATH` first in each Bash call, or use the absolute path `/Users/satyendra.kumar/Documents/PersonalProjects/flutter/flutter/bin/flutter`.
- Run tests: `flutter test test/account -r expanded`. Analyze: `flutter analyze lib/account test/account`.
- No `pubspec.yaml` change is needed. If you do edit it for any reason, run `flutter pub get --offline` once afterwards (sandboxed network resolution fails otherwise).
- `lib/main.dart` (~11.7k lines) **has unrelated uncommitted changes** (also `pubspec.yaml`, `macos/Runner/MainFlutterWindow.swift`). Before the first commit that touches `main.dart`, run `git diff --stat lib/main.dart`; if it is already modified, stop and ask the user to commit or stash first. Stage only the files a task touched (`git add <paths>`, never `git add -A`).
- `test/widget_test.dart` has failed to compile since the initial commit; a full `flutter test` always reports exactly that one failure. Run `test/account` and `test/notif` instead.
- Every commit message ends with the trailer line: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Code is authoritative over comments.
- The webapp side of the bridge is built by `docs/superpowers/plans/2026-10-13-multi-user-webapp.md` (Task 18 there). Either plan can ship first: the webapp degrades to "not available" without the channel, and the app's channel is harmless without a caller.

---

## Bridge message contract (shared with the webapp plan — must stay identical in both)

The app registers a JS channel named `AccountBridge` on the dialog1 WebView. In a plain browser the channel does not exist and the webapp shows "not available in a browser" for in-app sign-in.

**JS → Dart** — `window.AccountBridge.postMessage(JSON.stringify(msg))`

```json
{ "op": "signIn" | "signOut" | "getStatus", "request_id": "<string, unique per call>" }
```

**Dart → JS** — one `CustomEvent` named `cupitorAccountAck` per message, dispatched on `window`; the same object is also stored on `window.__cupitorAccountAck` just before the dispatch (the app's global-then-dispatch pattern).

```json
{ "request_id": "<echoed, or null when the request could not be parsed>",
  "op": "<echoed op, or \"unknown\">",
  "ok": true | false,
  "error": "<only when ok is false>",
  "data": { "signed_in": true | false }   // present when ok is true for signIn and getStatus
}
```

| op | Effect in the app | `ok:true` data | `ok:false` error |
|---|---|---|---|
| `signIn` | Runs the GitHub device flow in a native dialog; on success stores the token where the app keeps `githubToken` | `{signed_in:true}` | `cancelled` (user closed the dialog), `denied` (user declined on GitHub), `expired` (code timed out), `network`, `busy` (a sign-in is already running), `internal` |
| `signOut` | Clears the stored token | `{signed_in:false}` | `internal` |
| `getStatus` | Nothing | `{signed_in: <bool>}` | — |
| anything else | — | — | `unknown_op`; unparsable JSON gives `bad_json` with `request_id: null` |

The token never crosses the bridge. After `signed_in:true` the webapp learns who it is with `GET /user` through `GitHubProxy`, which attaches the token.

---

## GitHub device flow facts the code relies on

- `POST https://github.com/login/device/code` with header `Accept: application/json` and form body `client_id=Ov23linnANScOoh6elAJ&scope=public_repo` → `200 {"device_code","user_code","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}`.
- `POST https://github.com/login/oauth/access_token` with `Accept: application/json` and form body `client_id`, `device_code`, `grant_type=urn:ietf:params:oauth:grant-type:device_code` → `200` with either `{"access_token":"gh…","token_type":"bearer","scope":"public_repo"}` or `{"error": "authorization_pending" | "slow_down" | "expired_token" | "access_denied" | …}`. A `slow_down` reply carries a new `interval` (the old one plus 5 s).
- These two endpoints do not send CORS headers, which is why the device flow lives in the app only.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/account/github_device_signin.dart` (new) | `DeviceCode`, `DeviceSignInException`, `GitHubDeviceSignIn.requestCode()` / `pollForToken()`. Pure; `http.Client`, sleep and clock injected. |
| `lib/account/device_signin_dialog.dart` (new) | `showDeviceSignInDialog(context)` → `Future<String?>`; the dialog widget. |
| `lib/account/account_bridge.dart` (new) | `AccountBridge.handle(raw)`; acks via injected `emit`. |
| `lib/main.dart` (modify) | `_setGithubToken`, "Sign in with GitHub" tile, `_accountBridge`, channel registration. |
| `docs/webapp-integration-spec.md` (modify) | The `AccountBridge` contract, current state. |
| `test/account/*.dart` (new) | Unit tests with `MockClient`; widget tests for the dialog. |

---

### Task 1: Device flow — request a code

**Files:**
- Create: `lib/account/github_device_signin.dart`
- Test: `test/account/github_device_signin_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/account/github_device_signin_test.dart`:

```dart
import 'dart:convert';

import 'package:cupitor/account/github_device_signin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> codeJson() => {
      'device_code': 'dc-1',
      'user_code': 'ABCD-1234',
      'verification_uri': 'https://github.com/login/device',
      'expires_in': 899,
      'interval': 5,
    };

void main() {
  group('requestCode', () {
    test('posts client id and scope as a form and parses the reply', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode(codeJson()), 200);
      });
      final flow = GitHubDeviceSignIn(client: client, sleep: (_) async {});
      final code = await flow.requestCode();
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://github.com/login/device/code');
      expect(seen.headers['Accept'], 'application/json');
      expect(seen.bodyFields, {'client_id': GitHubDeviceSignIn.clientId, 'scope': 'public_repo'});
      expect(GitHubDeviceSignIn.clientId, 'Ov23linnANScOoh6elAJ');
      expect(code.deviceCode, 'dc-1');
      expect(code.userCode, 'ABCD-1234');
      expect(code.verificationUri, 'https://github.com/login/device');
      expect(code.interval, const Duration(seconds: 5));
      expect(code.expiresIn, const Duration(seconds: 899));
    });

    test('a non-200 or an error body is an error; a thrown client is network', () async {
      final bad = GitHubDeviceSignIn(client: MockClient((_) async => http.Response('nope', 500)), sleep: (_) async {});
      await expectLater(bad.requestCode(), throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'error')));
      final errBody = GitHubDeviceSignIn(client: MockClient((_) async => http.Response('{"error":"device_flow_disabled"}', 200)), sleep: (_) async {});
      await expectLater(errBody.requestCode(), throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'error')));
      final offline = GitHubDeviceSignIn(client: MockClient((_) async => throw http.ClientException('offline')), sleep: (_) async {});
      await expectLater(offline.requestCode(), throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'network')));
    });
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `flutter test test/account/github_device_signin_test.dart -r expanded`
Expected: FAIL — `package:cupitor/account/github_device_signin.dart` not found.

- [ ] **Step 3: Create the module**

Create `lib/account/github_device_signin.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// GitHub's OAuth device flow for the "Cupitor" OAuth app: no client secret,
/// scope `public_repo`, tokens that do not expire. Pure: the HTTP client, the
/// sleep and the clock are injected so tests run without time or network.
///
/// Flow: [requestCode] → show `userCode`, open `verificationUri` →
/// [pollForToken] until GitHub hands back the token or says no.
class DeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final Duration interval;
  final Duration expiresIn;

  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresIn,
  });

  factory DeviceCode.fromJson(Map<String, dynamic> j) => DeviceCode(
        deviceCode: j['device_code'] as String,
        userCode: j['user_code'] as String,
        verificationUri: (j['verification_uri'] as String?) ?? 'https://github.com/login/device',
        interval: Duration(seconds: (j['interval'] as num?)?.toInt() ?? 5),
        expiresIn: Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 900),
      );
}

/// `code` is one of: `denied` (the user declined), `expired` (the code ran
/// out), `cancelled` (the caller gave up), `network`, `error` (anything else
/// GitHub said). These are the bridge's error strings too.
class DeviceSignInException implements Exception {
  final String code;
  final String message;
  const DeviceSignInException(this.code, this.message);
  @override
  String toString() => 'DeviceSignInException($code): $message';
}

typedef Sleep = Future<void> Function(Duration d);

class GitHubDeviceSignIn {
  static const clientId = 'Ov23linnANScOoh6elAJ';
  static const scope = 'public_repo';
  static final codeUrl = Uri.parse('https://github.com/login/device/code');
  static final tokenUrl = Uri.parse('https://github.com/login/oauth/access_token');
  static const _timeout = Duration(seconds: 15);

  final http.Client _client;
  final Sleep _sleep;
  final DateTime Function() _now;

  GitHubDeviceSignIn({http.Client? client, Sleep? sleep, DateTime Function()? now})
      : _client = client ?? http.Client(),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? DateTime.now;

  Future<Map<String, dynamic>> _post(Uri url, Map<String, String> form) async {
    final http.Response r;
    try {
      r = await _client
          .post(url, headers: const {'Accept': 'application/json'}, body: form)
          .timeout(_timeout);
    } catch (e) {
      throw DeviceSignInException('network', '$e');
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw DeviceSignInException('error', 'HTTP ${r.statusCode}');
    }
    if (r.statusCode != 200 && j['error'] == null) {
      throw DeviceSignInException('error', 'HTTP ${r.statusCode}');
    }
    return j;
  }

  Future<DeviceCode> requestCode() async {
    final j = await _post(codeUrl, {'client_id': clientId, 'scope': scope});
    if (j['error'] != null) throw DeviceSignInException('error', '${j['error']}');
    return DeviceCode.fromJson(j);
  }

  // pollForToken is added in Task 2.
}
```

- [ ] **Step 4: Run the test**

Run: `flutter test test/account/github_device_signin_test.dart -r expanded`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/account/github_device_signin.dart test/account/github_device_signin_test.dart
git commit -m "account: request a GitHub device code

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Device flow — poll for the token

**Files:**
- Modify: `lib/account/github_device_signin.dart`
- Test: `test/account/github_device_signin_test.dart`

- [ ] **Step 1: Write the failing tests**

Append inside `main()` in `test/account/github_device_signin_test.dart`:

```dart
  group('pollForToken', () {
    final code = DeviceCode.fromJson(codeJson());

    // A GitHub that answers the token endpoint with `replies` in order and
    // records every sleep.
    ({GitHubDeviceSignIn flow, List<Duration> sleeps, List<http.Request> posts}) world(List<Map<String, Object?>> replies, {DateTime Function()? now}) {
      final sleeps = <Duration>[];
      final posts = <http.Request>[];
      var i = 0;
      final client = MockClient((req) async {
        posts.add(req);
        final r = replies[i < replies.length ? i : replies.length - 1];
        i++;
        return http.Response(jsonEncode(r), 200);
      });
      return (
        flow: GitHubDeviceSignIn(client: client, sleep: (d) async => sleeps.add(d), now: now),
        sleeps: sleeps,
        posts: posts,
      );
    }

    test('approved after pending: waits the interval each time, posts the grant', () async {
      final w = world([
        {'error': 'authorization_pending'},
        {'error': 'authorization_pending'},
        {'access_token': 'ghu_ok', 'token_type': 'bearer', 'scope': 'public_repo'},
      ]);
      expect(await w.flow.pollForToken(code), 'ghu_ok');
      expect(w.sleeps, [const Duration(seconds: 5), const Duration(seconds: 5), const Duration(seconds: 5)]);
      expect(w.posts.first.url.toString(), 'https://github.com/login/oauth/access_token');
      expect(w.posts.first.bodyFields, {
        'client_id': GitHubDeviceSignIn.clientId,
        'device_code': 'dc-1',
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
    });

    test('slow_down raises the interval (GitHub says by how much)', () async {
      final w = world([
        {'error': 'slow_down', 'interval': 10},
        {'error': 'authorization_pending'},
        {'access_token': 'ghu_ok'},
      ]);
      expect(await w.flow.pollForToken(code), 'ghu_ok');
      expect(w.sleeps, [const Duration(seconds: 5), const Duration(seconds: 10), const Duration(seconds: 10)]);
    });

    test('slow_down without an interval adds five seconds', () async {
      final w = world([{'error': 'slow_down'}, {'access_token': 'ghu_ok'}]);
      await w.flow.pollForToken(code);
      expect(w.sleeps, [const Duration(seconds: 5), const Duration(seconds: 10)]);
    });

    test('expired_token → expired; access_denied → denied; other errors → error', () async {
      await expectLater(world([{'error': 'expired_token'}]).flow.pollForToken(code),
          throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'expired')));
      await expectLater(world([{'error': 'access_denied'}]).flow.pollForToken(code),
          throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'denied')));
      await expectLater(world([{'error': 'incorrect_device_code'}]).flow.pollForToken(code),
          throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'error')));
    });

    test('the local clock passing expires_in → expired without another post', () async {
      var t = DateTime(2026, 1, 1, 12, 0, 0);
      final w = world([{'error': 'authorization_pending'}], now: () => t);
      // Each sleep moves the clock 10 minutes; the code lasts ~15.
      final flow = GitHubDeviceSignIn(
        client: MockClient((req) async { w.posts.add(req); return http.Response('{"error":"authorization_pending"}', 200); }),
        sleep: (_) async => t = t.add(const Duration(minutes: 10)),
        now: () => t,
      );
      await expectLater(flow.pollForToken(code), throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'expired')));
      expect(w.posts.length, 1);
    });

    test('cancelled() stops the loop', () async {
      var asked = 0;
      final w = world([{'error': 'authorization_pending'}]);
      await expectLater(
        w.flow.pollForToken(code, cancelled: () => ++asked > 1),
        throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'cancelled')),
      );
    });

    test('a thrown client is network', () async {
      final flow = GitHubDeviceSignIn(client: MockClient((_) async => throw http.ClientException('offline')), sleep: (_) async {});
      await expectLater(flow.pollForToken(code), throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', 'network')));
    });
  });
```

- [ ] **Step 2: Run to see them fail**

Run: `flutter test test/account/github_device_signin_test.dart -r expanded`
Expected: FAIL — `pollForToken` is not defined.

- [ ] **Step 3: Implement**

Replace the line `  // pollForToken is added in Task 2.` in `lib/account/github_device_signin.dart` with:

```dart
  /// Polls until GitHub returns the token. Waits `interval` before every
  /// attempt (GitHub rate-limits the first one too), grows it on
  /// `slow_down`, and gives up at `expiresIn`. `cancelled` is checked before
  /// each attempt so a closed dialog stops the loop.
  Future<String> pollForToken(DeviceCode code, {bool Function()? cancelled}) async {
    var interval = code.interval;
    final deadline = _now().add(code.expiresIn);
    while (true) {
      if (cancelled?.call() ?? false) throw const DeviceSignInException('cancelled', 'cancelled');
      if (_now().isAfter(deadline)) throw const DeviceSignInException('expired', 'the code expired');
      await _sleep(interval);
      if (cancelled?.call() ?? false) throw const DeviceSignInException('cancelled', 'cancelled');
      if (_now().isAfter(deadline)) throw const DeviceSignInException('expired', 'the code expired');
      final j = await _post(tokenUrl, {
        'client_id': clientId,
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      final token = j['access_token'];
      if (token is String && token.isNotEmpty) return token;
      switch (j['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          final next = (j['interval'] as num?)?.toInt();
          interval = Duration(seconds: next ?? (interval.inSeconds + 5));
          continue;
        case 'expired_token':
          throw const DeviceSignInException('expired', 'the code expired');
        case 'access_denied':
          throw const DeviceSignInException('denied', 'sign-in was declined');
        default:
          throw DeviceSignInException('error', '${j['error'] ?? 'no token in the reply'}');
      }
    }
  }
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/account/github_device_signin_test.dart -r expanded`
Expected: PASS (9 tests). Check the "cancelled" test in particular: `cancelled` is asked before the sleep (1) and after it (2) → the second answer is true → the loop stops before the first post.

- [ ] **Step 5: Commit**

```bash
git add lib/account/github_device_signin.dart test/account/github_device_signin_test.dart
git commit -m "account: poll GitHub for the device-flow token, honouring slow_down, expiry and denial

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `AccountBridge` — the JS channel handler

**Files:**
- Create: `lib/account/account_bridge.dart`
- Test: `test/account/account_bridge_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/account/account_bridge_test.dart`:

```dart
import 'dart:async';

import 'package:cupitor/account/account_bridge.dart';
import 'package:cupitor/account/github_device_signin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<(String, Map<String, Object?>)> events;
  late List<String> stored;
  late int signOuts;
  late bool hasToken;
  Future<String?> Function() signIn = () async => 'ghu_x';

  AccountBridge make() => AccountBridge(
        signIn: () => signIn(),
        storeToken: (t) async => stored.add(t),
        signOut: () async { signOuts++; hasToken = false; },
        hasToken: () => hasToken,
        emit: (e, d) => events.add((e, d)),
      );

  setUp(() {
    events = [];
    stored = [];
    signOuts = 0;
    hasToken = false;
    signIn = () async => 'ghu_x';
  });

  Map<String, Object?> lastAck() => events.last.$2;

  test('signIn stores the token and acks signed_in with the request id', () async {
    await make().handle('{"op":"signIn","request_id":"r1"}');
    expect(stored, ['ghu_x']);
    expect(events.single.$1, AccountBridge.ackEvent);
    expect(lastAck(), {'request_id': 'r1', 'op': 'signIn', 'ok': true, 'data': {'signed_in': true}});
  });

  test('a closed dialog is cancelled; nothing is stored', () async {
    signIn = () async => null;
    await make().handle('{"op":"signIn","request_id":"r2"}');
    expect(stored, isEmpty);
    expect(lastAck(), {'request_id': 'r2', 'op': 'signIn', 'ok': false, 'error': 'cancelled'});
  });

  test('device-flow failures map to their code; anything else is internal', () async {
    for (final code in ['denied', 'expired', 'network']) {
      signIn = () async => throw DeviceSignInException(code, 'x');
      await make().handle('{"op":"signIn","request_id":"$code"}');
      expect(lastAck(), {'request_id': code, 'op': 'signIn', 'ok': false, 'error': code});
    }
    signIn = () async => throw StateError('boom');
    await make().handle('{"op":"signIn","request_id":"r3"}');
    expect(lastAck()['error'], 'internal');
  });

  test('a second signIn while one is running is busy; the first still completes', () async {
    final gate = Completer<String?>();
    signIn = () => gate.future;
    final bridge = make();
    final first = bridge.handle('{"op":"signIn","request_id":"a"}');
    await bridge.handle('{"op":"signIn","request_id":"b"}');
    expect(lastAck(), {'request_id': 'b', 'op': 'signIn', 'ok': false, 'error': 'busy'});
    gate.complete('ghu_y');
    await first;
    expect(stored, ['ghu_y']);
    expect(events.where((e) => e.$2['request_id'] == 'a').single.$2['ok'], true);
    // And a third one after completion runs again.
    signIn = () async => 'ghu_z';
    await bridge.handle('{"op":"signIn","request_id":"c"}');
    expect(lastAck()['ok'], true);
  });

  test('signOut clears the token and acks signed_in:false', () async {
    hasToken = true;
    await make().handle('{"op":"signOut","request_id":"s"}');
    expect(signOuts, 1);
    expect(lastAck(), {'request_id': 's', 'op': 'signOut', 'ok': true, 'data': {'signed_in': false}});
  });

  test('getStatus reports whether a token is stored', () async {
    await make().handle('{"op":"getStatus","request_id":"g1"}');
    expect(lastAck()['data'], {'signed_in': false});
    hasToken = true;
    await make().handle('{"op":"getStatus","request_id":"g2"}');
    expect(lastAck(), {'request_id': 'g2', 'op': 'getStatus', 'ok': true, 'data': {'signed_in': true}});
  });

  test('bad json and unknown ops are acked, never thrown', () async {
    final bridge = make();
    await bridge.handle('{nope');
    expect(lastAck(), {'request_id': null, 'op': 'unknown', 'ok': false, 'error': 'bad_json'});
    await bridge.handle('{"op":"dance","request_id":"u"}');
    expect(lastAck(), {'request_id': 'u', 'op': 'dance', 'ok': false, 'error': 'unknown_op'});
    await bridge.handle('{"request_id":"v"}');
    expect(lastAck(), {'request_id': 'v', 'op': 'unknown', 'ok': false, 'error': 'unknown_op'});
  });
}
```

- [ ] **Step 2: Run to see them fail**

Run: `flutter test test/account/account_bridge_test.dart -r expanded`
Expected: FAIL — module not found.

- [ ] **Step 3: Create the module**

Create `lib/account/account_bridge.dart`:

```dart
import 'dart:convert';

import 'github_device_signin.dart';

// Its own name: notif_bridge.dart declares an `EmitEvent` with the same
// shape, and main.dart imports both files.
typedef AccountEmit = void Function(String event, Map<String, Object?> detail);

/// The `AccountBridge` JS-channel handler. Contract (also in
/// docs/webapp-integration-spec.md):
///   JS → Dart  { op: 'signIn' | 'signOut' | 'getStatus', request_id }
///   Dart → JS  CustomEvent 'cupitorAccountAck'
///              { request_id, op, ok, error?, data?: { signed_in } }
/// Mirrors NotifBridge: every dependency is injected, every path acks, and
/// nothing escapes into the channel. The token itself never crosses.
class AccountBridge {
  static const ackEvent = 'cupitorAccountAck';

  /// Runs the native sign-in UI. Resolves to the token, or null when the
  /// user closed it; throws [DeviceSignInException] for GitHub's answers.
  final Future<String?> Function() signIn;
  final Future<void> Function(String token) storeToken;
  final Future<void> Function() signOut;
  final bool Function() hasToken;
  final AccountEmit emit;

  bool _signingIn = false;

  AccountBridge({
    required this.signIn,
    required this.storeToken,
    required this.signOut,
    required this.hasToken,
    required this.emit,
  });

  void _ack(String? reqId, String op, bool ok, {String? error, Map<String, Object?>? data}) {
    emit(ackEvent, {
      'request_id': reqId,
      'op': op,
      'ok': ok,
      if (error != null) 'error': error,
      if (data != null) 'data': data,
    });
  }

  Future<void> handle(String raw) async {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _ack(null, 'unknown', false, error: 'bad_json');
      return;
    }
    final op = m['op'] is String ? m['op'] as String : 'unknown';
    final reqId = m['request_id'] is String ? m['request_id'] as String : null;
    try {
      switch (op) {
        case 'signIn':
          await _signIn(reqId);
        case 'signOut':
          await signOut();
          _ack(reqId, op, true, data: {'signed_in': false});
        case 'getStatus':
          _ack(reqId, op, true, data: {'signed_in': hasToken()});
        default:
          _ack(reqId, op, false, error: 'unknown_op');
      }
    } catch (_) {
      _ack(reqId, op, false, error: 'internal');
    }
  }

  Future<void> _signIn(String? reqId) async {
    const op = 'signIn';
    if (_signingIn) {
      _ack(reqId, op, false, error: 'busy');
      return;
    }
    _signingIn = true;
    try {
      final token = await signIn();
      if (token == null || token.isEmpty) {
        _ack(reqId, op, false, error: 'cancelled');
        return;
      }
      await storeToken(token);
      _ack(reqId, op, true, data: {'signed_in': true});
    } on DeviceSignInException catch (e) {
      _ack(reqId, op, false, error: e.code);
    } catch (_) {
      _ack(reqId, op, false, error: 'internal');
    } finally {
      _signingIn = false;
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/account/account_bridge_test.dart -r expanded`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/account/account_bridge.dart test/account/account_bridge_test.dart
git commit -m "account: AccountBridge answers signIn, signOut and getStatus with acks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The device sign-in dialog

**Files:**
- Create: `lib/account/device_signin_dialog.dart`
- Test: `test/account/device_signin_dialog_test.dart`

- [ ] **Step 1: Write the failing widget tests**

Create `test/account/device_signin_dialog_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:cupitor/account/device_signin_dialog.dart';
import 'package:cupitor/account/github_device_signin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _code = {
  'device_code': 'dc-1', 'user_code': 'ABCD-1234',
  'verification_uri': 'https://github.com/login/device', 'expires_in': 899, 'interval': 5,
};

/// A GitHub that hands out the code, then answers the token endpoint with
/// `tokenReplies` in order (repeating the last).
http.Client github(List<Map<String, Object?>> tokenReplies) {
  var i = 0;
  return MockClient((req) async {
    if (req.url.path == '/login/device/code') return http.Response(jsonEncode(_code), 200);
    final r = tokenReplies[i < tokenReplies.length ? i : tokenReplies.length - 1];
    i++;
    return http.Response(jsonEncode(r), 200);
  });
}

/// A few frames with time passing. The dialog shows an indeterminate
/// spinner, so pumpAndSettle would never settle; bounded pumps are enough
/// for the MockClient futures and setStates to land.
Future<void> pumps(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Pumps a page with one button that opens the dialog; returns the dialog's
/// future and the URIs the dialog asked to open.
Future<({Future<String?> result, List<Uri> opened})> open(WidgetTester tester, GitHubDeviceSignIn flow) async {
  final opened = <Uri>[];
  final done = Completer<String?>();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () async {
          done.complete(await showDeviceSignInDialog(ctx, flow: flow, launch: (u) async { opened.add(u); return true; }));
        },
        child: const Text('go'),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await pumps(tester);
  return (result: done.future, opened: opened);
}

void main() {
  testWidgets('shows the user code, opens GitHub, and returns the token', (tester) async {
    final gate = Completer<void>();
    final flow = GitHubDeviceSignIn(client: github([{'error': 'authorization_pending'}, {'access_token': 'ghu_x'}]), sleep: (_) => gate.future);
    final o = await open(tester, flow);
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Open GitHub'));
    await tester.pump();
    expect(o.opened.single.toString(), 'https://github.com/login/device');
    gate.complete();
    await pumps(tester);
    expect(await o.result, 'ghu_x');
    await pumps(tester, 20); // the dialog's exit animation
    expect(find.text('ABCD-1234'), findsNothing);
  });

  testWidgets('Cancel closes with null', (tester) async {
    final gate = Completer<void>();
    final flow = GitHubDeviceSignIn(client: github([{'error': 'authorization_pending'}]), sleep: (_) => gate.future);
    final o = await open(tester, flow);
    await tester.tap(find.text('Cancel'));
    await pumps(tester);
    expect(await o.result, isNull);
    gate.complete(); // lets the abandoned poll finish (it sees _cancelled and stops)
    await pumps(tester);
  });

  testWidgets('a declined sign-in shows the reason and offers Retry', (tester) async {
    var round = 0;
    final client = MockClient((req) async {
      if (req.url.path == '/login/device/code') return http.Response(jsonEncode(_code), 200);
      round++;
      return http.Response(jsonEncode(round == 1 ? {'error': 'access_denied'} : {'access_token': 'ghu_second'}), 200);
    });
    final flow = GitHubDeviceSignIn(client: client, sleep: (_) async {});
    final o = await open(tester, flow);
    expect(find.text('GitHub sign-in was declined.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await pumps(tester);
    expect(await o.result, 'ghu_second');
  });
}
```

- [ ] **Step 2: Run to see them fail**

Run: `flutter test test/account/device_signin_dialog_test.dart -r expanded`
Expected: FAIL — module not found.

- [ ] **Step 3: Create the dialog**

Create `lib/account/device_signin_dialog.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'github_device_signin.dart';

typedef LaunchUrl = Future<bool> Function(Uri uri);

/// Native GitHub sign-in: shows the one-time code, opens
/// github.com/login/device, and resolves to the token once GitHub approves.
/// Resolves to null when the user cancels. Errors from GitHub (declined,
/// expired, offline) are shown in the dialog with a Retry.
Future<String?> showDeviceSignInDialog(BuildContext context, {GitHubDeviceSignIn? flow, LaunchUrl? launch}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DeviceSignInDialog(
      flow: flow ?? GitHubDeviceSignIn(),
      launch: launch ?? ((u) => launchUrl(u, mode: LaunchMode.externalApplication)),
    ),
  );
}

class DeviceSignInDialog extends StatefulWidget {
  final GitHubDeviceSignIn flow;
  final LaunchUrl launch;
  const DeviceSignInDialog({super.key, required this.flow, required this.launch});

  @override
  State<DeviceSignInDialog> createState() => _DeviceSignInDialogState();
}

class _DeviceSignInDialogState extends State<DeviceSignInDialog> {
  DeviceCode? _code;
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() { _code = null; _error = null; });
    try {
      final code = await widget.flow.requestCode();
      if (!mounted || _cancelled) return;
      setState(() => _code = code);
      final token = await widget.flow.pollForToken(code, cancelled: () => _cancelled);
      if (!mounted || _cancelled) return;
      Navigator.of(context).pop(token);
    } on DeviceSignInException catch (e) {
      if (!mounted || _cancelled) return;
      setState(() => _error = switch (e.code) {
            'denied' => 'GitHub sign-in was declined.',
            'expired' => 'The code expired. Try again.',
            'network' => 'Could not reach GitHub. Check the connection and retry.',
            _ => 'Sign-in failed: ${e.message}',
          });
    }
  }

  void _cancel() {
    _cancelled = true;
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final error = _error;
    Widget body;
    if (error != null) {
      body = Text(error);
    } else if (code == null) {
      body = const Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 12),
        Text('Asking GitHub for a code…'),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Enter this code on GitHub, then approve the Cupitor app:'),
        const SizedBox(height: 12),
        Center(
          child: SelectableText(
            code.userCode,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open GitHub'),
            onPressed: () => widget.launch(Uri.parse(code.verificationUri)),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy code'),
            onPressed: () => Clipboard.setData(ClipboardData(text: code.userCode)),
          ),
        ]),
        const SizedBox(height: 12),
        const Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Waiting for approval…'),
        ]),
      ]);
    }
    return AlertDialog(
      title: const Text('Sign in with GitHub'),
      content: body,
      actions: [
        if (error != null) TextButton(onPressed: _start, child: const Text('Retry')),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/account/device_signin_dialog_test.dart -r expanded`
Expected: PASS (3 tests). If an assertion runs before a MockClient future has landed, raise the pump count in `pumps` (never switch to `pumpAndSettle`: the spinner keeps it from settling).

- [ ] **Step 5: Analyze and commit**

Run: `flutter analyze lib/account test/account` → no errors.

```bash
git add lib/account/device_signin_dialog.dart test/account/device_signin_dialog_test.dart
git commit -m "account: native dialog for the GitHub device sign-in

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `main.dart` — one token setter and a "Sign in with GitHub" entry

**Files:**
- Modify: `lib/main.dart` (`_showTokenDialog`, the Tools sheet "Advanced" section)

- [ ] **Step 1: Imports**

Next to `import 'notif/notif_bridge.dart';` add:

```dart
import 'account/account_bridge.dart';
import 'account/device_signin_dialog.dart';
```

- [ ] **Step 2: The setter**

Directly above `void _showTokenDialog() {` add:

```dart
  /// The one place the GitHub token is written: memory for the proxy and
  /// SharedPreferences `githubToken` for the next launch. Null or empty
  /// clears it.
  Future<void> _setGithubToken(String? token) async {
    final t = (token ?? '').trim();
    setState(() => _githubToken = t.isEmpty ? null : t);
    final prefs = await SharedPreferences.getInstance();
    if (t.isEmpty) {
      await prefs.remove('githubToken');
    } else {
      await prefs.setString('githubToken', t);
    }
  }

  /// Device-flow sign-in from the Tools sheet. The paste-token dialog stays
  /// as the fallback.
  Future<void> _showDeviceSignIn() async {
    final token = await showDeviceSignInDialog(context);
    if (token != null) await _setGithubToken(token);
  }
```

- [ ] **Step 3: Route the paste dialog through it**

In `_showTokenDialog`, replace the Clear button's `onPressed`:

```dart
            onPressed: () async {
              setState(() => _githubToken = null);
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('githubToken');
              Navigator.of(ctx).pop();
            },
```

with

```dart
            onPressed: () async {
              await _setGithubToken(null);
              Navigator.of(ctx).pop();
            },
```

and the Save button's `onPressed`:

```dart
            onPressed: () async {
              final token = ctrl.text.trim();
              setState(() => _githubToken = token.isEmpty ? null : token);
              final prefs = await SharedPreferences.getInstance();
              if (token.isEmpty) {
                await prefs.remove('githubToken');
              } else {
                await prefs.setString('githubToken', token);
              }
              Navigator.of(ctx).pop();
            },
```

with

```dart
            onPressed: () async {
              await _setGithubToken(ctrl.text);
              Navigator.of(ctx).pop();
            },
```

(The exact original lines may differ slightly in variable names; the intent is that both buttons call `_setGithubToken` and nothing else writes `githubToken`. Verify with `grep -n "'githubToken'" lib/main.dart` → the read in `_loadPrefs`-style code plus the two writes inside `_setGithubToken` only.)

- [ ] **Step 4: The Tools entry**

In the Tools sheet, find the `ListTile` whose title is `const Text('GitHub token')` (under `_toolsSectionHeader('Advanced')`). Insert a new tile right **before** it:

```dart
                    ListTile(
                      leading: const Icon(Icons.login),
                      title: const Text('Sign in with GitHub'),
                      subtitle: Text(_githubToken != null ? 'Signed in' : 'Needed to save to your repo'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showDeviceSignIn();
                      },
                    ),
```

- [ ] **Step 5: Analyze, run, commit**

Run: `flutter analyze lib/main.dart` → no new errors (pre-existing infos are fine).
Run the app on macOS (`flutter run -d macos`, sandbox off) or Android: Tools → Advanced → "Sign in with GitHub" shows the code dialog; approve on github.com/login/device with a test account; the tile then says "Signed in" and "GitHub token" says "Token set".

```bash
git add lib/main.dart
git commit -m "app: sign in with GitHub via the device flow; one setter for the stored token

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `main.dart` — register `AccountBridge` on dialog1; document the contract

**Files:**
- Modify: `lib/main.dart` (field next to `_notifBridge`; channel list in `_openDialogWithWebview`)
- Modify: `docs/webapp-integration-spec.md`

- [ ] **Step 1: The bridge instance**

Directly after the `late final NotifBridge _notifBridge = NotifBridge( ... );` declaration add:

```dart
  // Language-app ↔ Cupitor bridge for the account feature: GitHub device
  // sign-in / sign-out on the page's request. Contract:
  // docs/webapp-integration-spec.md §3 "AccountBridge". The token never
  // crosses; the page asks GET /user through GitHubProxy afterwards.
  late final AccountBridge _accountBridge = AccountBridge(
    signIn: () => showDeviceSignInDialog(context),
    storeToken: _setGithubToken,
    signOut: () => _setGithubToken(null),
    hasToken: () => _githubToken != null && _githubToken!.isNotEmpty,
    emit: _emitNotifEvent,
  );
```

(`_emitNotifEvent(String event, Map<String, Object?> detail)` is the existing generic global-then-dispatch emitter; it stores `window.__<event>` and dispatches the CustomEvent, which is exactly the contract.)

- [ ] **Step 2: Register the channel**

In `_openDialogWithWebview`, after

```dart
        ..addJavaScriptChannel('NotifBridge',
            onMessageReceived: (msg) => _notifBridge.handle(msg.message))
```

add

```dart
        // Language-app ↔ Cupitor bridge for the account feature
        // (spec: docs/superpowers/specs/2026-10-13-multi-user-design.md).
        // Ops signIn / signOut / getStatus, acks via cupitorAccountAck.
        ..addJavaScriptChannel('AccountBridge',
            onMessageReceived: (msg) => _accountBridge.handle(msg.message))
```

- [ ] **Step 3: Document the contract (current state only)**

In `docs/webapp-integration-spec.md`, in §3 "JS → Dart Channels", add a subsection after the last existing channel subsection:

````markdown
### 3.x `AccountBridge`

GitHub account for the language webapp's multi-user feature. The app holds the token; the page only asks for sign-in/sign-out and reads who it is via `GET /user` through `GitHubProxy`.

```js
AccountBridge.postMessage(JSON.stringify({ op: 'signIn', request_id: 'acct-1' }));
// → CustomEvent 'cupitorAccountAck' { request_id: 'acct-1', op: 'signIn', ok: true, data: { signed_in: true } }
```

| op | Effect | `ok:true` data | `ok:false` error |
|---|---|---|---|
| `signIn` | Native GitHub device-flow dialog (scope `public_repo`); stores the token | `{signed_in:true}` | `cancelled`, `denied`, `expired`, `network`, `busy`, `internal` |
| `signOut` | Clears the stored token | `{signed_in:false}` | `internal` |
| `getStatus` | — | `{signed_in:<bool>}` | — |
| other | — | — | `unknown_op`; unparsable JSON → `bad_json` with `request_id: null` |

Every message gets exactly one ack. `request_id` is echoed; the ack detail is also stored on `window.__cupitorAccountAck` before the dispatch. A sign-in can take as long as GitHub's code is valid (about 15 minutes); the page should wait at least that long before giving up.
````

Also add `cupitorAccountAck` to the list of Dart → JS events in that document (the section that lists `cupitorPlaylists`, `cupitorNotifAck`, …) with the one-line description "ack for an `AccountBridge` op (§3.x)". Number the subsection to follow the existing ones.

- [ ] **Step 4: Analyze, tests, run**

Run: `flutter analyze lib/main.dart lib/account` → no new errors.
Run: `flutter test test/account test/notif -r expanded` → PASS (notif suites prove `_emitNotifEvent`'s callers still compile).

Manual (device or macOS, sandbox off), with the webapp plan's panel deployed — or from the dialog1 page's DevTools / log viewer:

```js
window.addEventListener('cupitorAccountAck', e => console.log('ack', JSON.stringify(e.detail)))
AccountBridge.postMessage(JSON.stringify({ op: 'getStatus', request_id: 't1' }))   // ack {signed_in:false}
AccountBridge.postMessage(JSON.stringify({ op: 'signIn', request_id: 't2' }))      // native dialog appears
```

Approve on GitHub → `ack {"request_id":"t2","op":"signIn","ok":true,"data":{"signed_in":true}}`; Tools → "GitHub token" shows "Token set". Then `signOut` → `{signed_in:false}` and the tile shows "Not configured".

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart docs/webapp-integration-spec.md
git commit -m "app: AccountBridge channel on dialog1 for the webapp's sign-in requests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Done when

- `flutter test test/account -r expanded` passes (19 tests) and `flutter test test/notif` still passes.
- `flutter analyze lib/account lib/main.dart` reports no errors.
- In the running app: Tools → "Sign in with GitHub" completes the device flow and the token survives a restart (read from `githubToken` at launch, as today).
- From the dialog1 page, `getStatus` / `signIn` / `signOut` each produce one `cupitorAccountAck` as in the table above.
- The owner decides separately whether to cut a release (version bump convention: patch and build number move together, e.g. `1.0.198+198` → `1.0.199+199`).
