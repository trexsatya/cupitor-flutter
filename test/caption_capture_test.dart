import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/caption_capture.dart';

/// Input comes from JS scraping a third-party player, so the shaping has to
/// survive whatever the page hands over.
void main() {
  Map<String, dynamic>? build(Object? raw, {String lang = 'sv'}) =>
      buildCaptionCaptureDetail(raw, fallbackLang: lang);

  group('shape', () {
    test('carries the flag, metadata and lines', () {
      final d = build({
        'title': 'Längtan till landet',
        'url': 'https://urplay.se/program/1',
        'lang': 'sv',
        'lines': [
          {'start': 12.0, 'end': 14.5, 'text': 'Han gick hem.'},
        ],
      })!;

      expect(d['source'], 'caption',
          reason: 'this is what tells the webapp it is not a book item');
      expect(d['title'], 'Längtan till landet');
      expect(d['url'], 'https://urplay.se/program/1');
      expect(d['lang'], 'sv');
      expect(d['lines'], [
        {'start': 12.0, 'end': 14.5, 'text': 'Han gick hem.'},
      ]);
    });

    test('orders by media time whatever order they arrived in', () {
      final d = build({
        'lines': [
          {'start': 30.0, 'end': 32.0, 'text': 'third'},
          {'start': 10.0, 'end': 12.0, 'text': 'first'},
          {'start': 20.0, 'end': 22.0, 'text': 'second'},
        ],
      })!;
      final texts =
          (d['lines'] as List).map((l) => (l as Map)['text']).toList();
      expect(texts, ['first', 'second', 'third']);
    });
  });

  group('translations', () {
    test('are carried through when present', () {
      final d = build({
        'lines': [
          {'start': 1.0, 'end': 2.0, 'text': 'Hej', 'translation': 'Hello'},
        ],
      })!;
      expect((d['lines'] as List).first, containsPair('translation', 'Hello'));
    });

    test('are omitted per line when absent — the ragged case', () {
      // Translation is opt-in and backfills asynchronously, so a selection
      // routinely contains a mix.
      final d = build({
        'lines': [
          {'start': 1.0, 'end': 2.0, 'text': 'Hej', 'translation': 'Hello'},
          {'start': 3.0, 'end': 4.0, 'text': 'Då'},
          {'start': 5.0, 'end': 6.0, 'text': 'Nu', 'translation': '   '},
        ],
      })!;
      final lines = (d['lines'] as List).cast<Map>();
      expect(lines[0]['translation'], 'Hello');
      expect(lines[1].containsKey('translation'), isFalse);
      expect(lines[2].containsKey('translation'), isFalse,
          reason: 'whitespace is not a translation');
    });
  });

  group('language', () {
    test('prefers what the page reports', () {
      final d = build({
        'lang': 'es',
        'lines': [
          {'start': 0, 'end': 1, 'text': 'Hola'}
        ],
      }, lang: 'sv')!;
      expect(d['lang'], 'es');
    });

    test('falls back to the app setting when the page is silent', () {
      final d = build({
        'lines': [
          {'start': 0, 'end': 1, 'text': 'Hej'}
        ],
      }, lang: 'sv')!;
      expect(d['lang'], 'sv');
    });
  });

  group('source', () {
    test("page selections are flagged 'page'", () {
      final d = build({
        'source': 'page',
        'title': 'Muntlig interaktion',
        'url': 'https://studora.se/x',
        'lines': [
          {'text': 'Han gick hem.'}
        ],
      })!;
      expect(d['source'], 'page');
      expect(d['title'], 'Muntlig interaktion');
    });

    test('an absent source stays a caption, so older page scripts keep working',
        () {
      final d = build({
        'lines': [
          {'start': 1, 'end': 2, 'text': 'x'}
        ]
      })!;
      expect(d['source'], 'caption');
    });

    test('an unrecognised source is treated as a caption', () {
      final d = build({
        'source': 'sideways',
        'lines': [
          {'start': 1, 'end': 2, 'text': 'x'}
        ]
      })!;
      expect(d['source'], 'caption');
    });

    test('page lines carry no time and land at zero', () {
      final d = build({
        'source': 'page',
        'lines': [
          {'text': 'Bara en mening.'}
        ],
      })!;
      final line = (d['lines'] as List).first as Map;
      expect(line['start'], 0.0);
      expect(line['end'], 0.0, reason: 'end is clamped to start, never before it');
    });

    test('untimed selections keep the order they were picked in', () {
      // Every start is 0 here, and Dart's sort is NOT stable — without an
      // arrival-index tiebreak this is exactly where a selection would come
      // back shuffled. Enough items that an unstable sort would show.
      final picked = [for (var i = 0; i < 24; i++) 'sentence $i'];
      final d = build({
        'source': 'page',
        'lines': [for (final t in picked) {'text': t}],
      })!;
      final got =
          (d['lines'] as List).map((l) => (l as Map)['text']).toList();
      expect(got, picked);
    });

    test('timed lines still sort by time, ties keeping arrival order', () {
      final d = build({
        'lines': [
          {'start': 5, 'end': 6, 'text': 'later'},
          {'start': 1, 'end': 2, 'text': 'first-a'},
          {'start': 1, 'end': 2, 'text': 'first-b'},
        ]
      })!;
      final got =
          (d['lines'] as List).map((l) => (l as Map)['text']).toList();
      expect(got, ['first-a', 'first-b', 'later']);
    });
  });

  group('hostile input is dropped, not thrown', () {
    test('null, non-map, and missing lines produce nothing', () {
      expect(build(null), isNull);
      expect(build('nope'), isNull);
      expect(build(<String, dynamic>{}), isNull);
      expect(build({'lines': 'not a list'}), isNull);
    });

    test('an empty or all-blank selection produces nothing', () {
      expect(build({'lines': []}), isNull);
      expect(
        build({
          'lines': [
            {'start': 1, 'end': 2, 'text': '   '},
            {'start': 3, 'end': 4, 'text': ''},
          ]
        }),
        isNull,
        reason: 'the DOM observer can catch an empty cue container',
      );
    });

    test('blank lines are skipped but good ones survive', () {
      final d = build({
        'lines': [
          {'start': 1, 'end': 2, 'text': ''},
          {'start': 3, 'end': 4, 'text': 'kept'},
        ]
      })!;
      expect((d['lines'] as List).length, 1);
      expect((d['lines'] as List).first, containsPair('text', 'kept'));
    });

    test('string and missing times are coerced to numbers', () {
      final d = build({
        'lines': [
          {'start': '7.5', 'end': '9', 'text': 'a'},
          {'text': 'b'},
        ]
      })!;
      final lines = (d['lines'] as List).cast<Map>();
      // 'b' has no time, so it sorts to 0 and comes first.
      expect(lines[0]['text'], 'b');
      expect(lines[0]['start'], 0.0);
      expect(lines[1]['start'], 7.5);
      expect(lines[1]['end'], 9.0);
    });

    test('an end before its start is clamped, never negative duration', () {
      final d = build({
        'lines': [
          {'start': 10, 'end': 4, 'text': 'backwards'}
        ]
      })!;
      final line = (d['lines'] as List).first as Map;
      expect(line['end'], 10.0);
    });

    test('non-map entries in the list are ignored', () {
      final d = build({
        'lines': [
          'garbage',
          42,
          {'start': 1, 'end': 2, 'text': 'good'},
        ]
      })!;
      expect((d['lines'] as List).length, 1);
    });

    test('missing title and url become empty strings, not nulls', () {
      final d = build({
        'lines': [
          {'start': 0, 'end': 1, 'text': 'x'}
        ]
      })!;
      expect(d['title'], '');
      expect(d['url'], '');
    });
  });

  // One sentence sent from the tagging sheet. It has to come out the far side
  // of buildCaptionCaptureDetail intact, because that is the only validation
  // the host does before the webapp sees it.
  group('single sentence from the tagging sheet', () {
    test('survives the shaping it is fed into', () {
      final d = build(sentenceCaptureBlock(
        text: 'Han gick hem.',
        title: 'Langtan till landet',
        url: 'https://urplay.se/program/1',
      ))!;
      expect(d['source'], 'page');
      expect(d['title'], 'Langtan till landet');
      expect(d['url'], 'https://urplay.se/program/1');
      expect(d['lang'], 'sv'); // the app's language, since the block carries none
      final lines = d['lines'] as List;
      expect(lines, hasLength(1));
      expect(lines.first['text'], 'Han gick hem.');
      // No media time: a page block is what an untimed selection looks like.
      expect(lines.first['start'], 0.0);
      expect(lines.first['end'], 0.0);
    });

    test('an EPUB sentence carries a title and no address', () {
      final d = build(sentenceCaptureBlock(
        text: 'Det var en gang.',
        title: 'Rontgenbilden - Kapitel 3',
        url: '',
      ))!;
      expect(d['url'], '');
      expect(d['title'], 'Rontgenbilden - Kapitel 3');
      expect((d['lines'] as List).first['text'], 'Det var en gang.');
    });

    test('surrounding whitespace is trimmed off the metadata', () {
      final d = build(sentenceCaptureBlock(
        text: 'Hej.',
        title: '  spaced out  ',
        url: '  https://example.test/a  ',
      ))!;
      expect(d['title'], 'spaced out');
      expect(d['url'], 'https://example.test/a');
    });

    // The send button must not be able to push an empty card into a playlist.
    test('a blank sentence produces nothing to send', () {
      expect(build(sentenceCaptureBlock(text: '   ', title: 't', url: '')), isNull);
      expect(build(sentenceCaptureBlock(text: '', title: 't', url: '')), isNull);
    });

    test('a multi-line selection stays one line, one card', () {
      final d = build(sentenceCaptureBlock(
        text: 'Forsta raden\nandra raden',
        title: '',
        url: '',
      ))!;
      // The host does not split on newlines; the webapp collapses them when it
      // builds the card face.
      expect((d['lines'] as List), hasLength(1));
      expect((d['lines'] as List).first['text'], 'Forsta raden\nandra raden');
    });
  });
}
