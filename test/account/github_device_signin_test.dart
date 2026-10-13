import 'dart:async';
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

    Matcher fails(String code) => throwsA(isA<DeviceSignInException>().having((e) => e.code, 'code', code));
    GitHubDeviceSignIn replying(String body, [int status = 200]) =>
        GitHubDeviceSignIn(client: MockClient((_) async => http.Response(body, status)), sleep: (_) async {});

    test('a non-200 reply without an error field is error', () async {
      await expectLater(replying('nope', 500).requestCode(), fails('error'));
    });

    test('a 200 reply with an error field is error', () async {
      await expectLater(replying('{"error":"device_flow_disabled"}').requestCode(), fails('error'));
    });

    test('a non-JSON 200 body is error', () async {
      await expectLater(replying('<html>hi</html>').requestCode(), fails('error'));
    });

    test('a 200 reply missing or mistyping device_code / user_code is error', () async {
      await expectLater(replying('{}').requestCode(), fails('error'));
      await expectLater(replying('{"device_code":1,"user_code":"ABCD-1234"}').requestCode(), fails('error'));
      await expectLater(replying('{"device_code":"dc-1"}').requestCode(), fails('error'));
    });

    test('missing interval, expires_in and verification_uri fall back to defaults', () async {
      final code = await replying('{"device_code":"dc-1","user_code":"ABCD-1234"}').requestCode();
      expect(code.interval, const Duration(seconds: 5));
      expect(code.expiresIn, const Duration(seconds: 900));
      expect(code.verificationUri, 'https://github.com/login/device');
    });

    test('non-numeric interval and expires_in fall back to defaults', () async {
      final code = await replying('{"device_code":"dc-1","user_code":"ABCD-1234","interval":"7","expires_in":"soon"}').requestCode();
      expect(code.interval, const Duration(seconds: 5));
      expect(code.expiresIn, const Duration(seconds: 900));
    });

    test('a client that throws ClientException is network', () async {
      final offline = GitHubDeviceSignIn(client: MockClient((_) async => throw http.ClientException('offline')), sleep: (_) async {});
      await expectLater(offline.requestCode(), fails('network'));
    });

    test('a client that throws TimeoutException is network', () async {
      final slow = GitHubDeviceSignIn(client: MockClient((_) async => throw TimeoutException('slow')), sleep: (_) async {});
      await expectLater(slow.requestCode(), fails('network'));
    });
  });

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

    test('slow_down with a non-numeric interval adds five seconds', () async {
      final w = world([{'error': 'slow_down', 'interval': '10'}, {'access_token': 'ghu_ok'}]);
      expect(await w.flow.pollForToken(code), 'ghu_ok');
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
}
