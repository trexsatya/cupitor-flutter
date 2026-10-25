import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class StudyCallHistoryTarget {
  final String id;
  final int profileId;
  final String openId;

  const StudyCallHistoryTarget(this.id, this.profileId, this.openId);

  static StudyCallHistoryTarget? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], profile = raw['profile_id'], openId = raw['open_id'];
    if (id is! String || id.isEmpty || id.length > 128 ||
        profile is! int || profile < 1 || openId is! String || openId.isEmpty) {
      return null;
    }
    return StudyCallHistoryTarget(id, profile, openId);
  }
}

/// This channel is host-only; a web page cannot consume or choose profiles.
class StudyCallHistoryBridge {
  static const channel = MethodChannel('cupitor/study_call_history');
  final Future<void> Function(StudyCallHistoryTarget) onOpen;
  final Future<Object?> Function() takePending;
  final bool supported;
  bool _busy = false, _again = false, _disposed = false;

  StudyCallHistoryBridge({
    required this.onOpen,
    Future<Object?> Function()? takePending,
    bool? supported,
  }) : takePending = takePending ?? (() => channel.invokeMethod('takePendingOpen')),
       supported = supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<void> start() async {
    if (!supported || _disposed) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pending') await checkPending();
    });
    await checkPending();
  }

  Future<void> checkPending() async {
    if (!supported || _disposed) return;
    if (_busy) { _again = true; return; }
    _busy = true;
    try {
      do {
        _again = false;
        final target = StudyCallHistoryTarget.parse(await takePending());
        if (_disposed) return;
        if (target != null) {
          await onOpen(target);
          _again = true; // A second tap may have arrived during navigation.
        }
      } while (_again && !_disposed);
    } catch (e) {
      debugPrint('study call history open failed: $e');
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    if (supported) channel.setMethodCallHandler(null);
  }
}
