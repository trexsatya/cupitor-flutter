import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/caption_capture.dart';
import 'package:cupitor/video_note.dart';

void main() {
  final moment = {
    'found': true,
    'time': 128.7,
    'wasPlaying': true,
    'title': 'Rapport',
    'url': 'https://www.svtplay.se/video/abc',
    'timeParam': 'position',
    'timeLink': true,
  };

  group('parseVideoMoment', () {
    test('reads the JSON string WKWebView hands back', () {
      final m = parseVideoMoment(jsonEncode(moment))!;
      expect(m.seconds, 128.7);
      expect(m.wasPlaying, isTrue);
      expect(m.url, 'https://www.svtplay.se/video/abc');
      expect(m.timeParam, 'position');
      expect(m.timeLink, isTrue);
    });

    test('reads the double-encoded string Android hands back', () {
      expect(parseVideoMoment(jsonEncode(jsonEncode(moment)))!.seconds, 128.7);
    });

    test('no video, garbage or a non-finite time is null', () {
      expect(parseVideoMoment(jsonEncode({'found': false})), isNull);
      expect(parseVideoMoment('not json'), isNull);
      expect(parseVideoMoment(null), isNull);
      expect(parseVideoMoment(jsonEncode({...moment, 'time': null})), isNull);
    });

    test('a live channel keeps its "no link" answer', () {
      final m = parseVideoMoment(jsonEncode({...moment, 'timeLink': false}))!;
      expect(m.timeLink, isFalse);
    });
  });

  group('videoNoteBlock', () {
    test('becomes one timed caption line on the shared capture path', () {
      final m = parseVideoMoment(jsonEncode(moment))!;
      final d = buildCaptionCaptureDetail(
        videoNoteBlock(m, '  Han sa något viktigt.  '),
        fallbackLang: 'sv',
      )!;
      expect(d['source'], 'caption',
          reason: 'caption is what makes the webapp put a time on the link');
      expect(d['url'], 'https://www.svtplay.se/video/abc');
      expect(d['timeParam'], 'position');
      expect(d['timeLink'], isTrue);
      expect(d['title'], 'Rapport');
      expect(d['lines'], [
        {'start': 128.7, 'end': 128.7, 'text': 'Han sa något viktigt.'},
      ]);
    });

    test('blank text sends nothing', () {
      final m = parseVideoMoment(jsonEncode(moment))!;
      expect(
          buildCaptionCaptureDetail(videoNoteBlock(m, '   '), fallbackLang: 'sv'),
          isNull);
    });
  });

  test("an edited time replaces the player's moment", () {
    final m = parseVideoMoment(jsonEncode(moment))!;
    final d = buildCaptionCaptureDetail(
      videoNoteBlock(m, 'Hej', seconds: 95),
      fallbackLang: 'sv',
    )!;
    expect((d['lines'] as List).single['start'], 95.0);
  });

  test('parseVideoClock', () {
    expect(parseVideoClock('2:08'), 128);
    expect(parseVideoClock(' 1:02:05 '), 3725);
    expect(parseVideoClock('90'), 90);
    expect(parseVideoClock('0:00'), 0);
    for (final bad in ['', 'abc', '1:60', '1:2:3:4', '-5', '1:-2']) {
      expect(parseVideoClock(bad), isNull, reason: bad);
    }
  });

  test('formatVideoClock', () {
    expect(formatVideoClock(5.9), '0:05');
    expect(formatVideoClock(128.7), '2:08');
    expect(formatVideoClock(3725), '1:02:05');
  });
}
