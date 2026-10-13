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
