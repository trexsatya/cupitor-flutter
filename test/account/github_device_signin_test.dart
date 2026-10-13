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

    test('a client that throws ClientException is network', () async {
      final offline = GitHubDeviceSignIn(client: MockClient((_) async => throw http.ClientException('offline')), sleep: (_) async {});
      await expectLater(offline.requestCode(), fails('network'));
    });

    test('a client that throws TimeoutException is network', () async {
      final slow = GitHubDeviceSignIn(client: MockClient((_) async => throw TimeoutException('slow')), sleep: (_) async {});
      await expectLater(slow.requestCode(), fails('network'));
    });
  });
}
