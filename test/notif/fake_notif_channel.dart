import 'package:cupitor/notif/notif_channel.dart';
import 'package:cupitor/notif/pending_fire.dart';

/// In-memory NotifChannel for service tests: records exactly what the
/// service armed/showed/cancelled, in order.
class FakeNotifChannel implements NotifChannel {
  final List<PendingFire> scheduled = [];
  final List<PendingFire> shown = [];
  int cancelAllCalls = 0;
  String permission = 'granted';
  bool exactAllowed = true;
  NotifCallbacks? callbacks;

  @override
  Future<void> init(NotifCallbacks cb) async => callbacks = cb;
  @override
  Future<String> permissionStatus() async => permission;
  @override
  Future<String> requestPermission() async => permission;
  @override
  Future<bool> exactAlarmsAllowed() async => exactAllowed;
  @override
  Future<void> schedule(PendingFire fire) async => scheduled.add(fire);
  @override
  Future<void> showNow(PendingFire fire) async => shown.add(fire);
  @override
  Future<void> cancelAllScheduled() async {
    cancelAllCalls++;
    scheduled.clear();
  }
  @override
  bool get supportsActions => true;
}
