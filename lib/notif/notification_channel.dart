import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'notif_channel.dart';
import 'notif_runtime.dart';
import 'pending_fire.dart';

/// Background action entry point — must be top-level with vm:entry-point so
/// the engine can invoke it in a fresh isolate while the app is dead (or,
/// on Android, even while the app is alive: `showsUserInterface: false`
/// actions always route through the plugin's background dispatcher).
/// Calls the isolate-safe top-level handler in notif_runtime.dart directly
/// — NOT a mutable static set by main(), which would be null in this fresh
/// isolate since main() never runs there. Kept here (rather than folded
/// into notif_runtime.dart) so this file remains the only plugin importer;
/// the resulting notification_channel <-> notif_runtime import cycle is
/// legal Dart, and notif_runtime.dart itself never imports the plugin.
@pragma('vm:entry-point')
void notifBackgroundResponse(NotificationResponse response) {
  notifBackgroundActionHandler(response.actionId ?? '', response.payload ?? '');
}

/// flutter_local_notifications adapter. The ONLY file that imports the
/// plugin (spec §notification_channel). Android channel id/name and the
/// Darwin category are fixed constants — changing them orphans armed
/// notifications.
class FlutterNotifChannel implements NotifChannel {
  static const String androidChannelId = 'cupitor_reviews';
  static const String androidChannelName = 'Review reminders';
  static const String darwinCategoryId = 'cupitorNotif';

  final _plugin = FlutterLocalNotificationsPlugin();
  NotifCallbacks? _callbacks;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _isDarwin =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  bool get supportsActions => _isAndroid || _isDarwin;

