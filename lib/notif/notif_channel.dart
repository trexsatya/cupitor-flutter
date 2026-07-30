import 'pending_fire.dart';

/// Callbacks out of the notification system into the app. Wired in main.dart
/// (foreground) and the background action handler.
class NotifCallbacks {
  /// User tapped the notification body. [payloadJson] is PendingFire.payloadJson.
  final Future<void> Function(String payloadJson) onOpened;

  /// User tapped an action button ('again' | 'good' | 'easy').
  final Future<void> Function(String actionId, String payloadJson) onAction;

  const NotifCallbacks({required this.onOpened, required this.onAction});
}

/// The ONLY seam that touches a notification plugin (spec §notification_channel:
/// its implementation is the only file importing a notification package).
/// Everything above tests against a fake.
abstract class NotifChannel {
  Future<void> init(NotifCallbacks callbacks);

  /// 'granted' | 'denied' | 'unknown'
  Future<String> permissionStatus();
  Future<String> requestPermission();

  /// Android: SCHEDULE_EXACT_ALARM granted? Always true elsewhere.
  Future<bool> exactAlarmsAllowed();

  Future<void> schedule(PendingFire fire);
  Future<void> showNow(PendingFire fire);

  /// Cancel every notification this app has pending. Cupitor has no local
  /// notifications outside this feature, so plugin-level cancelAll is safe.
  Future<void> cancelAllScheduled();

  /// Ids of notifications currently displayed in the shade — empty where
  /// the platform can't enumerate them. Lets the sweep tell "the pre-armed
  /// alarm already delivered this fire" from "this fire was missed", so it
  /// records the former without re-posting (re-posting re-alerts).
  Future<Set<int>> activeNotificationIds();

  /// Take [notifId] down from the shade IF it is currently displayed;
  /// returns whether it was. Used when a resume sweep re-posts a fire the
  /// user had just tapped (the tap dismissed it before the sweep could see
  /// it). Implementations may also drop a pending alarm sharing the id —
  /// callers must rearm() after a true return.
  Future<bool> dismiss(int notifId);

  /// Offline action buttons available on this platform?
  bool get supportsActions;
}
