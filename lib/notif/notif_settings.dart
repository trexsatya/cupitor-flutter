import 'package:shared_preferences/shared_preferences.dart';

import 'waking_clock.dart';

/// Global notification settings (spec: waking window default 05:00–22:00,
/// per-fire cap default 5). Cached statics because the bridge and (Plan 2)
/// the scheduler need synchronous reads; init() runs in the same startup
/// sequence as PlaylistService.init(). Prefs-unavailable → defaults stand,
/// matching the feature's self-disable posture.
class NotifSettings {
  NotifSettings._();
  static const _kWakeStart = 'notifWakeStart';
  static const _kWakeEnd = 'notifWakeEnd';
  static const _kPerFireCap = 'notifPerFireCap';

  static WakingWindow window = WakingWindow.defaults;
  static int perFireCap = 5;

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      window = WakingWindow.fromStrings(
        prefs.getString(_kWakeStart) ?? '05:00',
        prefs.getString(_kWakeEnd) ?? '22:00',
      );
      perFireCap = prefs.getInt(_kPerFireCap) ?? 5;
    } catch (_) {/* defaults stand */}
  }

  static Future<void> setWindow(String start, String end) async {
    window = WakingWindow.fromStrings(start, end);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kWakeStart, start);
      await prefs.setString(_kWakeEnd, end);
    } catch (_) {/* best effort */}
  }

  static Future<void> setPerFireCap(int cap) async {
    perFireCap = cap;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPerFireCap, cap);
    } catch (_) {/* best effort */}
  }
}
