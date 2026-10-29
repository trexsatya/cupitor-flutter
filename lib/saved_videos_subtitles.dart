/// Batch subtitle download for the "Saved videos" dialog: for each chosen
/// video, list its caption tracks, pick one, download it and hand a
/// lookup-page payload to [send]. Every step that touches the network or the
/// app is injected, so the sequencing can be tested on its own.
library;

import 'dart:convert';

/// A saved video as the batch sees it.
typedef SavedVideoRef = ({String url, String title});

enum SavedVideoSubtitleStatus { sent, notYouTube, noCaptions, failed }

class SavedVideoSubtitleResult {
  const SavedVideoSubtitleResult(this.video, this.status, [this.reason = '']);

  final SavedVideoRef video;
  final SavedVideoSubtitleStatus status;

  /// Plain-words explanation for anything other than [SavedVideoSubtitleStatus.sent].
  final String reason;
}

class SavedVideosSubtitlesOutcome {
  const SavedVideosSubtitlesOutcome({
    required this.results,
    required this.total,
    this.stoppedReason,
    this.cancelled = false,
  });

  /// One entry per video that was attempted, in order.
  final List<SavedVideoSubtitleResult> results;

  /// How many videos the batch was asked for.
  final int total;

  /// Set when the batch could not start at all (e.g. yt-dlp is missing);
  /// [results] is then empty.
  final String? stoppedReason;

  /// True when [isCancelled] stopped the batch before every video was tried.
  final bool cancelled;

  int get sentCount =>
      results.where((r) => r.status == SavedVideoSubtitleStatus.sent).length;
}

/// Index of the caption track to use by default for [lang]. Languages are
/// compared by their base (`sv-SE` and `sv` are both `sv`). Preference order:
/// manual track in the language → the original-language auto track
/// `<base>-orig` → any manual track → auto track in the language (often a
/// machine translation) → first track. yt-dlp lists auto tracks with kind
/// `asr`; an `-orig` track is never taken for a manual one, whatever its kind.
int defaultCaptionTrackIndex(List<Map<String, dynamic>> tracks, String lang) {
  const base = baseLanguageCode;
  final want = base(lang);
  String code(Map<String, dynamic> t) =>
      (t['languageCode'] as String? ?? '').toLowerCase();
  bool isOrig(Map<String, dynamic> t) => code(t).endsWith('-orig');
  bool isManual(Map<String, dynamic> t) =>
      (t['kind'] as String? ?? '') != 'asr' && !isOrig(t);
  bool inLang(Map<String, dynamic> t) => !isOrig(t) && base(code(t)) == want;
  final rules = <bool Function(Map<String, dynamic>)>[
    (t) => isManual(t) && inLang(t),
    (t) => code(t) == '$want-orig',
    isManual,
    inLang,
  ];
  for (final rule in rules) {
    final i = tracks.indexWhere(rule);
    if (i >= 0) return i;
  }
  return 0;
}

/// Base language of a caption track code: `sv-orig`, `sv-SE` and `SV` are all
/// `sv`. The lookup page files a capture as `<name>.<sourceLang>.srt` and reads
/// `<name>.<page language>.srt`, so only the base code finds the file again.
String baseLanguageCode(String code) =>
    code.trim().toLowerCase().split(RegExp('[-_]')).first;

/// Display order only: keep original indices so choosing a row downloads the
/// same track. Put the study language, original audio and device languages
/// before the long list of machine translations. Preserve source order for
/// ties, with manual captions before original ASR before translated ASR.
List<int> captionTrackDisplayOrder(
  List<Map<String, dynamic>> tracks,
  Iterable<String> languages,
) {
  final preferred = languages.map(baseLanguageCode).where((s) => s.isNotEmpty).toSet().toList();
  String code(int i) => (tracks[i]['languageCode'] as String? ?? '').trim().toLowerCase();
  bool original(int i) => code(i).endsWith('-orig');
  bool manual(int i) => tracks[i]['kind'] != 'asr' && !original(i);
  int languageRank(int i) {
    final rank = preferred.indexOf(baseLanguageCode(code(i)));
    if (rank == 0) return 0;
    if (original(i)) return 1;
    return rank > 0 ? rank + 1 : preferred.length + 2;
  }
  int kindRank(int i) => manual(i) ? 0 : original(i) ? 1 : 2;
  return List.generate(tracks.length, (i) => i)..sort((a, b) {
    final language = languageRank(a).compareTo(languageRank(b));
    if (language != 0) return language;
    final kind = kindRank(a).compareTo(kindRank(b));
    return kind != 0 ? kind : a.compareTo(b);
  });
}

