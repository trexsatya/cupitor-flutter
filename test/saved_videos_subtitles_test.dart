import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/saved_videos_subtitles.dart';

Map<String, dynamic> track(String code, {bool auto = false}) =>
    {'languageCode': code, 'kind': auto ? 'asr' : ''};

void main() {
  group('captionTrackDisplayOrder', () {
    test('study, original and device languages precede unrelated translated tracks', () {
      final tracks = [track('ab', auto: true), track('aa', auto: true),
        track('sv', auto: true), track('sv-orig', auto: true), track('sv-SE'),
        track('en', auto: true), track('de', auto: true)];
      final order = captionTrackDisplayOrder(tracks, ['sv', 'en']);
      expect(order, [4, 3, 2, 5, 0, 1, 6]);
      expect(tracks[order[0]]['languageCode'], 'sv-SE');
      expect(tracks.first['languageCode'], 'ab', reason: 'source indices remain unchanged');
    });
    test('original audio is near the top when study language is translated', () {
      final tracks = [track('ab', auto: true), track('en-orig', auto: true),
        track('sv', auto: true), track('es'), track('en')];
      expect(captionTrackDisplayOrder(tracks, ['SV_se', 'en', 'en']), [2, 1, 4, 3, 0]);
      expect(captionTrackDisplayOrder([], ['sv']), isEmpty);
    });
  });
  group('defaultCaptionTrackIndex', () {
    test('sv-orig beats the plain sv auto track and a manual English track', () {
      final tracks = [track('en'), track('sv', auto: true), track('sv-orig', auto: true)];
      expect(defaultCaptionTrackIndex(tracks, 'sv'), 2);
    });
    test('a manual sv track still beats sv-orig', () {
      final tracks = [track('sv-orig', auto: true), track('sv')];
      expect(defaultCaptionTrackIndex(tracks, 'sv'), 1);
    });
    test('a manual region variant counts as the language', () {
      final tracks = [track('sv-orig', auto: true), track('en'), track('sv-SE')];
      expect(defaultCaptionTrackIndex(tracks, 'SV'), 2);
    });
    test('no tracks in the language falls back to any manual track', () {
      final tracks = [track('de', auto: true), track('fr')];
      expect(defaultCaptionTrackIndex(tracks, 'sv'), 1);
    });
    test('plain sv auto track is used when nothing better exists', () {
      final tracks = [track('de', auto: true), track('sv', auto: true)];
      expect(defaultCaptionTrackIndex(tracks, 'sv'), 1);
    });
    test('only translations of other languages gives the first track', () {
      final tracks = [track('de', auto: true), track('fr', auto: true)];
      expect(defaultCaptionTrackIndex(tracks, 'sv'), 0);
    });
    test('a region setting matches the base language and its -orig track', () {
      expect(defaultCaptionTrackIndex([track('en'), track('sv')], 'sv-SE'), 1);
      expect(defaultCaptionTrackIndex(
          [track('en'), track('sv', auto: true), track('sv-orig', auto: true)],
          'sv-SE'), 2);
    });
    test('an -orig track is never treated as a manual track', () {
      // kind '' would otherwise make it a manual sv-* region variant.
      final tracks = [track('sv-orig'), track('sv')];
      expect(defaultCaptionTrackIndex(tracks, 'sv'), 1);
      expect(defaultCaptionTrackIndex([track('en', auto: true), track('sv-orig')], 'sv'), 1);
      expect(defaultCaptionTrackIndex([track('de-orig'), track('en')], 'sv'), 1);
    });
    test('empty list does not throw', () {
      expect(defaultCaptionTrackIndex(const [], 'sv'), 0);
    });
  });

  group('downloadSavedVideoSubtitles', () {
    const yt1 = (url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa', title: 'One');
    const yt2 = (url: 'https://www.youtube.com/watch?v=bbbbbbbbbbb', title: 'Two');
    const yt3 = (url: 'https://www.youtube.com/watch?v=ccccccccccc', title: 'Three');
    const other = (url: 'https://example.com/video', title: 'Elsewhere');

    String? idOf(String url) {
      final m = RegExp(r'v=([A-Za-z0-9_-]{11})').firstMatch(url);
      return m?.group(1);
    }

    final cue = [
      {'start': 1.0, 'end': 2.0, 'text': 'hej'},
      {'start': 2.0, 'end': 3.0, 'text': 'då'},
    ];

    Future<SavedVideosSubtitlesOutcome> run(
      List<SavedVideoRef> videos, {
      Future<String?> Function()? toolMissing,
      Map<String, List<Map<String, dynamic>>> tracksById = const {},
      Set<String> failDownload = const {},
      List<Map<String, dynamic>>? sent,
      bool Function()? isCancelled,
      List<String>? progress,
    }) {
      return downloadSavedVideoSubtitles(
        videos: videos,
        videoIdOf: idOf,
        toolMissing: toolMissing ?? () async => null,
        listTracks: (id) async => {
          'title': 'YT $id',
          'tracks': tracksById[id] ?? [track('sv')],
        },
        pickIndex: (t) => defaultCaptionTrackIndex(t, 'sv'),
        download: (id, t) async {
          if (failDownload.contains(id)) throw 'HTTP 429';
          return cue;
        },
        send: (p) async => sent?.add(p),
        fallbackLang: 'sv',
        onProgress: (pos, total, v) => progress?.add('$pos/$total ${v.title}'),
        isCancelled: isCancelled,
      );
    }

    test('sends each video in order with the lookup payload shape', () async {
      final sent = <Map<String, dynamic>>[];
      final progress = <String>[];
      final o = await run([yt1, yt2], sent: sent, progress: progress);
      expect(o.sentCount, 2);
      expect(progress, ['1/2 One', '2/2 Two']);
      expect(sent.map((p) => p['videoId']), ['aaaaaaaaaaa', 'bbbbbbbbbbb']);
      final p = sent.first;
      expect(p['videoTitle'], 'YT aaaaaaaaaaa');
      expect(p['videoUrl'], 'https://www.youtube.com/watch?v=aaaaaaaaaaa');
      expect(p['sourceLang'], 'sv');
      // Untranslated: no target file for the page to write.
      expect(p.containsKey('targetLang'), isFalse);
      expect(p['translation'], isEmpty);
      expect(p['matchIndex'], 0);
      expect(p['query'], '');
      expect((p['lines'] as List).map((l) => l['text']), ['hej', 'då']);
      expect((p['lines'] as List).last['start'], 2.0);
    });

    test('an sv-orig or region track is filed under the base language', () async {
      final sent = <Map<String, dynamic>>[];
      await run([yt1, yt2], sent: sent, tracksById: {
        'aaaaaaaaaaa': [track('sv-orig', auto: true)],
        'bbbbbbbbbbb': [track('sv-SE')],
      });
      expect(sent.map((p) => p['sourceLang']), ['sv', 'sv']);
    });

    test('a video with no tracks is reported and the rest continue', () async {
      final sent = <Map<String, dynamic>>[];
      final o = await run([yt1, yt2], tracksById: {'aaaaaaaaaaa': []}, sent: sent);
      expect(o.results.first.status, SavedVideoSubtitleStatus.noCaptions);
      expect(o.results.first.reason, 'no captions');
      expect(o.sentCount, 1);
      expect(sent.single['videoId'], 'bbbbbbbbbbb');
    });

    test('a download error is reported with its message', () async {
      final o = await run([yt1, yt2], failDownload: {'aaaaaaaaaaa'});
      expect(o.results.first.status, SavedVideoSubtitleStatus.failed);
      expect(o.results.first.reason, 'download failed: HTTP 429');
      expect(o.results.last.status, SavedVideoSubtitleStatus.sent);
    });

    test('a non-YouTube URL is skipped without touching yt-dlp', () async {
      final o = await run([other, yt1]);
      expect(o.results.first.status, SavedVideoSubtitleStatus.notYouTube);
      expect(o.results.first.reason, 'not a YouTube URL');
      expect(o.sentCount, 1);
    });

    test('cancel stops after the current video', () async {
      var cancel = false;
      final sent = <Map<String, dynamic>>[];
      final o = await downloadSavedVideoSubtitles(
        videos: [yt1, yt2, yt3],
        videoIdOf: idOf,
        toolMissing: () async => null,
        listTracks: (id) async => {'title': '', 'tracks': [track('sv')]},
        pickIndex: (t) => 0,
        download: (id, t) async {
          cancel = true; // user taps Cancel while the first one downloads
          return cue;
        },
        send: (p) async => sent.add(p),
        fallbackLang: 'sv',
        isCancelled: () => cancel,
      );
      expect(o.cancelled, isTrue);
      expect(o.results, hasLength(1));
      expect(sent.single['videoTitle'], 'One'); // falls back to the saved title
      expect(describeSavedVideosSubtitlesOutcome(o), contains('Sent 1 of 3 to lookup. Stopped early; 2 not tried.'));
    });

    test('yt-dlp missing stops the batch once, before any video', () async {
      var listed = 0;
      final o = await downloadSavedVideoSubtitles(
        videos: [yt1, yt2],
        videoIdOf: idOf,
        toolMissing: () async => 'Install yt-dlp',
        listTracks: (id) async {
          listed++;
          return {'title': '', 'tracks': []};
        },
        pickIndex: (t) => 0,
        download: (id, t) async => cue,
        send: (p) async {},
        fallbackLang: 'sv',
      );
      expect(listed, 0);
      expect(o.results, isEmpty);
      expect(o.stoppedReason, 'Install yt-dlp');
      expect(describeSavedVideosSubtitlesOutcome(o), 'Install yt-dlp');
    });

    test('summary names each video that was not sent and why', () async {
      final o = await run([other, yt1, yt2], failDownload: {'bbbbbbbbbbb'});
      final text = describeSavedVideosSubtitlesOutcome(o);
      expect(text, startsWith('Sent 1 of 3 to lookup.'));
      expect(text, contains('Elsewhere — not a YouTube URL'));
      expect(text, contains('Two — download failed: HTTP 429'));
    });
  });

  group('baseLanguageCode', () {
    test('strips -orig, regions and case', () {
      expect(baseLanguageCode('sv-orig'), 'sv');
      expect(baseLanguageCode('sv-SE'), 'sv');
      expect(baseLanguageCode('pt_BR'), 'pt');
      expect(baseLanguageCode(' SV '), 'sv');
      expect(baseLanguageCode('es'), 'es');
    });
  });

  group('captureTranslationFields', () {
    final lines = [
      {'index': 5, 'start': 1.0, 'end': 2.0},
      {'index': 6, 'start': 2.0, 'end': 3.0},
      {'index': 7, 'start': 3.0, 'end': 4.0},
    ];
    test('nothing translated: empty list and no targetLang', () {
      expect(captureTranslationFields(lines, ['', ' ', '']),
          {'translation': <Map<String, dynamic>>[]});
      expect(captureTranslationFields(lines, const []),
          {'translation': <Map<String, dynamic>>[]});
    });
    test('keeps only translated lines, with their own index and times', () {
      final f = captureTranslationFields(lines, ['hello', '', 'bye']);
      expect(f['targetLang'], 'en');
      expect(f['translation'], [
        {'index': 5, 'start': 1.0, 'end': 2.0, 'text': 'hello'},
        {'index': 7, 'start': 3.0, 'end': 4.0, 'text': 'bye'},
      ]);
    });
    test('a line without an index uses its position', () {
      final f = captureTranslationFields([{'start': 0, 'end': 1}], ['x']);
      expect((f['translation'] as List).single['index'], 0);
    });
  });

  group('parseKnownVideosAnswer', () {
    const json = '{"ready":true,"library":["a"],"pending":["b"]}';
    test('macOS: the JSON string itself', () {
      final a = parseKnownVideosAnswer(json)!;
      expect(a.ready, isTrue);
      expect(a.known.library, {'a'});
      expect(a.known.pending, {'b'});
    });
    test('Android: JSON-encoded once more', () {
      final a = parseKnownVideosAnswer(jsonEncode(json))!;
      expect(a.known.library, {'a'});
    });
    test('not ready', () {
      expect(parseKnownVideosAnswer('{"ready":false,"library":[],"pending":[]}')!.ready,
          isFalse);
    });
    test('old page or garbage is null', () {
      expect(parseKnownVideosAnswer(''), isNull);
      expect(parseKnownVideosAnswer('""'), isNull);
      expect(parseKnownVideosAnswer(null), isNull);
      expect(parseKnownVideosAnswer('{"library":[]}'), isNull);
      expect(parseKnownVideosAnswer('not json'), isNull);
    });
  });

  group('KnownVideos.labelFor', () {
    const k = KnownVideos(library: {'a', 'b'}, pending: {'b'});
    test('pending wins over library', () {
      expect(k.labelFor('a'), 'Already in library');
      expect(k.labelFor('b'), 'Waiting in Review Captured');
      expect(k.labelFor('c'), isNull);
      expect(k.labelFor(null), isNull);
    });
  });

  group('pollKnownVideos', () {
    late DateTime clock;
    setUp(() => clock = DateTime(2026));
    Future<KnownVideos?> poll(List<Object? Function()> answers) {
      var i = 0;
      return pollKnownVideos(
        ask: () async => answers[i < answers.length ? i++ : answers.length - 1](),
        timeout: const Duration(seconds: 15),
        interval: const Duration(milliseconds: 500),
        now: () => clock,
        sleep: (d) async => clock = clock.add(d),
      );
    }

    const notReady = '{"ready":false,"library":[],"pending":[]}';
    const ready = '{"ready":true,"library":["a"],"pending":[]}';

    test('waits for the page and for ready', () async {
      final k = await poll([() => null, () => throw 'navigating', () => notReady, () => ready]);
      expect(k!.library, {'a'});
    });
    test('gives up after the timeout', () async {
      expect(await poll([() => notReady]), isNull);
      expect(clock.difference(DateTime(2026)).inSeconds, 15);
    });
    test('page that never loads gives up too', () async {
      expect(await poll([() => null]), isNull);
    });
    test('a hook that appears later is still asked; one that never does times out', () async {
      expect((await poll([() => '', () => jsonEncode(''), () => ready]))!.library, {'a'});
      clock = DateTime(2026);
      expect(await poll([() => '']), isNull);
      expect(clock.difference(DateTime(2026)).inSeconds, 15);
    });
    test('a malformed answer fails at once', () async {
      expect(await poll([() => '{"library":[]}']), isNull);
      expect(clock, DateTime(2026));
    });
  });

  group('selectAllUrls', () {
    final urls = [for (var i = 0; i < 14; i++) 'u$i'];
    test('first 10 eligible ones that the page does not have', () {
      final s = selectAllUrls(urls,
          selectable: (u) => u != 'u0',
          alreadyKnown: (u) => u == 'u1' || u == 'u2');
      expect(s, {for (var i = 3; i < 13; i++) 'u$i'});
    });
    test('fewer than the cap', () {
      expect(selectAllUrls(['a', 'b'], selectable: (_) => true, alreadyKnown: (_) => false),
          {'a', 'b'});
      expect(kSavedVideosBatchCap, 10);
    });
  });
}
