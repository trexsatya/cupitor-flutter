import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../db.dart';
import 'notif_channel.dart';
import 'notification_channel.dart';
import 'notif_settings.dart';
import 'notification_service.dart';

/// Isolate-safe notification runtime. These globals are lazy top-level
/// finals: each isolate (main, plugin callback isolate, workmanager worker)
/// constructs its own instances on first touch, with no dependence on
/// main()-only initialization.
///
/// This matters because `notifBackgroundActionHandler` below is invoked by
/// flutter_local_notifications' own background dispatcher in a FRESH
/// isolate when an action is tapped and the app is dead (or, on Android,
/// even while alive — `showsUserInterface: false` actions always route
/// through the plugin's background ActionBroadcastReceiver path). main()
/// never runs in that isolate, so anything that depended on main()-time
/// mutation (e.g. a static field assigned inside main()) would read as
/// null/uninitialized there. Top-level finals have no such dependency:
/// first access in ANY isolate constructs them from scratch.

/// Feature-wide singletons. Channel choice: real plugin adapter where it
/// delivers, noop shim on Windows/web (spec §Platform specifics).
final NotifChannel notifChannel = FlutterNotifChannel.platformSupported
    ? FlutterNotifChannel()
    : NoopNotifChannel();

final NotificationService notifService = NotificationService(
  channel: notifChannel,
  dao: () => CupitorDb.instance.notifDao(),
  window: () => NotifSettings.window,
  perFireCap: () => NotifSettings.perFireCap,
  now: () => tz.TZDateTime.now(tz.local),
  retainCallItems: (ids) async {
    if (notifChannel is FlutterNotifChannel) {
      await (notifChannel as FlutterNotifChannel).retainCallItems(ids);
    }
  },
  maxArmed: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? 60 : 200,
);

/// Background isolate action handler (app may be dead). Boots just enough
/// of the world — bindings, tz, db — grades, and rearms. No webview here;
/// the webpage learns about the grade from the lists warm-push next launch.
@pragma('vm:entry-point')
Future<void> notifBackgroundActionHandler(
    String actionId, String payloadJson) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    tzdata.initializeTimeZones();
    try {
      final zoneName = await FlutterTimezone.getLocalTimezone()
          .timeout(const Duration(seconds: 2));
      tz.setLocalLocation(tz.getLocation(zoneName));
    } catch (_) {/* UTC */}
    await NotifSettings.init();
    await notifChannel.init(NotifCallbacks(
      onOpened: (_) async {/* taps never route here */},
      onAction: (_, __) async {},
    ));
    await notifService.handleAction(actionId, payloadJson);
  } catch (e) {
    debugPrint('notif background action failed: $e');
  }
}
