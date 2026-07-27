import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'schedules.dart';

/// Row models mirror the v7 columns 1:1 (spec: data-model section). Times are
/// epoch ms; `config` and `payload` stay raw JSON strings here — parsing is
/// the caller's business.

class NotifScheduleRow {
  final int id;
  final String name;
  final String kind; // 'series' | 'recurring'
  final String? builtinKey;
  final String config; // raw JSON
  final int createdAt;
  const NotifScheduleRow({
    required this.id, required this.name, required this.kind,
    required this.builtinKey, required this.config, required this.createdAt,
  });

  /// The form that crosses the bridge as `schedule_key`.
  String get key => builtinKey ?? 'custom:$id';

  static NotifScheduleRow fromMap(Map<String, Object?> m) => NotifScheduleRow(
        id: m['id'] as int,
        name: m['name'] as String,
        kind: m['kind'] as String,
        builtinKey: m['builtin_key'] as String?,
        config: m['config'] as String,
        createdAt: m['created_at'] as int,
      );
}

class NotifListRow {
  final int id;
  final int profileId;
  final String name;
  final String source; // 'webpage' | 'app'
  final String? externalKey;
  final int? scheduleId;
  final String status; // 'active' | 'paused'
  final int cursor;
  final int? nextFireAt;
  final int? lastFiredAt;
  final int createdAt;
  final int updatedAt;
  const NotifListRow({
    required this.id, required this.profileId, required this.name,
    required this.source, required this.externalKey, required this.scheduleId,
    required this.status, required this.cursor, required this.nextFireAt,
    required this.lastFiredAt, required this.createdAt, required this.updatedAt,
  });

  static NotifListRow fromMap(Map<String, Object?> m) => NotifListRow(
        id: m['id'] as int,
        profileId: m['profile_id'] as int,
        name: m['name'] as String,
        source: m['source'] as String,
        externalKey: m['external_key'] as String?,
        scheduleId: m['schedule_id'] as int?,
        status: m['status'] as String,
        cursor: (m['cursor'] as num?)?.toInt() ?? 0,
        nextFireAt: (m['next_fire_at'] as num?)?.toInt(),
        lastFiredAt: (m['last_fired_at'] as num?)?.toInt(),
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
      );
}

class NotifItemRow {
  final int id;
  final int listId;
  final String? externalId;
  final String title;
  final String? body;
  final String? openUrl;
  final String? payload; // raw JSON, echoed back verbatim
  final int position;
  final int step;
  final int? nextDueAt;
  final int? lastFiredAt;
  final int? lastGrade;
  final String status; // 'active' | 'suspended' | 'done'
  final int createdAt;
  const NotifItemRow({
    required this.id, required this.listId, required this.externalId,
    required this.title, required this.body, required this.openUrl,
    required this.payload, required this.position, required this.step,
    required this.nextDueAt, required this.lastFiredAt, required this.lastGrade,
    required this.status, required this.createdAt,
  });

  static NotifItemRow fromMap(Map<String, Object?> m) => NotifItemRow(
        id: m['id'] as int,
        listId: m['list_id'] as int,
        externalId: m['external_id'] as String?,
        title: m['title'] as String,
        body: m['body'] as String?,
        openUrl: m['open_url'] as String?,
        payload: m['payload'] as String?,
        position: (m['position'] as num?)?.toInt() ?? 0,
        step: (m['step'] as num?)?.toInt() ?? 0,
        nextDueAt: (m['next_due_at'] as num?)?.toInt(),
        lastFiredAt: (m['last_fired_at'] as num?)?.toInt(),
        lastGrade: (m['last_grade'] as num?)?.toInt(),
        status: m['status'] as String,
        createdAt: m['created_at'] as int,
      );
}

class NotifEventRow {
  final int id;
  final int itemId;
  final int firedAt;
  final int? respondedAt;
  final int? grade;
  final String? source; // 'action' | 'webpage' | 'auto'
  const NotifEventRow({
    required this.id, required this.itemId, required this.firedAt,
    required this.respondedAt, required this.grade, required this.source,
  });

  static NotifEventRow fromMap(Map<String, Object?> m) => NotifEventRow(
        id: m['id'] as int,
        itemId: m['item_id'] as int,
        firedAt: m['fired_at'] as int,
        respondedAt: (m['responded_at'] as num?)?.toInt(),
        grade: (m['grade'] as num?)?.toInt(),
        source: m['source'] as String?,
      );
}

/// Takes the handle directly (not CupitorDb) so every test runs on
/// sqflite_common_ffi in memory — CupitorDb._open() needs path_provider,
/// which doesn't exist in a unit test. Production callers get one via
/// CupitorDb.instance.notifDao(), which honours the null-if-unavailable
/// contract.
class NotifDao {
  final Database db;
  NotifDao(this.db);

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  // ── schedules ──────────────────────────────────────────────────────

  Future<List<NotifScheduleRow>> listSchedules() async =>
      (await db.query('notif_schedules', orderBy: 'id ASC'))
          .map(NotifScheduleRow.fromMap)
          .toList(growable: false);

