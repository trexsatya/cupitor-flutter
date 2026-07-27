import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'notif_channel.dart';
import 'notif_dao.dart';
import 'pending_fire.dart';
import 'recurring_scheduler.dart';
import 'schedules.dart';
import 'series_scheduler.dart';
import 'waking_clock.dart';

/// Arms and catches up notification fires (spec §Delivery). All state lives
/// in SQLite; this class is a pure translation from "what's due/upcoming"
/// to NotifChannel calls, so it tests fully against FakeNotifChannel.
/// Profile-agnostic on purpose: every profile's reviews keep firing.
class NotificationService {
  final NotifChannel channel;
  final Future<NotifDao?> Function() dao;
  final WakingWindow Function() window;
  final int Function() perFireCap;
  final tz.TZDateTime Function() now;

  /// 60 on iOS (headroom under the 64-pending hard cap), 200 elsewhere.
  final int maxArmed;

  NotificationService({
    required this.channel,
    required this.dao,
    required this.window,
    required this.perFireCap,
    required this.now,
    required this.maxArmed,
  });

  /// Stable notification ids: cancel-and-rearm must be idempotent and a
  /// grade must be able to cancel exactly its own notification. The offset
  /// keeps this range disjoint from any future id families (int32-safe).
  static int itemNotifId(int itemId) => 0x1000000 + itemId;

  /// Rearm window: 48 absolute hours (spec §Arming).
  static const int windowMs = 48 * 3600 * 1000;

  /// Sweep grace: overdue by at most this many WAKING hours → post now;
  /// older → silent auto-advance (spec §The sweep).
  static const double graceWakingHours = 2;

  // ── rearm ────────────────────────────────────────────────────────────

  /// Cancel-everything-then-arm-the-window. Triggers (wired in main.dart /
  /// worker): app resume, boot, any fire, any grade, any bridge mutation,
  /// settings change, worker tick.
  Future<void> rearm() async {
    final d = await dao();
    if (d == null) return;
    final t = now();
    final nowMs = t.millisecondsSinceEpoch;

    await channel.cancelAllScheduled();

    final fires = <PendingFire>[];
    for (final item in await d.upcomingItems(nowMs, nowMs + windowMs)) {
      fires.add(await _itemFire(d, item, item.nextDueAt!,
          withActions: await _isSeriesList(d, item.listId)));
    }
    for (final list in await d.recurringUpcomingLists(nowMs, nowMs + windowMs)) {
      fires.addAll(await _recurringFires(d, list, list.nextFireAt!));
    }

    fires.sort((a, b) => a.whenMs.compareTo(b.whenMs));
    final cap = perFireCap();
    final perMinute = <int, int>{};
    var armed = 0;
    for (final f in fires) {
      if (armed >= maxArmed) break;
      final bucket = f.whenMs ~/ 60000;
      final inBucket = perMinute[bucket] ?? 0;
      if (inBucket >= cap) continue; // deferred: next rearm picks it up
      perMinute[bucket] = inBucket + 1;
      armed++;
      await channel.schedule(f);
    }
  }

  // ── shared fire construction ─────────────────────────────────────────

  Future<bool> _isSeriesList(NotifDao d, int listId) async {
    final list = await d.listById(listId);
    if (list?.scheduleId == null) return false;
    final s = await d.scheduleById(list!.scheduleId!);
    return s?.kind == 'series';
  }

  Future<PendingFire> _itemFire(NotifDao d, NotifItemRow item, int whenMs,
      {required bool withActions}) async {
    final list = await d.listById(item.listId);
    return PendingFire(
      notifId: itemNotifId(item.id),
      whenMs: whenMs,
      title: item.title,
      body: item.body,
      payloadJson: jsonEncode({
        'v': 1,
        'item_id': item.id,
        'list_ek': list?.externalKey,
        'item_eid': item.externalId,
        'open_url': item.openUrl,
        'echo': item.payload == null ? null : jsonDecode(item.payload!),
      }),
      groupKey: 'cupitor-notif-list-${item.listId}',
      withActions: withActions && channel.supportsActions,
    );
  }

  /// The items a recurring list would show at [whenMs], selected with the
  /// CURRENT cursor. The cursor only advances when the fire is processed
  /// (sweep) — consecutive unattended fires may repeat items; documented
  /// spec §Delivery trade-off for content frozen at arm time.
  Future<List<PendingFire>> _recurringFires(
      NotifDao d, NotifListRow list, int whenMs) async {
    final schedule =
        list.scheduleId == null ? null : await d.scheduleById(list.scheduleId!);
    if (schedule == null || schedule.kind != 'recurring') return const [];
    final cfg = parseRecurring(
        jsonDecode(schedule.config) as Map<String, dynamic>);
    final items = await d.itemsForList(list.id);
    final sel = takeForFire<NotifItemRow>(
        items, list.cursor, cfg.perFire, (i) => i.status == 'active');
    return [
      for (final item in sel.items)
        await _itemFire(d, item, whenMs, withActions: false)
    ];
  }
}
