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
    } on Exception catch (e) {
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
    if (j['device_code'] is! String || j['user_code'] is! String) {
      throw const DeviceSignInException('error', 'reply lacks device_code or user_code');
    }
    return DeviceCode.fromJson(j);
  }

  // pollForToken is added in Task 2.
}
