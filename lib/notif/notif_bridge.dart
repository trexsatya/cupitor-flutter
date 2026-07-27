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
        case 'createList':
          await _createList(reqId, m);
        case 'syncItems':
          await _syncItems(reqId, m);
        case 'getLists':
          await _getLists(reqId);
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

  // ── item input parsing ─────────────────────────────────────────────

  /// Returns null on any invalid item (missing/empty external_id or title,
  /// duplicate external_id) — the whole op is rejected atomically.
  List<_ItemInput>? _parseItems(Object? raw) {
    if (raw is! List) return null;
    final out = <_ItemInput>[];
    final seen = <String>{};
    for (final e in raw) {
      if (e is! Map) return null;
      final id = e['external_id'] as String?;
      final title = e['title'] as String?;
      if (id == null || id.isEmpty || title == null || title.isEmpty) {
        return null;
      }
      if (!seen.add(id)) return null;
      out.add(_ItemInput(
        externalId: id,
        title: title,
        body: e['body'] as String?,
        openUrl: e['open_url'] as String?,
        payloadJson: e['payload'] == null ? null : jsonEncode(e['payload']),
      ));
    }
    return out;
  }

  /// Series offsets when the schedule is a series, else null. The null form
  /// doubles as "items get no per-item due time" (recurring lists).
  Future<List<double>?> _offsetsFor(NotifDao d, int? scheduleId) async {
    if (scheduleId == null) return null;
    final s = await d.scheduleById(scheduleId);
    if (s == null || s.kind != 'series') return null;
    return seriesOffsets(jsonDecode(s.config) as Map<String, dynamic>);
  }

  // ── list payloads ──────────────────────────────────────────────────

  Future<Map<String, Object?>> _listsPayload(NotifDao d) async {
    final lists = await d.listsForProfile(activeProfileId());
    final out = <Map<String, Object?>>[];
    for (final l in lists) {
      final schedule =
          l.scheduleId == null ? null : await d.scheduleById(l.scheduleId!);
      final items = await d.itemsForList(l.id);
      out.add({
        // Identity rule (spec): external ids only, internal row ids never
        // cross the bridge.
        'external_key': l.externalKey,
        'name': l.name,
        'source': l.source,
        'schedule_key': schedule?.key,
        'status': l.status,
        'next_fire_at': l.nextFireAt,
        'items': [
          for (final i in items)
            {
              'external_id': i.externalId,
              'title': i.title,
              'body': i.body,
              'open_url': i.openUrl,
              'payload': i.payload == null ? null : jsonDecode(i.payload!),
              'position': i.position,
              'step': i.step,
              'next_due_at': i.nextDueAt,
              'status': i.status,
            }
        ],
      });
    }
    return {'version': 1, 'lists': out};
  }

  Future<void> _pushLists(NotifDao d) async {
    emit('cupitorNotifLists', await _listsPayload(d));
  }

  Future<void> _afterMutation(NotifDao d) async {
    await _pushLists(d);
    await onMutated?.call();
  }

  // ── ops ────────────────────────────────────────────────────────────

  Future<void> _createList(String? reqId, Map<String, dynamic> m) async {
    const op = 'createList';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final key = m['external_key'] as String?;
    final name = m['name'] as String?;
    final items = _parseItems(m['items']);
    if (key == null || key.isEmpty || name == null || name.isEmpty ||
        items == null) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final profileId = activeProfileId();
    if (await d.listByExternalKey(profileId, key) != null) {
      _ack(reqId, op, false, error: 'duplicate_key');
      return;
    }
    final schedule =
        await d.scheduleByKey((m['schedule_key'] as String?) ?? 'ebbinghaus');
    if (schedule == null) {
      _ack(reqId, op, false, error: 'unknown_schedule');
      return;
    }
    final w = window();
    final t = now();
    final config = jsonDecode(schedule.config) as Map<String, dynamic>;
    int? nextFireAt;
    List<double>? offsets;
    if (schedule.kind == 'recurring') {
      nextFireAt =
          nextRecurringFire(parseRecurring(config), t, w).millisecondsSinceEpoch;
    } else {
      offsets = seriesOffsets(config);
    }
    final list = await d.createList(
        profileId: profileId, name: name, source: 'webpage',
        externalKey: key, scheduleId: schedule.id, nextFireAt: nextFireAt);
    var pos = 0;
    for (final it in items) {
      await d.insertItem(
        listId: list.id, externalId: it.externalId, title: it.title,
        body: it.body, openUrl: it.openUrl, payloadJson: it.payloadJson,
        position: pos++,
        nextDueAt: offsets == null
            ? null
            : addWakingHours(t, offsets[0], w).millisecondsSinceEpoch,
      );
    }
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _syncItems(String? reqId, Map<String, dynamic> m) async {
    const op = 'syncItems';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final key = m['external_key'] as String?;
    final items = _parseItems(m['items']);
    final mode = (m['mode'] as String?) ?? 'merge';
    if (key == null || items == null || (mode != 'merge' && mode != 'replace')) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final list = await d.listByExternalKey(activeProfileId(), key);
    if (list == null) {
      _ack(reqId, op, false, error: 'unknown_list');
      return;
    }
    final offsets = await _offsetsFor(d, list.scheduleId);
    final existing = await d.itemsForList(list.id);
    final byExt = {
      for (final i in existing)
        if (i.externalId != null) i.externalId!: i
    };
    final w = window();
    final t = now();
    final seen = <String>{};
    var pos = 0;
    for (final it in items) {
      seen.add(it.externalId);
      final cur = byExt[it.externalId];
      if (cur == null) {
        await d.insertItem(
          listId: list.id, externalId: it.externalId, title: it.title,
          body: it.body, openUrl: it.openUrl, payloadJson: it.payloadJson,
          position: pos,
          nextDueAt: offsets == null
              ? null
              : addWakingHours(t, offsets[0], w).millisecondsSinceEpoch,
        );
      } else {
        // Merge semantics (spec): content updates, SRS state (step,
        // next_due_at, status, history) survives.
        await d.updateItem(cur.id, {
          'title': it.title, 'body': it.body, 'open_url': it.openUrl,
          'payload': it.payloadJson, 'position': pos,
        });
      }
      pos++;
    }
    if (mode == 'replace') {
      for (final i in existing) {
        if (i.externalId != null && !seen.contains(i.externalId)) {
          await d.deleteItem(i.id);
        }
      }
    }
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _getLists(String? reqId) async {
    const op = 'getLists';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    await _pushLists(d);
    _ack(reqId, op, true);
  }
}

class _ItemInput {
  final String externalId;
  final String title;
  final String? body;
  final String? openUrl;
  final String? payloadJson;
  const _ItemInput({
    required this.externalId, required this.title,
    this.body, this.openUrl, this.payloadJson,
  });
}
