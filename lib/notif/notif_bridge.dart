import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'notif_dao.dart';
import 'notif_ops.dart';
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
  final Future<Map<String, Object?>> Function(NotifListRow)? schedulePreview;

  NotifBridge({
    required this.dao,
    required this.activeProfileId,
    required this.emit,
    required this.capabilities,
    required this.requestPermission,
    required this.window,
    required this.now,
    this.onMutated,
    this.schedulePreview,
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
    final op = m['op'] is String ? m['op'] as String : null;
    final reqId = m['request_id'] is String ? m['request_id'] as String : null;
    if (op == null) {
      _ack(reqId, 'unknown', false, error: 'unknown_op');
      return;
    }
    try {
      switch (op) {
        case 'getCapabilities':
          _ack(reqId, op, true, data: {...(await capabilities()).toJson(), 'schedule_preview': schedulePreview != null});
        case 'requestPermission':
          _ack(reqId, op, true, data: {'permission': await requestPermission()});
        case 'getSchedulePreview':
          await _getSchedulePreview(reqId, m);
        case 'getSchedules':
          await _getSchedules(reqId);
        case 'createList':
          await _createList(reqId, m);
        case 'syncItems':
          await _syncItems(reqId, m);
        case 'getLists':
          await _getLists(reqId);
        case 'getNotifications':
          await _getNotifications(reqId, m);
        case 'ackItem':
          await _ackItem(reqId, m);
        case 'grade':
          await _grade(reqId, m);
        case 'setSchedule':
          await _setSchedule(reqId, m);
        case 'setStatus':
          await _setStatus(reqId, m);
        case 'deleteList':
          await _deleteList(reqId, m);
        default:
          _ack(reqId, op, false, error: 'unknown_op');
      }
    } catch (e) {
      // Nothing may escape into the channel.
      _ack(reqId, op, false, error: 'internal');
    }
  }

  Future<void> _getSchedulePreview(String? reqId, Map<String, dynamic> m) async {
    const op = 'getSchedulePreview';
    final profile = activeProfileId();
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    if (profile != activeProfileId()) { _ack(reqId, op, false, error: 'profile_changed'); return; }
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    if (profile != activeProfileId()) { _ack(reqId, op, false, error: 'profile_changed'); return; }
    if (schedulePreview == null) { _ack(reqId, op, false, error: 'unsupported'); return; }
    final data = await schedulePreview!(list);
    if (profile != activeProfileId()) { _ack(reqId, op, false, error: 'profile_changed'); return; }
    _ack(reqId, op, true, data: data);
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
    return offsetsIfSeries(await d.scheduleById(scheduleId));
  }

  // ── list payloads ──────────────────────────────────────────────────

  Future<Map<String, Object?>> _listsPayload(NotifDao d) async {
    final lists = await d.listsForProfile(activeProfileId());
    final out = <Map<String, Object?>>[];
    for (final l in lists) {
      final schedule =
          l.scheduleId == null ? null : await d.scheduleById(l.scheduleId!);
      final introSchedule = l.introScheduleId == null
          ? null
          : await d.scheduleById(l.introScheduleId!);
      final items = await d.itemsForList(l.id);
      out.add({
        // Identity rule (spec): external ids only, internal row ids never
        // cross the bridge.
        'external_key': l.externalKey,
        'name': l.name,
        'source': l.source,
        'schedule_key': schedule?.key,
        'intro_schedule_key': introSchedule?.key,
        'open_url': l.openUrl,
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

  Future<void> _insertParsedItem(NotifDao d, int listId, _ItemInput it,
      int position, List<double>? offsets, tz.TZDateTime t, WakingWindow w) {
    return d.insertItem(
      listId: listId, externalId: it.externalId, title: it.title,
      body: it.body, openUrl: it.openUrl, payloadJson: it.payloadJson,
      position: position,
      nextDueAt: offsets == null
          ? null
          : addWakingHours(t, offsets[0], w).millisecondsSinceEpoch,
    );
  }

  Future<void> _afterMutation(NotifDao d) async {
    await _pushLists(d);
    try {
      await onMutated?.call();
    } catch (_) {
      // The mutation itself committed and was already acked ok; a rearm
      // failure must not surface as a second, contradictory ack.
    }
  }

  // ── ops ────────────────────────────────────────────────────────────

  /// Resolves an optional `intro_schedule_key` against the main [schedule].
  /// Returns (handled, intro): when handled is true an error ack has already
  /// been sent and the op must stop. An intro requires a series main
  /// schedule and a recurring intro schedule — anything else is `bad_intro`.
  Future<(bool, NotifScheduleRow?)> _resolveIntro(NotifDao d, String? reqId,
      String op, Map<String, dynamic> m, NotifScheduleRow schedule) async {
    final raw = m['intro_schedule_key'];
    if (raw == null) return (false, null);
    if (raw is! String || raw.isEmpty) {
      _ack(reqId, op, false, error: 'bad_payload');
      return (true, null);
    }
    final intro = await d.scheduleByKey(raw);
    if (intro == null) {
      _ack(reqId, op, false, error: 'unknown_schedule');
      return (true, null);
    }
    if (schedule.kind != 'series' || intro.kind != 'recurring') {
      _ack(reqId, op, false, error: 'bad_intro');
      return (true, null);
    }
    return (false, intro);
  }

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
    final (handled, intro) = await _resolveIntro(d, reqId, op, m, schedule);
    if (handled) return;
    final listOpenUrl = m['open_url'];
    if (listOpenUrl != null && listOpenUrl is! String) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final w = window();
    final t = now();
    // With an intro cadence: items stay unseeded (they are the intro queue)
    // and the list fire runs the cadence. Without: today's behavior.
    final nextFireAt = intro != null
        ? (items.isEmpty ? null : initialNextFireMs(intro, t, w))
        : initialNextFireMs(schedule, t, w);
    final offsets = intro != null ? null : offsetsIfSeries(schedule);
    final list = await d.createList(
        profileId: profileId, name: name, source: 'webpage',
        externalKey: key, scheduleId: schedule.id,
        introScheduleId: intro?.id, openUrl: listOpenUrl as String?,
        nextFireAt: nextFireAt);
    var pos = 0;
    for (final it in items) {
      await _insertParsedItem(d, list.id, it, pos++, offsets, t, w);
    }
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _syncItems(String? reqId, Map<String, dynamic> m) async {
    const op = 'syncItems';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final items = _parseItems(m['items']);
    final mode = (m['mode'] as String?) ?? 'merge';
    if (items == null || (mode != 'merge' && mode != 'replace')) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    // List-level deep link: present-and-string sets, present-and-null
    // clears, absent leaves unchanged.
    if (m.containsKey('open_url')) {
      final v = m['open_url'];
      if (v != null && v is! String) {
        _ack(reqId, op, false, error: 'bad_payload');
        return;
      }
      await d.updateList(list.id, {'open_url': v});
    }
    // Intro lists: new items join the intro queue unseeded.
    final offsets = list.introScheduleId != null
        ? null
        : await _offsetsFor(d, list.scheduleId);
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
        await _insertParsedItem(d, list.id, it, pos, offsets, t, w);
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
    // A dormant intro cadence wakes up when new items join its queue.
    await ensureIntroArmed(d, list, t, w);
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

  /// The notification feed (spec: webapp bell-style inbox, one flat
  /// newest-first stream — grouping is the page's business via
  /// external_key). An entry with responded_at == null is unacknowledged.
  Future<void> _getNotifications(String? reqId, Map<String, dynamic> m) async {
    const op = 'getNotifications';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final rawLimit = m['limit'];
    final limit =
        rawLimit is int && rawLimit > 0 && rawLimit <= 200 ? rawLimit : 50;
    final entries = await d.recentEvents(activeProfileId(), limit);
    emit('cupitorNotifFeed', {
      'version': 1,
      'notifications': [
        for (final e in entries)
          {
            'external_key': e.listExternalKey,
            'list_name': e.listName,
            'item_external_id': e.itemExternalId,
            'title': e.title,
            'body': e.body,
            'step': e.step,
            'item_status': e.itemStatus,
            'fired_at': e.firedAt,
            'responded_at': e.respondedAt,
            'grade': e.grade,
            'source': e.source,
          }
      ],
    });
    _ack(reqId, op, true);
  }

  /// Mark ALL of an item's outstanding fires as seen WITHOUT grading (the
  /// feed's "mark read") — stamping only the latest would orphan any older
  /// unread row forever. Idempotent: already-acknowledged or never-fired
  /// items ack ok and change nothing.
  Future<void> _ackItem(String? reqId, Map<String, dynamic> m) async {
    const op = 'ackItem';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final itemExt = m['item_external_id'] as String?;
    if (itemExt == null || itemExt.isEmpty) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    final item = await d.itemByExternalId(list.id, itemExt);
    if (item == null) {
      _ack(reqId, op, false, error: 'unknown_item');
      return;
    }
    await d.ackUnrespondedEvents(item.id, now().millisecondsSinceEpoch);
    _ack(reqId, op, true);
  }

  /// Shared list lookup with unknown_list ack.
  Future<NotifListRow?> _listOrAck(
      NotifDao d, String? reqId, String op, Object? key) async {
    final k = key as String?;
    if (k == null || k.isEmpty) {
      _ack(reqId, op, false, error: 'bad_payload');
      return null;
    }
    final list = await d.listByExternalKey(activeProfileId(), k);
    if (list == null) _ack(reqId, op, false, error: 'unknown_list');
    return list;
  }

  Future<void> _grade(String? reqId, Map<String, dynamic> m) async {
    const op = 'grade';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final itemExt = m['item_external_id'] as String?;
    final gradeRaw = m['grade'];
    final grade = gradeRaw is int ? gradeRaw : null;
    if (itemExt == null || itemExt.isEmpty) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    if (grade != gradeAgain && grade != gradeGood && grade != gradeEasy) {
      _ack(reqId, op, false, error: 'bad_grade');
      return;
    }
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    final schedule =
        list.scheduleId == null ? null : await d.scheduleById(list.scheduleId!);
    if (schedule == null || schedule.kind != 'series') {
      _ack(reqId, op, false, error: 'not_series');
      return;
    }
    final item = await d.itemByExternalId(list.id, itemExt);
    if (item == null) {
      _ack(reqId, op, false, error: 'unknown_item');
      return;
    }
    final offsets =
        seriesOffsets(jsonDecode(schedule.config) as Map<String, dynamic>);
    final t = now();
    final o = advanceSeries(
        step: item.step, done: item.status == 'done',
        offsetsWakingHours: offsets, now: t, grade: grade, window: window());
    await d.updateItem(item.id, {
      'step': o.step,
      'status': o.done ? 'done' : 'active',
      'next_due_at': o.nextDue?.millisecondsSinceEpoch,
      'last_grade': grade,
    });
    final nowMs = t.millisecondsSinceEpoch;
    // Grading means the user has seen the item — acknowledge any fire rows
    // still unread so they don't linger in the feed.
    await d.ackUnrespondedEvents(item.id, nowMs);
    // A webpage grade is review-without-fire; fired_at = responded_at keeps
    // the event usable for dedupe and the sweep (spec: notif_events).
    await d.insertEvent(
        itemId: item.id, firedAt: nowMs, respondedAt: nowMs,
        grade: grade, source: 'webpage', step: item.step);
    emit('cupitorNotifGraded', {
      'external_key': list.externalKey,
      'item_external_id': itemExt,
      'grade': grade,
      'source': 'webpage',
    });
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _setSchedule(String? reqId, Map<String, dynamic> m) async {
    const op = 'setSchedule';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    final schedule = await d.scheduleByKey((m['schedule_key'] as String?) ?? '');
    if (schedule == null) {
      _ack(reqId, op, false, error: 'unknown_schedule');
      return;
    }
    // setSchedule sets the list's FULL scheduling: an absent
    // intro_schedule_key clears any existing intro (contract doc).
    final (handled, intro) = await _resolveIntro(d, reqId, op, m, schedule);
    if (handled) return;
    await applyScheduleToList(d, list, schedule, now(), window(),
        intro: intro);
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _setStatus(String? reqId, Map<String, dynamic> m) async {
    const op = 'setStatus';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final status = m['status'];
    if (status is! String || (status != 'active' && status != 'paused')) {
      _ack(reqId, op, false, error: 'bad_payload');
      return;
    }
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    await setListStatus(d, list, status, now(), window());
    _ack(reqId, op, true);
    await _afterMutation(d);
  }

  Future<void> _deleteList(String? reqId, Map<String, dynamic> m) async {
    const op = 'deleteList';
    final d = await _daoOrAck(reqId, op);
    if (d == null) return;
    final list = await _listOrAck(d, reqId, op, m['external_key']);
    if (list == null) return;
    await d.deleteList(list.id);
    _ack(reqId, op, true);
    await _afterMutation(d);
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
