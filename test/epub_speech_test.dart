import 'package:cupitor/epub_reader.dart';
import 'package:cupitor/epub_speech.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('existing books retain speed and get read-aloud defaults', () {
    final state = EpubReadingState.fromJson({'ttsRate': 0.8});
    expect(state.ttsRate, 0.8);
    expect(state.ttsReplacements, epubDefaultTtsReplacements);
    expect(state.ttsNewlinePauseMs, 700);
    expect(state.ttsParagraphPauseMs, 1200);
  });

  test('disabled rules and zero pause survive a settings round trip', () {
    final state = EpubReadingState(
      ttsRate: 0.7,
      ttsReplacements: '',
      ttsNewlinePauseMs: 0,
      ttsParagraphPauseMs: 2200,
    );
    final restored = EpubReadingState.fromJson(state.toJson());
    expect(restored.ttsRate, 0.7);
    expect(restored.ttsReplacements, '');
    expect(restored.ttsNewlinePauseMs, 0);
    expect(restored.ttsParagraphPauseMs, 2200);
  });

  test('speech replacements are literal and can delete text', () {
    final rules = parseEpubTtsReplacements(
      '$epubDefaultTtsReplacements\n[skip]=\nfoo=one=two',
    );
    expect(
      applyEpubTtsReplacements('A->B → foo [skip]', rules),
      'A could be B could be one=two',
    );
    expect(parseEpubTtsReplacements(''), isEmpty);
    expect(() => parseEpubTtsReplacements('  =word'), throwsFormatException);
    expect(
      () => parseEpubTtsReplacements('missing equals'),
      throwsFormatException,
    );
  });

  test(
    'resume retains the interrupted word and advances after completed lines',
    () {
      final position = EpubSpeechPosition();
      const line = 'Read this line aloud.';
      expect(position.resumeOffset(line), 0);
      position.speechOffset = line.indexOf('line');
      expect(line.substring(position.resumeOffset(line)), 'line aloud.');
      expect(position.resumeOffset('Replaced text'), 0);
      position.advanceLine();
      expect(position.nextLine, 1);
      expect(position.speechOffset, 0);
      position.advanceChapter();
      expect(position.nextLine, 0);
    },
  );

  test('long lines stay within the engine limit and keep Unicode intact', () {
    final words = List.filled(1200, 'word').join(' ');
    final utterances = epubTtsUtterances(words).toList();
    expect(utterances, hasLength(2));
    expect(utterances.every((part) => part.length <= 4000), isTrue);
    expect(utterances.join(' '), words);

    final unbroken = '${'a' * 3999}🙂z';
    final chunks = epubTtsUtterances(unbroken).toList();
    expect(chunks[1], '🙂z');
    expect(chunks.join(), unbroken);
  });
}
