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

  /// Device-flow codes the contract passes through; any other code
  /// (e.g. the flow's generic 'error') is reported as 'internal'.
  static const _flowCodes = {'cancelled', 'denied', 'expired', 'network'};

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
      _ack(reqId, op, false,
          error: _flowCodes.contains(e.code) ? e.code : 'internal');
    } catch (_) {
      _ack(reqId, op, false, error: 'internal');
    } finally {
      _signingIn = false;
    }
  }
}
