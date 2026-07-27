import 'package:cupitor/notif/notif_timer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ticks call the sweep on the interval and stop cleanly', () {
    fakeAsync((async) {
      var sweeps = 0;
      final timer = NotifSweepTimer(
        sweep: () async => sweeps++,
        interval: const Duration(minutes: 5),
      )..start();
      async.elapse(const Duration(minutes: 16));
      expect(sweeps, 3);
      timer.stop();
      async.elapse(const Duration(minutes: 30));
      expect(sweeps, 3);
    });
  });

  test('start is idempotent', () {
    fakeAsync((async) {
      var sweeps = 0;
      final timer = NotifSweepTimer(
        sweep: () async => sweeps++,
        interval: const Duration(minutes: 5),
      );
      timer.start();
      timer.start();
      async.elapse(const Duration(minutes: 6));
      expect(sweeps, 1);
      timer.stop();
    });
  });
}