/// The translation half of a `capturedSubtitle` payload. Only lines with a
/// translation are included, keyed by their own index/start/end; with none,
/// `targetLang` is left out so the page writes no target file. A blank cue
/// would otherwise be filed into `<name>.<targetLang>.srt` and conflict with
/// (or add empty cues to) the real translation.
Map<String, dynamic> captureTranslationFields(
  List<Map<String, dynamic>> lines,
  List<String> translations, {
  String targetLang = 'en',
}) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < lines.length && i < translations.length; i++) {
    if (translations[i].trim().isEmpty) continue;
    out.add({
      'index': lines[i]['index'] ?? i,
      'start': lines[i]['start'],
      'end': lines[i]['end'],
      'text': translations[i],
    });
  }
  return {
    if (out.isNotEmpty) 'targetLang': targetLang,
    'translation': out,
  };
}

/// The `capturedSubtitle` payload the lookup page expects for an
/// untranslated capture: source lines only, no target file.
Map<String, dynamic> buildCapturedSubtitlePayload({
  required List<Map<String, dynamic>> lines,
  required String sourceLang,
  required String videoId,
  required String videoTitle,
}) {
  final outLines = <Map<String, dynamic>>[];
  for (var i = 0; i < lines.length; i++) {
    outLines.add({
      'index': i,
      'start': lines[i]['start'],
      'end': lines[i]['end'],
      'text': (lines[i]['text'] ?? '').toString(),
    });
  }
  return <String, dynamic>{
    'query': '',
    'sourceLang': baseLanguageCode(sourceLang),
    'matchIndex': 0,
    'lines': outLines,
    ...captureTranslationFields(outLines, const []),
    'videoUrl': 'https://www.youtube.com/watch?v=$videoId',
    'videoId': videoId,
    'videoTitle': videoTitle,
  };
}

