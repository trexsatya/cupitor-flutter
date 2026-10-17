import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/youtube_sidebar_subtitles.dart';

void main() {
  const id = 'abcdefghijk';
  test('accepts supported YouTube URL forms and rejects lookalike hosts', () {
    for (final url in [
      id,
      'https://www.youtube.com/watch?v=$id&t=42',
      'https://m.youtube.com/watch?v=$id',
      'https://youtu.be/$id?si=share',
      'https://www.youtube.com/shorts/$id',
      'https://www.youtube.com/live/$id',
      'https://www.youtube-nocookie.com/embed/$id',
    ]) {
      expect(youtubeSubtitleVideoId(url), id, reason: url);
    }
    for (final url in [
      'https://notyoutube.com/watch?v=$id',
      'https://youtube.com.evil.test/watch?v=$id',
      'https://example.com/embed/$id',
      'file:///watch?v=$id',
      'short',
    ]) {
      expect(youtubeSubtitleVideoId(url), isNull, reason: url);
    }
  });

  test('normalizes, sorts and deduplicates downloaded cues', () {
    final payload = youtubeSidebarSubtitlePayload(
      videoId: id,
      language: ' sv ',
      lines: [
        {'start': 5, 'end': 7, 'text': ' Andra '},
        {'start': '1.5', 'end': 3, 'text': 'Första'},
        {'start': 5, 'end': 7, 'text': 'Andra'},
        {'start': -1, 'end': 1, 'text': 'bad'},
        {'start': double.nan, 'end': 1, 'text': 'bad'},
        {'start': 10, 'end': 11, 'text': '  '},
      ],
    );
    expect(payload['lang'], 'sv');
    expect(payload['lines'], [
      {'start': 1.5, 'end': 3.0, 'text': 'Första'},
      {'start': 5.0, 'end': 7.0, 'text': 'Andra'},
    ]);
  });

  test('repairs timing-only durations without losing valid text', () {
    final payload = youtubeSidebarSubtitlePayload(
      videoId: id,
      language: 'en',
      lines: [
        {'start': 0, 'end': 0, 'text': 'First'},
        {'start': 4, 'end': double.infinity, 'text': 'Last'},
      ],
    );
    expect(payload['lines'], [
      {'start': 0.0, 'end': 4.0, 'text': 'First'},
      {'start': 4.0, 'end': 7.0, 'text': 'Last'},
    ]);
  });

  test(
    'invalid ids are rejected and arbitrary cue text is encoded as data',
    () {
      expect(
        () => youtubeSidebarSubtitlePayload(
          videoId: 'bad',
          language: 'sv',
          lines: [],
        ),
        throwsArgumentError,
      );
      final payload = youtubeSidebarSubtitlePayload(
        videoId: id,
        language: 'sv',
        lines: [
          {
            'start': 0,
            'end': 2,
            'text': '"; window.injected=true; // <script> hej',
          },
        ],
      );
      final js = youtubeSidebarSubtitleImportJs(payload);
      expect(js, contains(jsonEncode(payload)));
      expect(js, startsWith('Boolean(window.__cupImportYouTubeSubtitles &&'));
    },
  );
}
