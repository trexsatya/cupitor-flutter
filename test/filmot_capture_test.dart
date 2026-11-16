import 'dart:convert';

import 'package:cupitor/filmot_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = {
    'query': 'smälek',
    'lines': [
      {'i': 12, 'ts': 4.25, 't': 'att lida smälek'},
    ],
  };

  test('reads the dialog bridge payload and both native JS return formats', () {
    expect(decodeFilmotCapture(capture), capture);
    expect(decodeFilmotCapture(jsonEncode(capture)), capture);
    expect(decodeFilmotCapture(jsonEncode(jsonEncode(capture))), capture);
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
