import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cupitor/epub_reader.dart';
import 'package:cupitor/epub_speech.dart';
import 'package:flutter_test/flutter_test.dart';

import 'docx_fixtures.dart' show zipFixture;

void main() {
  test('reads EPUB language metadata and chapter overrides', () async {
    final folder = await Directory.systemTemp.createTemp(
      'cupitor_epub_speech_',
    );
    addTearDown(() => folder.delete(recursive: true));
    final archive = Archive();
    const files = {
      'META-INF/container.xml':
          '<container><rootfiles>'
          '<rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf': '''
<package xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata><dc:language>und</dc:language><dc:language>sv</dc:language></metadata>
  <manifest>
    <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
    <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine><itemref idref="a"/><itemref idref="b"/></spine>
</package>
''',
      'a.xhtml': '<html><body><p>Hej.</p></body></html>',
      'b.xhtml':
          '<html lang="en"><body xml:lang="es-MX"><p>Hola.</p></body></html>',
      'nav.xhtml':
          '<html><body><nav type="toc"><ol><li>'
          '<a href="b.xhtml">Spanish chapter</a></li></ol></nav></body></html>',
    };
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final file = await File.fromUri(
      folder.uri.resolve('book.epub'),
    ).writeAsBytes(zipFixture(archive));
    final book = await EpubBook.openFile(file);
    expect(book.chapters[1].title, 'Spanish chapter');
    expect(book.speechLanguageForChapter(0, 'en-US'), 'sv');
    expect(book.speechLanguageForChapter(1, 'en-US'), 'es-MX');
  });

  test('speech engine locale prefers exact and same-language voices', () {
    const available = ['en-US', 'es-ES', 'es-MX', 'sv-SE'];
    expect(epubSpeechEngineLocale('es-mx', available), 'es-MX');
    expect(epubSpeechEngineLocale('sv', available), 'sv-SE');
    expect(epubSpeechEngineLocale('es-AR', available), 'es-ES');
    expect(epubSpeechEngineLocale('fr', available), 'fr');
  });

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
