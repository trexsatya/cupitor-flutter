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
        interval: Duration(seconds: _positiveSeconds(j['interval']) ?? 5),
        expiresIn: Duration(seconds: _positiveSeconds(j['expires_in']) ?? 900),
      );
}

/// A positive whole number of seconds from a JSON value, or null when the
/// value is missing, not a number, or not above zero.
int? _positiveSeconds(Object? v) => v is num && v >= 1 ? v.toInt() : null;

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
          interval = Duration(seconds: _positiveSeconds(j['interval']) ?? (interval.inSeconds + 5));
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
}