  @override
  Future<void> init(NotifCallbacks callbacks) async {
    _callbacks = callbacks;
    // DarwinNotificationAction.plain is a plain (non-const) factory
    // constructor in 18.0.1, so this list can't be `const`.
    final actions = [
      DarwinNotificationAction.plain('again', 'Again'),
      DarwinNotificationAction.plain('good', 'Good'),
      DarwinNotificationAction.plain('easy', 'Easy'),
    ];
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(darwinCategoryId, actions: actions),
      ],
    );
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: darwin,
      macOS: darwin,
      linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notifBackgroundResponse,
    );
  }

  void _onResponse(NotificationResponse r) {
    final cb = _callbacks;
    if (cb == null) return;
    final payload = r.payload ?? '';
    if (r.notificationResponseType ==
        NotificationResponseType.selectedNotificationAction) {
      cb.onAction(r.actionId ?? '', payload);
    } else {
      cb.onOpened(payload);
    }
  }

  /// Terminated-tap: if the app was launched by tapping a notification,
  /// return its payload so main.dart can route after startup.
  Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details!.notificationResponse?.payload;
  }

  @override
  Future<String> permissionStatus() async {
    try {
      if (_isAndroid) {
        final enabled = await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.areNotificationsEnabled();
        return enabled == null ? 'unknown' : (enabled ? 'granted' : 'denied');
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        // 18.0.1's IOSFlutterLocalNotificationsPlugin exposes
        // checkPermissions() -> NotificationsEnabledOptions?; map isEnabled.
        final options = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.checkPermissions();
        if (options == null) return 'unknown';
        return options.isEnabled ? 'granted' : 'denied';
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        // Same checkPermissions() shape on MacOSFlutterLocalNotificationsPlugin.
        final options = await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.checkPermissions();
        if (options == null) return 'unknown';
        return options.isEnabled ? 'granted' : 'denied';
      }
    } catch (e) {
      debugPrint('notif permissionStatus failed: $e');
    }
    return 'unknown';
  }

  @override
  Future<String> requestPermission() async {
    try {
      if (_isAndroid) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        return granted == true ? 'granted' : 'denied';
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        return granted == true ? 'granted' : 'denied';
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        return granted == true ? 'granted' : 'denied';
      }
    } catch (e) {
      debugPrint('notif requestPermission failed: $e');
    }
    return 'unknown';
  }

  @override
  Future<bool> exactAlarmsAllowed() async {
    if (!_isAndroid) return true;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  NotificationDetails _details(PendingFire fire) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        androidChannelId,
        androidChannelName,
        channelDescription: 'Spaced-repetition review reminders',
        groupKey: fire.groupKey,
        // Without a summary row Android's auto-grouping ignores our custom
        // groupKey (it only kicks in below 4 ungrouped notifications), so
        // grouped fires never collapse into a stack.
        setAsGroupSummary: fire.isSummary,
        actions: fire.withActions
            ? const [
                AndroidNotificationAction('again', 'Again',
                    showsUserInterface: false),
                AndroidNotificationAction('good', 'Good',
                    showsUserInterface: false),
                AndroidNotificationAction('easy', 'Easy',
                    showsUserInterface: false),
              ]
            : null,
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: fire.withActions ? darwinCategoryId : null,
        threadIdentifier: fire.groupKey,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: fire.withActions ? darwinCategoryId : null,
        threadIdentifier: fire.groupKey,
      ),
      linux: const LinuxNotificationDetails(),
    );
  }

  @override
  Future<void> schedule(PendingFire fire) async {
    final exact = await exactAlarmsAllowed();
    await _plugin.zonedSchedule(
      fire.notifId,
      fire.title,
      fire.body,
      tz.TZDateTime.fromMillisecondsSinceEpoch(tz.local, fire.whenMs),
      _details(fire),
      payload: fire.payloadJson,
      // 18.0.1's top-level zonedSchedule requires this even though it only
      // matters for iOS < 10; our scheduledDate is already an absolute
      // TZDateTime so "absoluteTime" is the correct interpretation.
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          // Exact denied → degrade honestly (spec: report exact_alarms:false,
          // "timing approximate"), never silently drop the fire.
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> showNow(PendingFire fire) async {
    await _plugin.show(fire.notifId, fire.title, fire.body, _details(fire),
        payload: fire.payloadJson);
  }

  @override
  Future<void> cancelAllScheduled() async {
    // NOT _plugin.cancelAll(): that also dismisses notifications already
    // SHOWING in the shade — and rearm() (whose first step is this call)
    // runs on every sweep/resume/mutation, so fires vanished seconds after
    // appearing whenever the app was alive. Cancel pending requests one by
    // one instead, and leave any id that is currently displayed alone:
    // cancel(id) dismisses the displayed instance too (stable per-item ids).
    // A stale pending that shares an id with a displayed fire is either
    // replaced by the re-arm that follows (zonedSchedule on the same id
    // replaces) or, worst case, fires once spuriously — acceptable next to
    // eating every visible notification.
    List<PendingNotificationRequest> pending;
    try {
      pending = await _plugin.pendingNotificationRequests();
    } catch (_) {
      return; // platform can't enumerate → it can't have scheduled either
    }
    // Empty when unsupported (e.g. Linux, old OS): fall through and cancel
    // every pending id.
    final active = await activeNotificationIds();
    for (final p in pending) {
      if (active.contains(p.id)) continue;
      try {
        await _plugin.cancel(p.id);
      } catch (_) {/* one failed cancel must not stop the rest */}
    }
  }

  @override
  Future<Set<int>> activeNotificationIds() async {
    try {
      return {
        for (final n in await _plugin.getActiveNotifications())
          if (n.id != null) n.id!,
      };
    } catch (_) {
      return const {}; // platform can't enumerate the shade
    }
  }

  @override
  Future<bool> dismiss(int notifId) async {
    try {
      if (!(await activeNotificationIds()).contains(notifId)) return false;
      // cancel() also drops a same-id pending alarm — the caller rearms.
      await _plugin.cancel(notifId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True where this plugin actually delivers (spec: Windows/web are the
  /// timer-only shim, handled by NoopNotifChannel).
  static bool get platformSupported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS ||
          Platform.isLinux);
}

/// Windows/web shim: no OS notifications, no actions. The in-process timer
/// (Task 11) still runs the sweep so state advances while the app is open;
/// getCapabilities reports actions:false, and 'granted' here means "no
/// permission concept on this platform", not a real grant.
class NoopNotifChannel implements NotifChannel {
  @override
  Future<void> init(NotifCallbacks callbacks) async {}
  @override
  Future<String> permissionStatus() async => 'granted';
  @override
  Future<String> requestPermission() async => 'granted';
  @override
  Future<bool> exactAlarmsAllowed() async => false;
  @override
  Future<void> schedule(PendingFire fire) async {}
  @override
  Future<void> showNow(PendingFire fire) async {}
  @override
  Future<void> cancelAllScheduled() async {}
  @override
  Future<Set<int>> activeNotificationIds() async => const {};
  @override
  Future<bool> dismiss(int notifId) async => false;
  @override
  bool get supportsActions => false;
}
