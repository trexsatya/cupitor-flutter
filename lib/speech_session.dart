/// Decision core for the `SpeechBridge` JavaScript channel.
/// See `docs/speech-bridge-spec.md`.
///
/// Deliberately free of Flutter and of `speech_to_text` so the rid routing —
/// the part §5.1 of the spec calls "the rule that is easy to get wrong" — can
/// be unit tested. The host owns all I/O: it feeds requests and engine events
/// in, and performs the [SpeechAction] that comes back.
///
/// The invariant that makes the whole thing safe: the in-flight rid is cleared
/// *before* any settling reply is produced. A `done` or an error that arrives
/// after a `stop` then finds an idle session and returns [SpeechNoOp] instead
/// of answering a rid the webapp has already forgotten.
library;

enum SpeechPhase {
  /// Nothing in flight.
  idle,

  /// A `start` has been claimed but the engine is not confirmed live yet.
  /// Freeing the mic issues `stop()`+`cancel()` on the shared recognizer,
  /// which provokes a `done` of our own making — so status is ignored here.
  starting,

  /// The engine is running.
  listening,
}

/// What the host should do next.
sealed class SpeechAction {
  const SpeechAction();
}

/// Nothing to do. Covers every event that arrives for a session that has
/// already been settled, or for a rid that has been superseded.
class SpeechNoOp extends SpeechAction {
  const SpeechNoOp();
}

/// Free the mic and open the recognizer for [rid].
class SpeechListen extends SpeechAction {
  final String rid;

  /// Bare ISO-639-1 code straight off the page; run it through [speechBcp47].
  final String? locale;

  const SpeechListen(this.rid, this.locale);
}

/// The engine finished without hearing anything. Hold the reply briefly: a
/// real error may be a beat behind, and answering now would resolve the
/// promise empty and leave the error with nowhere to go. The host arms a
/// short timer and then calls [SpeechSession.engineDoneConfirmed].
class SpeechDefer extends SpeechAction {
  const SpeechDefer();
}

/// An envelope for `window.__cupSpeech`.
class SpeechReply extends SpeechAction {
  final String rid;
  final String? result;
  final String? error;
  final String? partial;

  /// Whether this reply ended the session that owns the mic.
  ///
  /// Distinct from [terminal], and the difference matters: a `BUSY` rejection
  /// settles the promise of the rid it names while the *other*, in-flight
  /// session carries on. Releasing the mic on it would kill the very session
  /// it was protecting, and nothing would ever settle that one's rid.
  final bool settlesSession;

  const SpeechReply(
    this.rid, {
    this.result,
    this.error,
    this.partial,
    this.settlesSession = true,
  });

  /// Whether this settles the webapp's promise. §4 rule 2: a `partial` alone
  /// leaves it open.
  bool get terminal => result != null || error != null;
}

/// A single dictation session — at most one is in flight at a time, which is
/// what lets the webapp's two 🎤 buttons share one recognizer.
class SpeechSession {
  SpeechPhase _phase = SpeechPhase.idle;
  String? _startRid;
  String _transcript = '';
  bool _listenIssued = false;

  SpeechPhase get phase => _phase;

  /// True from `start` until the session settles, `starting` included.
  bool get isBusy => _phase != SpeechPhase.idle;

  /// The rid every reply for this session must be addressed to.
  String? get startRid => _startRid;

  String get transcript => _transcript;

  /// A `start` request arrived from the page.
  SpeechAction start(String rid, String? locale) {
    // No rid means no pending entry on the other side — unanswerable.
    if (rid.isEmpty) return const SpeechNoOp();
    if (_phase != SpeechPhase.idle) {
      // Rejects the newcomer; the session already holding the mic is
      // untouched and still owes its own rid a reply.
      return SpeechReply(rid, error: 'BUSY', settlesSession: false);
    }
    _phase = SpeechPhase.starting;
    _startRid = rid;
    _transcript = '';
    return SpeechListen(rid, locale);
  }

  /// The host is about to call the engine's `listen()` for [rid].
  ///
  /// Until this point the mic still belongs to whatever session we tore down
  /// to make room, and the engine events still in flight are *its* — a stray
  /// error from the outgoing session would otherwise settle this brand-new
  /// rid before its mic ever opened.
  void listenIssued(String rid) {
    if (_startRid == rid) _listenIssued = true;
  }

  /// The host has evidence the engine is actually running.
  void listening(String rid) {
    if (_phase == SpeechPhase.starting && _startRid == rid) {
      _phase = SpeechPhase.listening;
    }
  }

  /// The host could not get the engine going for [rid].
  SpeechAction abort(String rid, String error) {
    if (_phase != SpeechPhase.starting || _startRid != rid) {
      return const SpeechNoOp();
    }
    _idle();
    return SpeechReply(rid, error: error);
  }

  /// `stop` op — settle with what was heard so far. Fire-and-forget when idle:
  /// the webapp registers no pending entry for the stop's own rid.
  SpeechAction stop() {
    final target = _startRid;
    if (target == null) return const SpeechNoOp();
    final text = _transcript.trim();
    _idle();
    return SpeechReply(target, result: text);
  }