/// Runs the batch one video at a time.
///
/// - [toolMissing] is asked once up front; a non-null answer stops the whole
///   batch with that message instead of failing every video with it.
/// - [listTracks] returns `{title, tracks}` like the single-video flow.
/// - [onProgress] is called before each video with its 1-based position.
/// - [isCancelled] is checked between videos, so the current one finishes.
Future<SavedVideosSubtitlesOutcome> downloadSavedVideoSubtitles({
  required List<SavedVideoRef> videos,
  required String? Function(String url) videoIdOf,
  required Future<String?> Function() toolMissing,
  required Future<Map<String, dynamic>> Function(String videoId) listTracks,
  required int Function(List<Map<String, dynamic>> tracks) pickIndex,
  required Future<List<Map<String, dynamic>>> Function(
          String videoId, Map<String, dynamic> track)
      download,
  required Future<void> Function(Map<String, dynamic> payload) send,
  required String fallbackLang,
  void Function(int position, int total, SavedVideoRef video)? onProgress,
  bool Function()? isCancelled,
}) async {
  final missing = await toolMissing();
  if (missing != null) {
    return SavedVideosSubtitlesOutcome(
        results: const [], total: videos.length, stoppedReason: missing);
  }
  final results = <SavedVideoSubtitleResult>[];
  for (var i = 0; i < videos.length; i++) {
    if (isCancelled?.call() ?? false) {
      return SavedVideosSubtitlesOutcome(
          results: results, total: videos.length, cancelled: true);
    }
    final video = videos[i];
    onProgress?.call(i + 1, videos.length, video);
    final videoId = videoIdOf(video.url);
    if (videoId == null) {
      results.add(SavedVideoSubtitleResult(
          video, SavedVideoSubtitleStatus.notYouTube, 'not a YouTube URL'));
      continue;
    }
    Map<String, dynamic> meta;
    try {
      meta = await listTracks(videoId);
    } catch (e) {
      results.add(SavedVideoSubtitleResult(video, SavedVideoSubtitleStatus.failed,
          'could not load the caption list: $e'));
      continue;
    }
    final tracks = ((meta['tracks'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    if (tracks.isEmpty) {
      results.add(SavedVideoSubtitleResult(
          video, SavedVideoSubtitleStatus.noCaptions, 'no captions'));
      continue;
    }
    final picked = tracks[pickIndex(tracks)];
    List<Map<String, dynamic>> lines;
    try {
      lines = await download(videoId, picked);
    } catch (e) {
      results.add(SavedVideoSubtitleResult(
          video, SavedVideoSubtitleStatus.failed, 'download failed: $e'));
      continue;
    }
    if (lines.isEmpty) {
      results.add(SavedVideoSubtitleResult(
          video, SavedVideoSubtitleStatus.noCaptions, 'the captions were empty'));
      continue;
    }
    final metaTitle = (meta['title'] as String?) ?? '';
    try {
      await send(buildCapturedSubtitlePayload(
        lines: lines,
        sourceLang: (picked['languageCode'] as String?) ?? fallbackLang,
        videoId: videoId,
        videoTitle: metaTitle.isNotEmpty ? metaTitle : video.title,
      ));
    } catch (e) {
      results.add(SavedVideoSubtitleResult(
          video, SavedVideoSubtitleStatus.failed, 'could not send to lookup: $e'));
      continue;
    }
    results.add(SavedVideoSubtitleResult(video, SavedVideoSubtitleStatus.sent));
  }
  return SavedVideosSubtitlesOutcome(results: results, total: videos.length);
}

/// Plain-words summary for the end-of-batch dialog.
String describeSavedVideosSubtitlesOutcome(SavedVideosSubtitlesOutcome o) {
  if (o.stoppedReason != null) return o.stoppedReason!;
  final b = StringBuffer('Sent ${o.sentCount} of ${o.total} to lookup.');
  if (o.cancelled) {
    b.write(' Stopped early; ${o.total - o.results.length} not tried.');
  }
  final failed =
      o.results.where((r) => r.status != SavedVideoSubtitleStatus.sent).toList();
  if (failed.isNotEmpty) {
    b.write('\n\nNot sent:');
    for (final r in failed) {
      final name = r.video.title.isNotEmpty ? r.video.title : r.video.url;
      b.write('\n• $name — ${r.reason}');
    }
  }
  return b.toString();
}

/// Most videos one batch may take.
const int kSavedVideosBatchCap = 10;

/// What the lookup page already has, from `window.cupitorKnownVideos`.
class KnownVideos {
  const KnownVideos({required this.library, required this.pending});

  /// In the library the page has loaded.
  final Set<String> library;

  /// Waiting in Review Captured. Takes precedence over [library].
  final Set<String> pending;

  /// Plain-words label for a row, or null when the page doesn't have it.
  String? labelFor(String? videoId) {
    if (videoId == null) return null;
    if (pending.contains(videoId)) return 'Waiting in Review Captured';
    if (library.contains(videoId)) return 'Already in library';
    return null;
  }

  bool has(String? videoId) => labelFor(videoId) != null;
}

/// The page's answer as `runJavaScriptReturningResult` hands it back (a JSON
/// string, JSON-encoded once more on Android). Returns `(ready, known)`; null
/// when it isn't a well-formed answer (e.g. an older page without the hook).
({bool ready, KnownVideos known})? parseKnownVideosAnswer(Object? raw) {
  Object? v = raw;
  for (var i = 0; i < 2 && v is String; i++) {
    try {
      v = jsonDecode(v);
    } catch (_) {
      return null;
    }
  }
  if (v is! Map || v['ready'] is! bool) return null;
  Set<String> ids(Object? list) =>
      list is List ? list.whereType<String>().toSet() : <String>{};
  return (
    ready: v['ready'] as bool,
    known: KnownVideos(library: ids(v['library']), pending: ids(v['pending'])),
  );
}

/// Asks the page until it answers `ready`, a malformed answer comes back, or
/// [timeout] passes (a missing hook is asked again until then). [ask] returns null (or throws) while the page isn't
/// there yet.
/// Null result means "couldn't check".
Future<KnownVideos?> pollKnownVideos({
  required Future<Object?> Function() ask,
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 500),
  DateTime Function() now = DateTime.now,
  Future<void> Function(Duration) sleep = Future<void>.delayed,
}) async {
  final deadline = now().add(timeout);
  while (true) {
    Object? raw;
    var asked = false;
    try {
      raw = await ask();
      asked = raw != null;
    } catch (_) {
      // A page mid-navigation can refuse the call; try again until the deadline.
    }
    if (asked && !_isBlankAnswer(raw)) {
      final answer = parseKnownVideosAnswer(raw);
      if (answer == null) return null;
      if (answer.ready) return answer.known;
    }
    if (!now().isBefore(deadline)) return null;
    await sleep(interval);
  }
}

/// The page's "no hook" answer (`""`, JSON-encoded once more on Android). A
/// page whose scripts are still starting looks the same as an old page, so
/// it is asked again until the deadline.
bool _isBlankAnswer(Object? raw) {
  Object? v = raw;
  for (var i = 0; i < 2 && v is String; i++) {
    if (v.trim().isEmpty) return true;
    try {
      v = jsonDecode(v);
    } catch (_) {
      return false;
    }
  }
  return v is String && v.trim().isEmpty;
}

/// URLs "select all" ticks: the first [cap] rows that can be ticked
/// ([selectable]) and that the page doesn't already have.
Set<String> selectAllUrls(
  List<String> urls, {
  required bool Function(String url) selectable,
  required bool Function(String url) alreadyKnown,
  int cap = kSavedVideosBatchCap,
}) {
  final out = <String>{};
  for (final u in urls) {
    if (out.length >= cap) break;
    if (selectable(u) && !alreadyKnown(u)) out.add(u);
  }
  return out;
}
