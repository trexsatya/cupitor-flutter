/// Identifies a recorder start across permission, microphone teardown and
/// platform awaits. Stop/cancel invalidates the pending start immediately.
class NativeRecordingStart {
  int _sequence = 0;
  int? _pending;

  bool get isPending => _pending != null;
  int get revision => _sequence;

  int? begin({required bool recording}) {
    if (recording || isPending) return null;
    return _pending = ++_sequence;
  }

  bool isCurrent(int token) => _pending == token;

  bool complete(int token) {
    if (!isCurrent(token)) return false;
    _pending = null;
    return true;
  }

  void cancel() {
    _sequence++;
    _pending = null;
  }
}
