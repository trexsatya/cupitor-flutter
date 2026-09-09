import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/speech_session.dart';

/// The rule §5.1 of docs/speech-bridge-spec.md calls "easy to get wrong":
/// `stop` and `cancel` carry their own rid, but the webapp registers no
/// pending entry for them. Every reply must therefore address the `start`
/// rid. Answering the stop/cancel rid leaks the pending entry forever.
void main() {
  late SpeechSession s;

  setUp(() => s = SpeechSession());

  /// Drives a session to the `listening` phase the way the host does.
  void beListening({String rid = 'A', String? locale}) {
    s.start(rid, locale);
    s.listenIssued(rid);
    s.listening(rid);
  }

  /// The window inside `start` where the host is still freeing the mic and
  /// has not called the engine's `listen()` yet.
  void beFreeingMic({String rid = 'A'}) => s.start(rid, null);

  group('start', () {
    test('claims the session and asks the host to listen', () {
      final a = s.start('A', 'sv');
      expect(a, isA<SpeechListen>());
      expect((a as SpeechListen).rid, 'A');
      expect(a.locale, 'sv');
      expect(s.phase, SpeechPhase.starting);
      expect(s.startRid, 'A');
    });

    test('an empty rid is unanswerable, so it is ignored', () {
      expect(s.start('', 'sv'), isA<SpeechNoOp>());
      expect(s.phase, SpeechPhase.idle);
    });

    test('a second start is BUSY and leaves the first session claimed', () {
      s.start('A', null);
      final a = s.start('B', null);
      expect(a, isA<SpeechReply>());
      expect((a as SpeechReply).rid, 'B');
      expect(a.error, 'BUSY');
      expect(s.startRid, 'A', reason: 'the in-flight session must survive');
    });

    test('is BUSY while listening too', () {
      beListening();
      expect((s.start('B', null) as SpeechReply).error, 'BUSY');
      expect(s.startRid, 'A');
    });

    test('BUSY does not claim to end the session it was protecting', () {
      // The host releases the mic and kills the watchdog on settlesSession.
      // If BUSY claimed it, rejecting a second tap would tear down the live
      // dictation and leave its rid unsettled forever.
      beListening();
      final busy = s.start('B', null) as SpeechReply;
      expect(busy.terminal, isTrue, reason: "B's promise is settled");
      expect(busy.settlesSession, isFalse, reason: "A's mic must be left alone");
      // A is still fully usable afterwards.
      expect((s.stop() as SpeechReply).rid, 'A');
    });

    test('a partial does not end the session either', () {
      beListening();
      final a = s.result('mid', isFinal: false) as SpeechReply;
      expect(a.settlesSession, isFalse);
    });

    test('every real settle does claim the session', () {
      for (final settle in <SpeechAction Function(SpeechSession)>[
        (x) => x.stop(),
        (x) => x.cancel(),
        (x) => x.result('done', isFinal: true),
        (x) => x.engineError('boom'),
        (x) => x.engineDoneConfirmed(),
        (x) => x.engineDone(), // non-empty transcript settles
      ]) {
        final x = SpeechSession()..start('A', null);
        x.listenIssued('A');
        x.listening('A');
        x.result('words', isFinal: false);
        expect((settle(x) as SpeechReply).settlesSession, isTrue);
      }
    });

    test('abort releases the mic too', () {
      s.start('A', null);
      final a = s.abort('A', 'mic-busy') as SpeechReply;
      expect(a.settlesSession, isTrue,
          reason: 'the host keys its _speech.cancel() off this');
    });
  });

  group('stop', () {
    test('settles the START rid, never the stop rid', () {
      beListening();
      s.result('hej da', isFinal: false);
      final a = s.stop();
      expect(a, isA<SpeechReply>());
      expect((a as SpeechReply).rid, 'A',
          reason: 'a reply to the stop rid would be dropped by the webapp');
      expect(a.result, 'hej da');
      expect(a.error, isNull);
      expect(s.phase, SpeechPhase.idle);
    });

    test('trims the transcript', () {
      beListening();
      s.result('  spaced  ', isFinal: false);
      expect((s.stop() as SpeechReply).result, 'spaced');
    });

    test('while idle is fire-and-forget', () {
      expect(s.stop(), isA<SpeechNoOp>());
    });

    test('during starting settles and releases the rid claim', () {
      s.start('A', null);
      final a = s.stop();
      expect((a as SpeechReply).rid, 'A');
      expect(a.result, '');
      expect(s.startRid, isNull,
          reason: 'the host guards on startRid to skip a pending listen()');
    });
  });

  group('cancel', () {
    test('settles the START rid with the cancelled spelling', () {
      beListening();
      s.result('discard me', isFinal: false);
      final a = s.cancel();
      expect((a as SpeechReply).rid, 'A');
      expect(a.error, 'cancelled',
          reason: "§8: the webapp matches /no-bridge|cancel/i to stay silent");
      expect(a.result, isNull);
      expect(s.phase, SpeechPhase.idle);
    });

    test('while idle is fire-and-forget', () {
      expect(s.cancel(), isA<SpeechNoOp>());
    });

    test('during starting settles', () {
      s.start('A', null);
      expect((s.cancel() as SpeechReply).error, 'cancelled');
      expect(s.startRid, isNull);
    });
  });

  group('results', () {
    test('interim streams a partial and keeps the promise open', () {
      beListening();
      final a = s.result('halv', isFinal: false);
      expect((a as SpeechReply).rid, 'A');
      expect(a.partial, 'halv');
      expect(a.result, isNull);
      expect(a.terminal, isFalse);
      expect(s.phase, SpeechPhase.listening);
    });

    test('final settles and closes the session', () {
      beListening();
      final a = s.result('hela meningen', isFinal: true);
      expect((a as SpeechReply).result, 'hela meningen');
      expect(a.partial, isNull, reason: '§4 rule 2: never send both');
      expect(s.phase, SpeechPhase.idle);
    });

    test('a result during starting is honoured and promotes the phase', () {
      // _resultListener is assigned synchronously at the top of listen(),
      // so a result can land before the host has seen the engine go live.
      s.start('A', null);
      s.listenIssued('A');
      final a = s.result('early', isFinal: false);
      expect((a as SpeechReply).partial, 'early');
      expect(s.phase, SpeechPhase.listening);
    });

    test('an empty final does not wipe a good partial', () {
      beListening();
      s.result('kept', isFinal: false);
      expect((s.result('', isFinal: true) as SpeechReply).result, 'kept');
    });

    test('while idle is ignored', () {
      expect(s.result('noise', isFinal: true), isA<SpeechNoOp>());
    });
  });

  group('engine done', () {
    test('with a transcript settles immediately', () {
      beListening();
      s.result('heard this', isFinal: false);
      final a = s.engineDone();
      expect((a as SpeechReply).rid, 'A');
      expect(a.result, 'heard this');
      expect(s.phase, SpeechPhase.idle);
    });

    test('with nothing heard defers, because an error may still follow', () {
      // doneNoResult reaches the app as 'done' ungated and lands BEFORE the
      // real error, so settling here would resolve '' and misroute the error.
      beListening();
      expect(s.engineDone(), isA<SpeechDefer>());
      expect(s.phase, SpeechPhase.listening, reason: 'still open during debounce');
    });

    test('confirmed after the debounce resolves empty, never an error', () {
      beListening();
      s.engineDone();
      final a = s.engineDoneConfirmed();
      expect((a as SpeechReply).rid, 'A');
      expect(a.result, '', reason: '§8: "heard nothing" is not an error');
      expect(a.error, isNull);
      expect(s.phase, SpeechPhase.idle);
    });

    test('an error during the debounce wins and the confirm is a no-op', () {
      beListening();
      s.engineDone();
      expect((s.engineError('mic-busy') as SpeechReply).error, 'mic-busy');
      expect(s.engineDoneConfirmed(), isA<SpeechNoOp>(),
          reason: 'settling twice would answer a rid the webapp has forgotten');
    });

    test('a silent settle during starting is honoured', () {
      // "Heard nothing" can arrive before the host has confirmed the engine
      // came up. Refusing it here would leave the rid to hit the start
      // deadline and surface as a spurious mic-busy alert.
      s.start('A', null);
      s.listenIssued('A');
      final a = s.engineDoneConfirmed();
      expect((a as SpeechReply).rid, 'A');
      expect(a.result, '');
      expect(a.error, isNull);
      expect(s.phase, SpeechPhase.idle);
    });

    test('status during starting is ignored', () {
      // _releaseMicFromSpeechToText() issues stop()+cancel() before listen(),
      // which provokes a 'done' of our own making.
      s.start('A', null);
      expect(s.engineDone(), isA<SpeechNoOp>());
      expect(s.phase, SpeechPhase.starting);
    });
  });

  group('engine error', () {
    test('settles the START rid', () {
      beListening();
      final a = s.engineError('permission-denied');
      expect((a as SpeechReply).rid, 'A');
      expect(a.error, 'permission-denied');
      expect(s.phase, SpeechPhase.idle);
    });

    test('during starting settles, once listen() has been issued', () {
      s.start('A', null);
      s.listenIssued('A');
      expect((s.engineError('mic-busy') as SpeechReply).error, 'mic-busy');
      expect(s.phase, SpeechPhase.idle);
    });

    test('while idle is ignored', () {
      expect(s.engineError('boom'), isA<SpeechNoOp>());
    });
  });

  group('events before listen() belong to the outgoing session', () {
    // Freeing the mic issues stop()+cancel() on the shared recognizer. The
    // events that produces are the *previous* session's dying breath, and
    // must not settle the rid whose mic has not even opened yet.
    test('a stray error is ignored', () {
      beFreeingMic();
      expect(s.engineError('error_client'), isA<SpeechNoOp>());
      expect(s.startRid, 'A');
      expect(s.phase, SpeechPhase.starting);
    });

    test('a stray "heard nothing" is ignored', () {
      beFreeingMic();
      expect(s.engineDoneConfirmed(), isA<SpeechNoOp>());
      expect(s.startRid, 'A');
    });

    test('a stray result is ignored', () {
      beFreeingMic();
      expect(s.result('leftovers', isFinal: true), isA<SpeechNoOp>());
      expect(s.transcript, isEmpty);
    });

    test('and the session still works normally once listen() is issued', () {
      beFreeingMic();
      s.engineError('error_client');
      s.listenIssued('A');
      s.result('hej', isFinal: false);
      expect((s.stop() as SpeechReply).result, 'hej');
    });

    test('a new session does not inherit the previous one permission', () {
      beListening();
      s.stop();
      // Fresh start: the gate must be closed again.
      s.start('B', null);
      expect(s.engineError('error_client'), isA<SpeechNoOp>());
    });
  });

  group('no double-settle', () {
    test('a late done after a stop is ignored', () {
      beListening();
      s.result('said', isFinal: false);
      s.stop();
      expect(s.engineDone(), isA<SpeechNoOp>());
      expect(s.engineDoneConfirmed(), isA<SpeechNoOp>());
    });

    test('a late error after a cancel is ignored', () {
      beListening();
      s.cancel();
      expect(s.engineError('error_client'), isA<SpeechNoOp>());
    });

    test('a late final result after a stop is ignored', () {
      beListening();
      s.stop();
      expect(s.result('too late', isFinal: true), isA<SpeechNoOp>());
    });
  });

  group('abort and listening are rid-guarded', () {
    test('abort settles the starting session', () {
      s.start('A', null);
      final a = s.abort('A', 'mic-busy');
      expect((a as SpeechReply).rid, 'A');
      expect(a.error, 'mic-busy');
      expect(s.phase, SpeechPhase.idle);
    });

    test('abort for a superseded rid is ignored', () {
      s.start('A', null);
      expect(s.abort('STALE', 'mic-busy'), isA<SpeechNoOp>());
      expect(s.startRid, 'A');
    });

    test('abort once already listening is ignored', () {
      beListening();
      expect(s.abort('A', 'mic-busy'), isA<SpeechNoOp>());
      expect(s.phase, SpeechPhase.listening);
    });

    test('listening() for a superseded rid does not revive the session', () {
      s.start('A', null);
      s.cancel();
      s.listening('A');
      expect(s.phase, SpeechPhase.idle);
    });
  });

  group('teardown', () {
    test('reports whether a session was live and leaves it reusable', () {
      expect(s.teardown(), isFalse);
      beListening();
      s.result('dropped', isFinal: false);
      expect(s.teardown(), isTrue);
      expect(s.phase, SpeechPhase.idle);
      expect(s.startRid, isNull);
      expect(s.start('B', null), isA<SpeechListen>());
      expect(s.transcript, isEmpty, reason: 'no bleed between sessions');
    });
  });

  group('speechBcp47', () {
    test('maps the codes the page actually sends', () {
      // §6: bare ISO-639-1 from the page, not BCP-47 tags.
      expect(speechBcp47('sv'), 'sv-SE');
      expect(speechBcp47('es'), 'es-ES');
      expect(speechBcp47('en'), 'en-US');
    });

    test('unknown or absent means device default', () {
      expect(speechBcp47('de'), isNull);
      expect(speechBcp47(''), isNull);
      expect(speechBcp47(null), isNull);
    });
  });

  group('mapSpeechError', () {
    test('"heard nothing" is silent, not a failure', () {
      expect(mapSpeechError('error_no_match').silent, isTrue);
      expect(mapSpeechError('error_speech_timeout').silent, isTrue);
    });

    test('maps the situations §8 names', () {
      expect(mapSpeechError('error_permission').error, 'permission-denied');
      expect(mapSpeechError('error_insufficient_permissions').error,
          'permission-denied');
      expect(mapSpeechError('error_busy').error, 'mic-busy');
      expect(mapSpeechError('error_recognizer_busy').error, 'mic-busy');
      expect(mapSpeechError('error_audio_error').error, 'mic-busy');
    });

    test('keeps messages short and human, never a raw code', () {
      // §8: the message is shown as alert('Dictation failed.\n' + message).
      for (final code in const [
        'error_network',
        'error_network_timeout',
        'error_server',
        'error_client',
        'error_language_not_supported',
        'something_unheard_of',
      ]) {
        final outcome = mapSpeechError(code);
        expect(outcome.silent, isFalse);
        expect(outcome.error, isNot(contains('error_')),
            reason: '$code leaked a raw plugin code to the user');
        expect(outcome.error!.length, lessThan(40));
      }
    });
  });
}
