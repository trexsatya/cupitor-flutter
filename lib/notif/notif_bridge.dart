import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'notif_dao.dart';
import 'recurring_scheduler.dart';
import 'schedules.dart';
import 'series_scheduler.dart';
import 'waking_clock.dart';

/// What the webpage learns from getCapabilities before offering the feature.
/// In Plan 1 permission/exactAlarms/actions are stubs — Plan 2's delivery
/// layer supplies real values through the same injected callback.
class NotifCapabilities {
  final bool supported;
  final String permission; // 'unknown' | 'granted' | 'denied'
  final bool exactAlarms;
  final bool actions;
  final String platform;
  const NotifCapabilities({
    required this.supported, required this.permission,
    required this.exactAlarms, required this.actions, required this.platform,
  });
  Map<String, Object?> toJson() => {
        'supported': supported, 'permission': permission,
        'exact_alarms': exactAlarms, 'actions': actions, 'platform': platform,
      };
}

typedef EmitEvent = void Function(String event, Map<String, Object?> detail);

/// The NotifBridge JS-channel handler (spec §Bridge). Mirrors PlaylistBridge:
/// JS→Flutter via the channel, Flutter→JS via CustomEvents — plus acks,
/// because these ops can genuinely fail. All dependencies are injected so
/// tests feed raw JSON and capture emitted events with no webview.
///
/// Failure posture (spec): never throw into the channel; every path acks.
class NotifBridge {
  final Future<NotifDao?> Function() dao;
  final int Function() activeProfileId;
  final EmitEvent emit;
  final Future<NotifCapabilities> Function() capabilities;
  final Future<String> Function() requestPermission;
  final WakingWindow Function() window;
  final tz.TZDateTime Function() now;

  /// Plan 2 hooks rearm() here; null until then.
  final Future<void> Function()? onMutated;

  NotifBridge({
    required this.dao,
    required this.activeProfileId,
    required this.emit,
    required this.capabilities,
    required this.requestPermission,
    required this.window,
    required this.now,
    this.onMutated,
  });

  void _ack(String? requestId, String op, bool ok,
      {String? error, Map<String, Object?>? data}) {
    emit('cupitorNotifAck', {
      'request_id': requestId,
      'op': op,
      'ok': ok,
      if (error != null) 'error': error,
      if (data != null) 'data': data,
    });
  }

  Future<NotifDao?> _daoOrAck(String? reqId, String op) async {
    final d = await dao();
    if (d == null) _ack(reqId, op, false, error: 'unsupported');
    return d;
  }

  Future<void> handle(String raw) async {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _ack(null, 'unknown', false, error: 'bad_json');
      return;
    }
    final op = m['op'] as String?;
    final reqId = m['request_id'] as String?;
    if (op == null) {
      _ack(reqId, 'unknown', false, error: 'unknown_op');
      return;
    }
    try {
      switch (op) {
        case 'getCapabilities':
          _ack(reqId, op, true, data: (await capabilities()).toJson());
        case 'requestPermission':
          _ack(reqId, op, true, data: {'permission': await requestPermission()});
        case 'getSchedules':
          await _getSchedules(reqId);
        // Task 10 adds: createList, syncItems, getLists.
        // Task 11 adds: grade, setSchedule, setStatus, deleteList.
        default:
          _ack(reqId, op, false, error: 'unknown_op');
      }
    } catch (e) {
      // Nothing may escape into the channel.
      _ack(reqId, op, false, error: 'internal');
    }
  }

  // ── payload builders ───────────────────────────────────────────────

  Map<String, Object?> _schedulesPayload(List<NotifScheduleRow> rows) => {
        'version': 1,
        'schedules': [
          for (final s in rows)
            {
              'key': s.key,
              'name': s.name,
              'kind': s.kind,
              'builtin': s.builtinKey != null,
              'config': jsonDecode(s.config),
            }
        ],
      };

  Future<void> _getSchedules(String? reqId) async {
    const op = 'getSchedules';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    emit('cupitorNotifSchedules', _schedulesPayload(await d.listSchedules()));
    _ack(reqId, op, true);
  }
}
