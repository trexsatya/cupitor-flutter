import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_error.dart';

/// One `initialize()` for the whole app, and one owner of its callbacks.
///
/// Two facts about `speech_to_text` force this to exist.
///
/// **It hands out a process-wide singleton.** `SpeechToText()` is a factory
/// returning a static instance, so every `SpeechToText()` in this app is the
/// same object, with one recognizer, one result listener and one status
/// listener behind it.
///
/// **`initialize()` honours only the first registration.** It early-returns
/// once it has worked, *without* reassigning `onStatus` / `onError`:
///
/// ```dart
/// if (_initWorked) { return Future.value(_initWorked); }
/// ```
///
/// Later callers still get `true` back, so nothing looks wrong — their
/// callbacks are simply never invoked. Which feature worked therefore
/// depended on which screen the user happened to open first.
///
/// ## Why ownership rather than broadcast
///
/// Delivering every event to every feature does not work either, because the
/// microphone has exactly one holder and the events do not say who they are
/// for. Worse, `stop()` and `cancel()` make the platform emit `notListening`
/// and `done` — so one feature releasing the mic produces an "utterance
/// ended" that a second feature would read as its own cue to listen again.
/// Two auto-restarting loops then fight over the plugin's single result
/// listener indefinitely.
///
/// So callbacks go to the current owner and nobody else. A feature calls
/// [acquire] immediately before `listen()` and [release] when it stops. Taking
/// the mic notifies the displaced owner through [SpeechHubListener.onSpeechLost]
/// so it can settle whatever it had open and reset its UI, instead of being
/// left with a lit mic icon and no events.
class SpeechHub {
  SpeechHub._();

  /// The shared recognizer. Use this rather than constructing `SpeechToText()`
  /// locally, so the singleton assumption is visible in the code.
  static final stt.SpeechToText speech = stt.SpeechToText();

  static bool _initWorked = false;
  static Future<bool>? _initInFlight;
  static SpeechHubListener? _owner;

  static bool get isInitialized => _initWorked;

  @visibleForTesting
  static SpeechHubListener? get owner => _owner;

  static bool owns(SpeechHubListener listener) => identical(_owner, listener);

  /// Claims the recognizer's callbacks for [listener].
  ///
  /// Call immediately before `listen()`. The previous owner, if any, is told
  /// it lost the microphone.
  static void acquire(SpeechHubListener listener) {
    if (identical(_owner, listener)) return;
    final displaced = _owner;
    _owner = listener;
    if (displaced != null) _guard(displaced.onSpeechLost);
  }

  /// Gives up the callbacks, if [listener] still holds them. Safe to call
  /// from `dispose()` and safe to call twice.
  static void release(SpeechHubListener listener) {
    if (identical(_owner, listener)) _owner = null;
  }

  /// Disconnect callbacks before recorder cleanup can emit late speech errors.
  /// The caller resets its own UI; only a different owner needs onSpeechLost.
  static void releaseForMicHandoff(SpeechHubListener caller) {
    final displaced = _owner;
    _owner = null;
    if (displaced != null && !identical(displaced, caller)) {
      _guard(displaced.onSpeechLost);
    }
  }

  /// Initializes the recognizer once, wiring its callbacks to this hub.
  /// Safe to call from every feature, on every use, concurrently.
  static Future<bool> ensureInitialized() {
    if (_initWorked) return Future<bool>.value(true);
    // Memoized: two features racing here would otherwise both call
    // initialize(), which on Android can raise a second mic-permission prompt.
    return _initInFlight ??= _initialize();
  }

  static Future<bool> _initialize() async {
    try {
      _initWorked = await speech.initialize(
        onStatus: dispatchStatus,
        onError: dispatchError,
      );
    } catch (e) {
      debugPrint('Speech init error: $e');
      _initWorked = false;
    }
    _initInFlight = null;
    return _initWorked;
  }

  /// Entry point for the recognizer's status callback. Public so tests can
  /// drive it without a platform channel.
  static void dispatchStatus(String status) {
    final o = _owner;
    if (o != null) _guard(() => o.onSpeechStatus(status));
  }

  /// Entry point for the recognizer's error callback.
  static void dispatchError(SpeechRecognitionError error) {
    final o = _owner;
    if (o != null) _guard(() => o.onSpeechError(error));
  }

  // A feature throwing must not take the recognizer down with it — the next
  // event still has to reach whoever owns the mic.
  static void _guard(void Function() body) {
    try {
      body();
    } catch (e, st) {
      debugPrint('Speech listener threw: $e\n$st');
    }
  }

  /// Test seam — drops the owner and the initialized flag.
  @visibleForTesting
  static void resetForTest() {
    _owner = null;
    _initWorked = false;
    _initInFlight = null;
  }
}

/// A feature's claim on the shared recognizer. Hold the instance you pass to
/// [SpeechHub.acquire] so you can [SpeechHub.release] it again.
class SpeechHubListener {
  final void Function(String status) onSpeechStatus;
  final void Function(SpeechRecognitionError error) onSpeechError;

  /// Another feature took the microphone. Settle anything still open and put
  /// the UI back — no further events are coming.
  final void Function() onSpeechLost;

  const SpeechHubListener({
    required this.onSpeechStatus,
    required this.onSpeechError,
    required this.onSpeechLost,
  });
}
