import 'dart:async';

/// Best-effort delivery for platforms with no OS wake (Windows/web/Linux
/// while running — spec §Platform specifics): a periodic in-process sweep.
/// Coarse 5-minute tick instead of a computed next-due deadline: the sweep
/// is cheap and idempotent, and a fixed tick survives clock changes.
class NotifSweepTimer {
  final Future<void> Function() sweep;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  NotifSweepTimer({
    required this.sweep,
    this.interval = const Duration(minutes: 5),
  });

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) async {
      if (_running) return; // a slow sweep must not overlap itself
      _running = true;
      try {
        await sweep();
      } finally {
        _running = false;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
