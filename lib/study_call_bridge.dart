import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Same request_id/ack + snapshot contract as NotifBridge. Android owns the
/// alarms, call screen and durable answers, independently of the WebView.
class StudyCallBridge {
  static const channel = MethodChannel('cupitor/study_calls');
  final int Function() activeProfileId;
  final void Function(String, Map<String, Object?>) emit;
  final Future<Object?> Function(String, Map<String, Object?>) invoke;
  final bool supported;

  StudyCallBridge({
    required this.activeProfileId,
    required this.emit,
    Future<Object?> Function(String, Map<String, Object?>)? invoke,
    bool? supported,
  }) : invoke = invoke ?? ((op, args) => channel.invokeMethod(op, args)),
       supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const _ops = {
    'getCapabilities',
    'requestPermission',
    'openFullScreenSettings',
    'openAlarmSettings',
    'getCalls',
    'callNow',
    'schedule',
    'cancel',
  };

  Future<void> handle(String raw) async {
    String? requestId;
    var op = 'unknown';
    void ack(bool ok, {Object? data, String? error}) {
      emit('cupitorCallAck', {
        'request_id': requestId,
        'op': op,
        'ok': ok,
        if (data != null) 'data': data,
        if (error != null) 'error': error,
      });
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        ack(false, error: 'bad_json');
        return;
      }
      requestId = decoded['request_id'] is String
          ? decoded['request_id'] as String
          : null;
      op = decoded['op'] is String ? decoded['op'] as String : 'unknown';
      if (!_ops.contains(op)) {
        ack(false, error: 'unknown_op');
        return;
      }
      if (!supported) {
        if (op == 'getCapabilities') {
          ack(true, data: {'supported': false});
        } else {
          ack(false, error: 'unsupported');
        }
        return;
      }
      // Never accept a profile supplied by page JavaScript.
      final profile = activeProfileId();
      final result = await invoke(op, {...decoded, 'profile_id': profile});
      if (profile != activeProfileId()) {
        ack(false, error: 'profile_changed');
        return;
      }
      ack(true, data: result);
      if (op == 'getCalls' && result is Map && profile == activeProfileId()) {
        emit('cupitorCalls', Map<String, Object?>.from(result));
      } else if (op == 'callNow' || op == 'schedule' || op == 'cancel') {
        // A refresh failure must never contradict an already successful ack.
        try {
          final snapshot = await invoke('getCalls', {'profile_id': profile});
          if (snapshot is Map && profile == activeProfileId()) {
            emit('cupitorCalls', Map<String, Object?>.from(snapshot));
          }
        } catch (_) {}
      }
    } on FormatException {
      ack(false, error: 'bad_json');
    } on PlatformException catch (e) {
      ack(false, error: e.code);
    } catch (_) {
      ack(false, error: 'internal');
    }
  }
}
