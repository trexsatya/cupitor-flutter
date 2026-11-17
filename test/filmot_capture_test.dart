import 'dart:convert';

import 'package:cupitor/filmot_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes both Filmot domains and rejects lookalike hosts', () {
    expect(isFilmotUrl('https://filmot.org/search/villosp%C3%A5r/1'), isTrue);
    expect(isFilmotUrl('https://beta.filmot.com/video/123'), isTrue);
    expect(isFilmotUrl('https://beta.filmot.org/video/123'), isTrue);
    expect(isFilmotUrl('https://filmot.org.example.com/'), isFalse);
    expect(isFilmotUrl('https://notfilmot.org/'), isFalse);
    expect(isFilmotUrl('ftp://filmot.org/'), isFalse);
  });

  const capture = {
    'query': 'smälek',
    'lines': [
      {'i': 12, 'ts': 4.25, 't': 'att lida smälek'},
    ],
  };

  test('reads decoded payloads and both native JS return formats', () {
    expect(decodeFilmotCapture(capture), capture);
    expect(decodeFilmotCapture(jsonEncode(capture)), capture);
    expect(decodeFilmotCapture(jsonEncode(jsonEncode(capture))), capture);
  });

  test('reads a WebView snapshot chunk with exact Unicode text', () {
    const chunk = {'chunk': 'svenska 💬'};
    expect(decodeFilmotReply(jsonEncode(chunk)), chunk);
    expect(decodeFilmotReply(jsonEncode(jsonEncode(chunk))), chunk);
    expect(decodeFilmotReply(false), isNull);
  });

  test('handles null, malformed, and incomplete replies without casting', () {
    for (final raw in [
      null,
      '',
      'null',
      '"null"',
      'false',
      '{}',
      '{"lines":[null]}',
    ]) {
      expect(decodeFilmotCapture(raw), isNull, reason: '$raw');
    }
    expect(decodeFilmotCapture('{"lines":[]}'), {'lines': []});
  });
}
