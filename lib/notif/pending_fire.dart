/// One concrete notification the service wants shown — either scheduled for
/// [whenMs] (epoch ms, strictly future) or posted immediately via showNow.
/// Content is frozen at arm time (spec §Delivery): the OS holds this, the
/// app may be dead when it fires.
class PendingFire {
  /// Stable id derived from the item id (see `NotificationService.itemNotifId`)
  /// so cancel-and-rearm is idempotent.
  final int notifId;
  final int whenMs;
  final String title;
  final String? body;

  /// JSON the tap/action callbacks get back:
  /// {"v":1,"item_id":`<internal>`,"list_ek":...,"item_eid":...,"open_url":...,
  ///  "echo":`<webpage payload>`} — internal id stays inside the app; only
  /// external ids ever reach the webpage (spec identity rule).
  final String payloadJson;

  /// Android group / Darwin thread id — one group per list.
  final String groupKey;

  /// Again/Good/Easy buttons. Only true for series-list items.
  final bool withActions;

  /// Group summary scaffolding (Android): setAsGroupSummary, exempt from caps.
  final bool isSummary;

  const PendingFire({
    required this.notifId,
    required this.whenMs,
    required this.title,
    this.body,
    required this.payloadJson,
    required this.groupKey,
    required this.withActions,
    this.isSummary = false,
  });
}