  /// `cancel` op — discard the transcript. The 'cancelled' spelling matters:
  /// §8 says the webapp stays silent for anything matching /no-bridge|cancel/i.
  SpeechAction cancel() {
    final target = _startRid;
    if (target == null) return const SpeechNoOp();
    _idle();
    return SpeechReply(target, error: 'cancelled');
  }

  /// The recognizer produced text. Honoured while `starting` too, because the
  /// plugin assigns its result listener synchronously inside `listen()` — a
  /// result can beat the host's confirmation that the engine came up.
  SpeechAction result(String words, {required bool isFinal}) {
    if (!_listenIssued || _phase == SpeechPhase.idle) return const SpeechNoOp();
    _phase = SpeechPhase.listening;
    final target = _startRid!;
    // recognizedWords is cumulative for the utterance, so assign rather than
    // append — but never let an empty final wipe a partial we already have.
    if (words.isNotEmpty) _transcript = words;
    if (!isFinal) {
      return SpeechReply(target, partial: _transcript, settlesSession: false);
    }
    final text = _transcript.trim();
    _idle();
    return SpeechReply(target, result: text);
  }

  /// The engine reported `done`, or the host's watchdog saw it stop.
  SpeechAction engineDone() {
    if (_phase != SpeechPhase.listening) return const SpeechNoOp();
    if (_transcript.trim().isEmpty) return const SpeechDefer();
    final target = _startRid!;
    final text = _transcript.trim();
    _idle();
    return SpeechReply(target, result: text);
  }

  /// Settle quietly with whatever was heard — nothing, usually.
  ///
  /// Used when the debounce expires with no error behind the empty `done`,
  /// and when the engine reports one of the "heard nothing" codes. §8: that
  /// resolves with an empty string, so the webapp restores the field and
  /// shows nothing. Accepted while `starting` too, because such an error can
  /// arrive before the host has confirmed the engine came up — refusing it
  /// there would leave the rid to time out as a spurious failure.
  SpeechAction engineDoneConfirmed() {
    if (!_listenIssued || _phase == SpeechPhase.idle) return const SpeechNoOp();
    final target = _startRid!;
    final text = _transcript.trim();
    _idle();
    return SpeechReply(target, result: text);
  }

  /// The engine failed. [message] is user-visible — run raw plugin codes
  /// through [mapSpeechError] first.
  SpeechAction engineError(String message) {
    if (!_listenIssued || _phase == SpeechPhase.idle) return const SpeechNoOp();
    final target = _startRid!;
    _idle();
    return SpeechReply(target, error: message);
  }

  /// Drop the session without replying. Only for a page that is genuinely
  /// going away — a page that is merely hidden still holds a pending promise
  /// and must be answered, or its 🎤 button pulses forever.
  bool teardown() {
    final was = _phase != SpeechPhase.idle;
    _idle();
    return was;
  }

  void _idle() {
    _phase = SpeechPhase.idle;
    _startRid = null;
    _transcript = '';
    _listenIssued = false;
  }
}

/// Bare ISO-639-1 code from the page → the BCP-47 tag `speech_to_text` wants.
/// §6: the page sends 'sv' / 'es' / 'en', never 'sv-SE'. An unknown or absent
/// code means "device default", which the plugin spells as a null localeId.
String? speechBcp47(String? code) => switch (code) {
      'sv' => 'sv-SE',
      'es' => 'es-ES',
      'en' => 'en-US',
      _ => null,
    };

/// How a raw engine error should surface to the user.
class SpeechErrorOutcome {
  /// Null means "not a failure" — resolve the promise instead of rejecting it.
  final String? error;

  const SpeechErrorOutcome.silent() : error = null;
  const SpeechErrorOutcome.fail(String this.error);

  bool get silent => error == null;
}

/// Translate a plugin error code into what §8 wants the user to see. The
/// message ends up in `alert('Dictation failed.\n' + message)`, so it has to
/// read like a sentence fragment, not a stack trace.
SpeechErrorOutcome mapSpeechError(String code) {
  final c = code.toLowerCase();
  // The recognizer heard nothing. Not a failure — §8 says resolve with ''.
  if (c.contains('no_match') || c.contains('speech_timeout')) {
    return const SpeechErrorOutcome.silent();
  }
  if (c.contains('permission')) {
    return const SpeechErrorOutcome.fail('permission-denied');
  }
  // A busy recognizer and a busy audio path are the same story to the user:
  // something else is holding the mic.
  if (c.contains('busy') || c.contains('audio')) {
    return const SpeechErrorOutcome.fail('mic-busy');
  }
  if (c.contains('network')) {
    return const SpeechErrorOutcome.fail('No network for speech.');
  }
  if (c.contains('server')) {
    return const SpeechErrorOutcome.fail('Speech service unavailable.');
  }
  if (c.contains('language')) {
    return const SpeechErrorOutcome.fail('Language not supported.');
  }
  return const SpeechErrorOutcome.fail('speech-unavailable');
}
