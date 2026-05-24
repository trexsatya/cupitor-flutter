// Platform-dispatching wrapper around yt-dlp for fetching YouTube caption
// tracks. Two execution paths:
//
//   * **Android**: youtubedl-android (yausername) bundles a Python interpreter
//     + yt-dlp + ffmpeg as native libs. Exposed to Flutter via the
//     `cupitor/ytdlp` MethodChannel implemented in `MainActivity.kt`.
//
//   * **macOS**: `Process.run('yt-dlp', …)` if the binary is installed
//     (Homebrew → `/opt/homebrew/bin/yt-dlp`). Falls back through standard
//     install paths; throws a readable error if not found.
//
// Both paths return data in the same shape so callers don't care which one
// fired. yt-dlp handles the PO-token wall on YouTube's side, so this is the
// only reliable in-app captions path we have.
//
// **macOS gotcha**: the default Flutter macOS app-sandbox forbids spawning
// child processes. To use the subprocess path you must either disable the
// sandbox in `macos/Runner/{DebugProfile,Release}.entitlements` or add
// `com.apple.security.temporary-exception.process-spawning`. The service
// surfaces a clear error if the spawn is denied.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Single caption track exposed by yt-dlp.
class YtDlpTrack {
  final String languageCode;
  final String name;
  /// `'asr'` for auto-generated, empty for manual.
  final String kind;
  const YtDlpTrack({
    required this.languageCode,
    required this.name,
    required this.kind,
  });

  factory YtDlpTrack.fromJson(Map<String, dynamic> m) => YtDlpTrack(
        languageCode: (m['languageCode'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? '',
      );

  Map<String, dynamic> toMap() => {
        'languageCode': languageCode,
        'name': name,
        'kind': kind,
      };
}

/// List-tracks result: video title + the available caption tracks.
class YtDlpListResult {
  final String title;
  final List<YtDlpTrack> tracks;
  const YtDlpListResult({required this.title, required this.tracks});
}

/// Downloaded subtitle body + the format yt-dlp picked
/// (`'json3'`, `'vtt'`, or `'unknown'`). Callers dispatch parsing on `format`.
class YtDlpSubtitle {
  final String body;
  final String format;
  const YtDlpSubtitle({required this.body, required this.format});
}

class YtDlpService {
  static const _channel = MethodChannel('cupitor/ytdlp');

  static bool _initialized = false;
  static String? _macYtDlpPath;

  /// Whether yt-dlp is callable on the current platform.
  /// - Android: always true (bundled).
  /// - macOS: true if `yt-dlp` is on PATH or in a known Homebrew location.
  static Future<bool> isAvailable() async {
    if (Platform.isAndroid) return true;
    if (Platform.isMacOS) {
      _macYtDlpPath ??= await _findMacOsYtDlp();
      return _macYtDlpPath != null;
    }
    return false;
  }

  /// Human-readable install hint for when `isAvailable()` returns false.
  static String installHint() {
    if (Platform.isMacOS) {
      return 'yt-dlp not found. Install via Homebrew:\n\n'
          '    brew install yt-dlp\n\n'
          'Then restart the app.';
    }
    return 'yt-dlp not supported on this platform.';
  }

  /// Lists available caption tracks for `videoUrl`. Pass a full
  /// `https://www.youtube.com/watch?v=…` URL — yt-dlp accepts the same forms
  /// the CLI does, so shorts/youtu.be/etc. work too.
  static Future<YtDlpListResult> listTracks(String videoUrl) async {
    await _ensureInit();
    final Map<String, dynamic> raw;
    if (Platform.isAndroid) {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'listTracks',
        {'url': videoUrl},
      ).timeout(const Duration(seconds: 90));
      if (r == null) throw 'yt-dlp returned null';
      raw = _coerceMap(r);
    } else {
      raw = await _macListTracks(videoUrl);
    }
    final tracks = (raw['tracks'] as List? ?? const [])
        .map((e) => YtDlpTrack.fromJson(_coerceMap(e as Map)))
        .toList();
    return YtDlpListResult(
      title: (raw['title'] as String?) ?? '',
      tracks: tracks,
    );
  }

  /// Downloads the chosen caption track. Prefers `json3` (cheap to parse),
  /// falls back to `vtt`. The returned `format` tells the caller which parser
  /// to use.
  static Future<YtDlpSubtitle> downloadSubtitle({
    required String videoUrl,
    required String languageCode,
    required String kind,
  }) async {
    await _ensureInit();
    if (Platform.isAndroid) {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'downloadSubtitle',
        {'url': videoUrl, 'lang': languageCode, 'kind': kind},
      ).timeout(const Duration(minutes: 3));
      if (r == null) throw 'yt-dlp returned null';
      final m = _coerceMap(r);
      return YtDlpSubtitle(
        body: (m['body'] as String?) ?? '',
        format: (m['format'] as String?) ?? 'unknown',
      );
    } else {
      return await _macDownloadSubtitle(videoUrl, languageCode, kind);
    }
  }

