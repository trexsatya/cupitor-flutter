import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';

/// Both main-page capture buttons open/import into this controller. A failed
/// page-side launcher must not fall through to the standalone lookup dialog.
Future<void> openMainYouTubeSubtitleCapture({
  required WebViewController page,
  required bool Function() isCurrent,
  required Future<void> Function(WebViewController page, String url)
  downloadToPage,
}) async {
  final url = await page.currentUrl() ?? '';
  final videoId = youtubeSubtitleVideoId(url);
  if (!isCurrent() || videoId == null) return;
  var opened = false;
  try {
    final result = await page
        .runJavaScriptReturningResult(
          'Boolean(window.__cupOpenSubtitlePanel && window.__cupOpenSubtitlePanel())',
        )
        .timeout(const Duration(seconds: 2));
    opened = result.toString() == 'true';
  } catch (_) {
    /* Missing or outdated panel: download into the same page. */
  }
  if (opened || !isCurrent()) return;
  final currentId = youtubeSubtitleVideoId(await page.currentUrl() ?? '');
  if (!isCurrent() || currentId != videoId) return;
  await downloadToPage(page, url);
}

/// Accepts a video id or a YouTube watch/share/embed/shorts/live URL.
String? youtubeSubtitleVideoId(String input) {
  final value = input.trim();
  final idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
  if (idPattern.hasMatch(value)) return value;
  final uri = Uri.tryParse(value);
  if (uri == null || !const ['https', 'http'].contains(uri.scheme)) return null;
  final host = uri.host.toLowerCase();
  if (host == 'youtu.be') {
    return uri.pathSegments.isNotEmpty &&
            idPattern.hasMatch(uri.pathSegments.first)
        ? uri.pathSegments.first
        : null;
  }
  if (host != 'youtube.com' &&
      !host.endsWith('.youtube.com') &&
      host != 'youtube-nocookie.com' &&
      !host.endsWith('.youtube-nocookie.com'))
    return null;
  final queryId = uri.queryParameters['v'];
  if (queryId != null && idPattern.hasMatch(queryId)) return queryId;
  if (uri.pathSegments.length >= 2 &&
      const ['shorts', 'embed', 'live', 'v'].contains(uri.pathSegments.first) &&
      idPattern.hasMatch(uri.pathSegments[1]))
    return uri.pathSegments[1];
  return null;
}

/// A complete, sorted track for the existing page sidebar. Zero-duration
/// timing events end at the next cue (or three seconds later at EOF).
Map<String, dynamic> youtubeSidebarSubtitlePayload({
  required String videoId,
  required String language,
  required List<Map<String, dynamic>> lines,
}) {
  if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
    throw ArgumentError.value(videoId, 'videoId');
  }
  double? number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  final cues = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final line in lines) {
    final start = number(line['start']);
    final end = number(line['end']);
    final text = line['text'] is String ? (line['text'] as String).trim() : '';
    if (start == null || !start.isFinite || start < 0 || text.isEmpty) continue;
    final safeEnd = end != null && end.isFinite && end > start ? end : start;
    if (!seen.add(jsonEncode([start, safeEnd, text]))) continue;
    cues.add({'start': start, 'end': safeEnd, 'text': text});
  }
  cues.sort((a, b) {
    final start = (a['start'] as double).compareTo(b['start'] as double);
    return start != 0
        ? start
        : (a['end'] as double).compareTo(b['end'] as double);
  });
  for (var i = 0; i < cues.length; i++) {
    final start = cues[i]['start'] as double;
    if ((cues[i]['end'] as double) > start) continue;
    final next = i + 1 < cues.length ? cues[i + 1]['start'] as double : start;
    cues[i]['end'] = next > start ? next : start + 3;
  }
  return {'videoId': videoId, 'lang': language.trim(), 'lines': cues};
}

String youtubeSidebarSubtitleImportJs(Map<String, dynamic> payload) =>
    'Boolean(window.__cupImportYouTubeSubtitles && '
    'window.__cupImportYouTubeSubtitles(${jsonEncode(payload)}))';