  Future<NotifScheduleRow?> scheduleById(int id) async {
    final r = await db.query('notif_schedules',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : NotifScheduleRow.fromMap(r.first);
  }

  /// Resolves both bridge forms: a builtin_key, or `custom:<id>`.
  Future<NotifScheduleRow?> scheduleByKey(String key) async {
    if (key.startsWith('custom:')) {
      final id = int.tryParse(key.substring(7));
      if (id == null) return null;
      final s = await scheduleById(id);
      return (s == null || s.builtinKey != null) ? null : s;
    }
    final r = await db.query('notif_schedules',
        where: 'builtin_key = ?', whereArgs: [key], limit: 1);
    return r.isEmpty ? null : NotifScheduleRow.fromMap(r.first);
  }

  /// Validates via [validateScheduleConfig]; throws [ScheduleConfigError].
  Future<NotifScheduleRow> createCustomSchedule({
    required String name,
    required String kind,
    required Map<String, Object?> config,
  }) async {
    final normalized = jsonEncode(validateScheduleConfig(kind, config));
    final now = _now();
    final id = await db.insert('notif_schedules', {
      'name': name, 'kind': kind, 'builtin_key': null,
      'config': normalized, 'created_at': now,
    });
    return NotifScheduleRow(
        id: id, name: name, kind: kind, builtinKey: null,
        config: normalized, createdAt: now);
  }

  /// Every list (any profile) still pointing at [scheduleId] — the editor's
  /// delete guard and its re-anchor-after-edit pass both need the full set.
  Future<List<NotifListRow>> listsUsingSchedule(int scheduleId) async =>
      (await db.query('notif_lists',
              where: 'schedule_id = ?', whereArgs: [scheduleId],
              orderBy: 'id ASC'))
          .map(NotifListRow.fromMap)
          .toList(growable: false);

  /// Rewrite a CUSTOM schedule. Built-ins are immutable (spec: visible and
  /// clonable, not editable), so a builtin or missing row returns false.
  /// Throws [ScheduleConfigError] on an invalid config.
  Future<bool> updateCustomSchedule(int id,
      {required String name,
      required String kind,
      required Map<String, Object?> config}) async {
    final s = await scheduleById(id);
    if (s == null || s.builtinKey != null) return false;
    final normalized = jsonEncode(validateScheduleConfig(kind, config));
    await db.update(
        'notif_schedules', {'name': name, 'kind': kind, 'config': normalized},
        where: 'id = ?', whereArgs: [id]);
    return true;
  }

  /// Delete a CUSTOM schedule. The caller must first verify no list uses it
  /// (spec: deletion is blocked until those lists are reassigned). Builtin
  /// or missing rows return false.
  Future<bool> deleteCustomSchedule(int id) async {
    final s = await scheduleById(id);
    if (s == null || s.builtinKey != null) return false;
    await db.delete('notif_schedules', where: 'id = ?', whereArgs: [id]);
    return true;
  }

  // ── lists ──────────────────────────────────────────────────────────

  Future<NotifListRow> createList({
    required int profileId,
    required String name,
    required String source,
    String? externalKey,
    int? scheduleId,
    int? nextFireAt,
  }) async {
    final now = _now();
    final id = await db.insert('notif_lists', {
      'profile_id': profileId, 'name': name, 'source': source,
      'external_key': externalKey, 'schedule_id': scheduleId,
      'status': 'active', 'cursor': 0, 'next_fire_at': nextFireAt,
      'created_at': now, 'updated_at': now,
    });
    return NotifListRow(
        id: id, profileId: profileId, name: name, source: source,
        externalKey: externalKey, scheduleId: scheduleId, status: 'active',
        cursor: 0, nextFireAt: nextFireAt, lastFiredAt: null,
        createdAt: now, updatedAt: now);
  }

  Future<NotifListRow?> listByExternalKey(int profileId, String key) async {
    final r = await db.query('notif_lists',
        where: 'profile_id = ? AND external_key = ?',
        whereArgs: [profileId, key], limit: 1);
    return r.isEmpty ? null : NotifListRow.fromMap(r.first);
  }

  Future<List<NotifListRow>> listsForProfile(int profileId) async =>
      (await db.query('notif_lists',
              where: 'profile_id = ?', whereArgs: [profileId],
              orderBy: 'created_at ASC, id ASC'))
          .map(NotifListRow.fromMap)
          .toList(growable: false);

  /// Column-name keyed partial update; updated_at is always bumped.
  Future<void> updateList(int id, Map<String, Object?> fields) async {
    await db.update('notif_lists', {...fields, 'updated_at': _now()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteList(int id) async {
    await db.delete('notif_lists', where: 'id = ?', whereArgs: [id]);
  }

  // ── items ──────────────────────────────────────────────────────────

  Future<NotifItemRow> insertItem({
    required int listId,
    String? externalId,
    required String title,
    String? body,
    String? openUrl,
    String? payloadJson,
    required int position,
    int step = 0,
    int? nextDueAt,
  }) async {
    final now = _now();
    final id = await db.insert('notif_items', {
      'list_id': listId, 'external_id': externalId, 'title': title,
      'body': body, 'open_url': openUrl, 'payload': payloadJson,
      'position': position, 'step': step, 'next_due_at': nextDueAt,
      'status': 'active', 'created_at': now,
    });
    return NotifItemRow(
        id: id, listId: listId, externalId: externalId, title: title,
        body: body, openUrl: openUrl, payload: payloadJson,
        position: position, step: step, nextDueAt: nextDueAt,
        lastFiredAt: null, lastGrade: null, status: 'active', createdAt: now);
  }

  Future<List<NotifItemRow>> itemsForList(int listId) async =>
      (await db.query('notif_items',
              where: 'list_id = ?', whereArgs: [listId],
              orderBy: 'position ASC, id ASC'))
          .map(NotifItemRow.fromMap)
          .toList(growable: false);

  Future<NotifItemRow?> itemByExternalId(int listId, String externalId) async {
    final r = await db.query('notif_items',
        where: 'list_id = ? AND external_id = ?',
        whereArgs: [listId, externalId], limit: 1);
    return r.isEmpty ? null : NotifItemRow.fromMap(r.first);
  }

  Future<void> updateItem(int id, Map<String, Object?> fields) async {
    await db.update('notif_items', fields, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteItem(int id) async {
    await db.delete('notif_items', where: 'id = ?', whereArgs: [id]);
  }

  /// Active items in active lists, due at or before [nowMs]. Fed to the
  /// arming pass and the sweep (Plan 2).
  Future<List<NotifItemRow>> dueItems(int nowMs) async =>
      (await db.rawQuery('''
        SELECT i.* FROM notif_items i
        JOIN notif_lists l ON l.id = i.list_id
        WHERE i.status = 'active' AND l.status = 'active'
          AND i.next_due_at IS NOT NULL AND i.next_due_at <= ?
        ORDER BY i.next_due_at ASC, i.id ASC
      ''', [nowMs]))
          .map(NotifItemRow.fromMap)
          .toList(growable: false);

  /// Active items in active lists due strictly AFTER [fromMs] and at or
  /// before [toMs] — the rearm window. Profile-agnostic by design: reviews
  /// keep firing for every profile (spec §Delivery).
  Future<List<NotifItemRow>> upcomingItems(int fromMs, int toMs) async =>
      (await db.rawQuery('''
        SELECT i.* FROM notif_items i
        JOIN notif_lists l ON l.id = i.list_id
        WHERE i.status = 'active' AND l.status = 'active'
          AND i.next_due_at IS NOT NULL
          AND i.next_due_at > ? AND i.next_due_at <= ?
        ORDER BY i.next_due_at ASC, i.id ASC
      ''', [fromMs, toMs]))
          .map(NotifItemRow.fromMap)
          .toList(growable: false);

  /// Active lists whose recurring fire time has passed. Profile-agnostic.
  Future<List<NotifListRow>> recurringDueLists(int nowMs) async =>
      (await db.query('notif_lists',
              where: "status = 'active' AND next_fire_at IS NOT NULL "
                  'AND next_fire_at <= ?',
              whereArgs: [nowMs],
              orderBy: 'next_fire_at ASC, id ASC'))
          .map(NotifListRow.fromMap)
          .toList(growable: false);

  /// Active lists firing inside the rearm window (strictly future).
  Future<List<NotifListRow>> recurringUpcomingLists(int fromMs, int toMs) async =>
      (await db.query('notif_lists',
              where: "status = 'active' AND next_fire_at IS NOT NULL "
                  'AND next_fire_at > ? AND next_fire_at <= ?',
              whereArgs: [fromMs, toMs],
              orderBy: 'next_fire_at ASC, id ASC'))
          .map(NotifListRow.fromMap)
          .toList(growable: false);

  Future<NotifItemRow?> itemById(int id) async {
    final r = await db.query('notif_items',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : NotifItemRow.fromMap(r.first);
  }

  Future<NotifListRow?> listById(int id) async {
    final r = await db.query('notif_lists',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : NotifListRow.fromMap(r.first);
  }

  // ── events ─────────────────────────────────────────────────────────

  Future<int> insertEvent({
    required int itemId,
    required int firedAt,
    int? respondedAt,
    int? grade,
    String? source,
  }) =>
      db.insert('notif_events', {
        'item_id': itemId, 'fired_at': firedAt,
        'responded_at': respondedAt, 'grade': grade, 'source': source,
      });

  Future<NotifEventRow?> lastEventForItem(int itemId) async {
    final r = await db.query('notif_events',
        where: 'item_id = ?', whereArgs: [itemId],
        orderBy: 'fired_at DESC, id DESC', limit: 1);
    return r.isEmpty ? null : NotifEventRow.fromMap(r.first);
  }

  Future<void> markEventResponded(int eventId, int respondedAtMs) async {
    await db.update('notif_events', {'responded_at': respondedAtMs},
        where: 'id = ?', whereArgs: [eventId]);
  }
}