  // ---------- internals ----------

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    if (Platform.isAndroid) {
      // First call lazy-extracts the Python+yt-dlp payloads from the APK —
      // can take several seconds on first launch, then ~instant after.
      await _channel
          .invokeMethod<bool>('init')
          .timeout(const Duration(seconds: 60));
      _initialized = true;
    } else if (Platform.isMacOS) {
      _macYtDlpPath ??= await _findMacOsYtDlp();
      if (_macYtDlpPath == null) throw installHint();
      _initialized = true;
    } else {
      throw 'yt-dlp not supported on this platform';
    }
  }

  static Future<String?> _findMacOsYtDlp() async {
    const candidates = [
      '/opt/homebrew/bin/yt-dlp',
      '/usr/local/bin/yt-dlp',
      '/usr/bin/yt-dlp',
    ];
    for (final p in candidates) {
      if (await File(p).exists()) return p;
    }
    // `which` as last resort — picks up unusual install locations.
    try {
      final r = await Process.run('which', ['yt-dlp']);
      final out = r.stdout.toString().trim();
      if (out.isNotEmpty && await File(out).exists()) return out;
    } catch (_) {
      // The macOS app-sandbox may block subprocess spawning entirely; surface
      // a more useful message at `_ensureInit` time rather than swallowing.
    }
    return null;
  }

  static Future<Map<String, dynamic>> _macListTracks(String url) async {
    final r = await Process.run(
      _macYtDlpPath!,
      ['-j', '--skip-download', '--no-warnings', url],
    ).timeout(const Duration(seconds: 90));
    if (r.exitCode != 0) {
      throw 'yt-dlp exit ${r.exitCode}: ${r.stderr.toString().trim()}';
    }
    final info = jsonDecode(r.stdout.toString()) as Map<String, dynamic>;
    final tracks = <Map<String, dynamic>>[];
    (info['subtitles'] as Map?)?.forEach((lang, _) {
      tracks.add({
        'languageCode': lang.toString(),
        'name': lang.toString(),
        'kind': '',
      });
    });
    (info['automatic_captions'] as Map?)?.forEach((lang, _) {
      tracks.add({
        'languageCode': lang.toString(),
        'name': '${lang.toString()} (auto-generated)',
        'kind': 'asr',
      });
    });
    return {
      'title': (info['title'] as String?) ?? '',
      'tracks': tracks,
    };
  }

  static Future<YtDlpSubtitle> _macDownloadSubtitle(
      String url, String lang, String kind) async {
    final tmp = await Directory.systemTemp.createTemp('cupitor-yt-sub-');
    try {
      final args = <String>[
        '--skip-download',
        '--no-warnings',
        if (kind == 'asr') '--write-auto-subs' else '--write-subs',
        '--sub-langs', lang,
        '--sub-format', 'json3/vtt/best',
        '-o', '${tmp.path}/sub.%(ext)s',
        url,
      ];
      final r = await Process.run(_macYtDlpPath!, args)
          .timeout(const Duration(minutes: 3));
      if (r.exitCode != 0) {
        throw 'yt-dlp exit ${r.exitCode}: ${r.stderr.toString().trim()}';
      }
      final files = tmp
          .listSync()
          .whereType<File>()
          .where((f) =>
              f.path.endsWith('.json3') ||
              f.path.endsWith('.vtt') ||
              f.path.endsWith('.srt'))
          .toList();
      if (files.isEmpty) {
        throw "yt-dlp wrote no subtitle file (language '$lang'"
            "${kind == 'asr' ? ' (auto)' : ''} may not exist for this video)";
      }
      files.sort((a, b) {
        int rank(File f) => f.path.endsWith('.json3')
            ? 0
            : f.path.endsWith('.vtt') ? 1 : 2;
        return rank(a) - rank(b);
      });
      final file = files.first;
      final body = await file.readAsString();
      final format = file.path.endsWith('.json3')
          ? 'json3'
          : (file.path.endsWith('.vtt') ? 'vtt' : 'unknown');
      return YtDlpSubtitle(body: body, format: format);
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// MethodChannel decodes maps as `Map<Object?, Object?>` — coerce to the
  /// shape Dart code expects.
  static Map<String, dynamic> _coerceMap(Map raw) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
}
