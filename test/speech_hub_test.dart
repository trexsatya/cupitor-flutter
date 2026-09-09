import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';

import 'package:cupitor/speech_hub.dart';

/// The recognizer is a process-wide singleton with one set of callbacks, and
/// `initialize()` honours only the first registration. The hub owns that
/// registration and routes it to whichever feature currently holds the mic.
///
/// Routing to *every* feature instead does not work: `stop()`/`cancel()` make
/// the platform emit `notListening` + `done`, so one feature handing over the
/// mic looks exactly like "the utterance ended" to another — and two
/// auto-restarting loops then fight over the plugin's single result listener.
void main() {
  setUp(SpeechHub.resetForTest);
  tearDown(SpeechHub.resetForTest);

  SpeechHubListener recorder(List<String> log, String name) => SpeechHubListener(
        onSpeechStatus: (s) => log.add('$name:status:$s'),
        onSpeechError: (e) => log.add('$name:error:${e.errorMsg}'),
        onSpeechLost: () => log.add('$name:lost'),
      );

  test('events reach the owner and nobody else', () {
    final log = <String>[];
    final dictation = recorder(log, 'dictation');
    final maskMic = recorder(log, 'maskMic');

    SpeechHub.acquire(dictation);
    log.clear();

    SpeechHub.dispatchStatus('done');
    SpeechHub.dispatchError(SpeechRecognitionError('error_no_match', false));

    expect(log, ['dictation:status:done', 'dictation:error:error_no_match']);
    expect(SpeechHub.owner, same(dictation));
    expect(maskMic, isNotNull); // registered nowhere; hears nothing
  });

  test('taking the mic tells the previous holder it lost', () {
    // Without this the displaced feature sits with a lit mic icon waiting on
    // events that will never come.
    final log = <String>[];
    final dictation = recorder(log, 'dictation');
    final maskMic = recorder(log, 'maskMic');

    SpeechHub.acquire(dictation);
    log.clear();
    SpeechHub.acquire(maskMic);

    expect(log, ['dictation:lost']);
    expect(SpeechHub.owner, same(maskMic));
  });

  test('the displaced feature stops receiving events', () {
    // The regression this design exists to prevent: a hand-off emits `done`,
    // and the old owner must not read it as its own cue to listen again.
    final log = <String>[];
    final loopA = recorder(log, 'loopA');
    final loopB = recorder(log, 'loopB');

    SpeechHub.acquire(loopA);
    SpeechHub.acquire(loopB);
    log.clear();

    SpeechHub.dispatchStatus('done');

    expect(log, ['loopB:status:done']);
    expect(log, isNot(contains('loopA:status:done')));
  });

  test('re-acquiring by the current owner is a no-op, not a self-lost', () {
    final log = <String>[];
    final l = recorder(log, 'one');
    SpeechHub.acquire(l);
    log.clear();

    SpeechHub.acquire(l);

    expect(log, isEmpty);
    expect(SpeechHub.owner, same(l));
  });

  test('release drops ownership; a stale release does not', () {
    final log = <String>[];
    final a = recorder(log, 'a');
    final b = recorder(log, 'b');

    SpeechHub.acquire(a);
    SpeechHub.acquire(b);
    // `a` disposing later must not unseat the current owner.
    SpeechHub.release(a);
    expect(SpeechHub.owner, same(b));

    SpeechHub.release(b);
    expect(SpeechHub.owner, isNull);

    log.clear();
    SpeechHub.dispatchStatus('done');
    expect(log, isEmpty);
  });

  test('a throwing listener does not break later dispatches', () {
    // A bug in one feature must not deafen the recognizer for the next one.
    final log = <String>[];
    final bad = SpeechHubListener(
      onSpeechStatus: (_) => throw StateError('boom'),
      onSpeechError: (_) {},
      onSpeechLost: () {},
    );
    SpeechHub.acquire(bad);
    expect(() => SpeechHub.dispatchStatus('done'), returnsNormally);

    final good = recorder(log, 'good');
    SpeechHub.acquire(good);
    log.clear();
    SpeechHub.dispatchStatus('done');
    expect(log, ['good:status:done']);
  });

  test('a throwing onSpeechLost does not block the hand-off', () {
    final log = <String>[];
    final bad = SpeechHubListener(
      onSpeechStatus: (_) {},
      onSpeechError: (_) {},
      onSpeechLost: () => throw StateError('boom'),
    );
    final next = recorder(log, 'next');

    SpeechHub.acquire(bad);
    expect(() => SpeechHub.acquire(next), returnsNormally);
    expect(SpeechHub.owner, same(next));
  });

  test('dispatching with no owner is harmless', () {
    expect(() => SpeechHub.dispatchStatus('done'), returnsNormally);
    expect(
      () => SpeechHub.dispatchError(SpeechRecognitionError('error_client', true)),
      returnsNormally,
    );
  });
}
