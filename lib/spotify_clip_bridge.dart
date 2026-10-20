import 'dart:async';
import 'dart:convert';

/// The real Spotify page, independent of the study page that owns the queue.
class SpotifyClipPage {
  const SpotifyClipPage({
    required this.identity,
    required this.evaluate,
    required this.install,
    required this.show,
  });
  final Object identity;
  final Future<Object?> Function(String) evaluate;
  final Future<void> Function() install;
  final Future<void> Function() show;
}

String? spotifyEpisodeId(Object? value) {
  final text = value?.toString() ?? '';
  final uri = RegExp(r'^spotify:episode:([A-Za-z0-9]{22})$').firstMatch(text);
  if (uri != null) return uri.group(1);
  final url = Uri.tryParse(text);
  if (url?.scheme != 'https' || url?.host != 'open.spotify.com') return null;
  return RegExp(
    r'^/(?:intl-[\w-]+/)?(?:embed/)?episode/([A-Za-z0-9]{22})/?$',
  ).firstMatch(url!.path)?.group(1);
}

class _Clip {
  _Clip(this.id, this.episode, this.start, this.end, this.since);
  final String id, episode;
  final double start, end;
  int since;
  SpotifyClipPage? page;
  bool installed = false, ready = false, ended = false;
}

/// Carries commands from dialog1 to Spotify's own WebView. The page's bundled
/// agent stops at the end itself; this pump reports actual progress to the
/// playlist, including when the study WebView is covered by another dialog.
class SpotifyClipBridge {
  SpotifyClipBridge({
    required this.openPage,
    required this.send,
    int Function()? nowMs,
    this.autoPoll = true,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  final Future<SpotifyClipPage> Function(String, bool Function()) openPage;
  final Future<void> Function(Map<String, Object?>) send;
  final int Function() nowMs;
  final bool autoPoll;
  _Clip? _active;
  Timer? _timer;
  bool _polling = false, _disposed = false, _foreground = true;

  Future<void> handle(String raw) async {
    if (_disposed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final request = Map<String, dynamic>.from(decoded);
    final op = request['op'], id = request['sessionId'];
    if (id is! String || id.isEmpty) return;
    if (op == 'cue') {
      final episode = spotifyEpisodeId(request['url']);
      final start = request['start'], end = request['end'];
      if (episode == null ||
          start is! num ||
          end is! num ||
          !start.isFinite ||
          !end.isFinite ||
          start < 0 ||
          end <= start) {
        await _emit({
          'sessionId': id,
          'type': 'error',
          'message': 'Invalid Spotify clip bounds.',
        });
        return;
      }
      final previous = _active;
      final clip = _Clip(
        id,
        episode,
        start.toDouble(),
        end.toDouble(),
        nowMs(),
      );
      _active = clip;
      if (previous?.page != null) {
        try {
          await _command(previous!, {'op': 'stop'});
        } catch (_) {}
      }
      if (!_current(clip)) return;
      try {
        final page = await openPage(
          'https://open.spotify.com/episode/$episode',
          () => _current(clip),
        );
        if (!_current(clip)) return;
        clip.page = page;
        _timer?.cancel();
        if (autoPoll)
          _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
            unawaited(poll());
          });
        await poll();
      } catch (error) {
        await _fail(clip, error.toString());
      }
      return;
    }
    final clip = _active;
    if (clip == null || clip.id != id) return;
    if (op == 'stop') {
      await stop();
      return;
    }
    if (op == 'show') {
      try {
        await clip.page?.show();
      } catch (_) {}
      return;
    }
    if (op == 'play' && !_foreground) return;
    if (op == 'pause' || op == 'play' || op == 'seek') {
      final time = request['time'];
      if (op == 'seek' &&
          (time is! num ||
              !time.isFinite ||
              time < clip.start ||
              time >= clip.end))
        return;
      try {
        await _command(clip, {'op': op, if (op == 'seek') 'time': time});
      } catch (error) {
        await _fail(clip, error.toString());
      }
    }
  }

  Future<void> _emit(Map<String, Object?> event) async {
    try {
      await send(event);
    } catch (_) {
      await stop();
    }
  }

  bool _current(_Clip clip) => !_disposed && identical(_active, clip);
  Future<Map<String, dynamic>?> _command(
    _Clip clip,
    Map<String, Object?> command,
  ) async {
    final page = clip.page;
    if (page == null) return null;
    final body = jsonEncode({...command, 'sessionId': clip.id});
    final result = await page.evaluate(
      'window.__cupSpotifyClipAgent ? '
      'JSON.stringify(window.__cupSpotifyClipAgent.command($body)) : ""',
    );
    Object? value = result;
    // WKWebView returns a string directly; Android can JSON-encode it again.
    for (var i = 0; i < 3 && value is String && value.isNotEmpty; i++) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> poll() async {
    final clip = _active;
    if (_polling || clip?.page == null || !_current(clip!)) return;
    _polling = true;
    try {
      var state = await _command(clip, {'op': 'state'});
      if (!_current(clip)) return;
      if (state == null) {
        await clip.page!.install();
        if (!_current(clip)) return;
        state = await _command(clip, {'op': 'state'});
      }
      if (!_current(clip)) return;
      if (state != null && state['sessionId'] != clip.id) {
        state = await _command(clip, {
          'op': 'cue',
          'url': 'https://open.spotify.com/episode/${clip.episode}',
          'start': clip.start,
          'end': clip.end,
        });
      }
      if (!_current(clip)) return;
      if (!_foreground) {
        clip.since = nowMs();
        await _command(clip, {'op': 'visibility', 'foreground': false});
        return;
      }
      if (state?['error'] is String) {
        await _fail(clip, state!['error'] as String);
        return;
      }
      if (state?['ready'] == true && !clip.ready) {
        clip.ready = true;
        await _emit({'sessionId': clip.id, 'type': 'ready'});
      }
      if (!_current(clip)) return;
      if (state?['complete'] == true && !clip.ended) {
        clip.ended = true;
        await _emit({
          'sessionId': clip.id,
          'type': 'ended',
          'position': clip.end * 1000,
          'duration': state?['duration'],
          'playingURI': 'spotify:episode:${clip.episode}',
        });
      } else if (clip.ready && !clip.ended) {
        await _emit({
          'sessionId': clip.id,
          'type': 'playback_update',
          'position': state?['position'],
          'duration': state?['duration'],
          'isPaused': state?['isPaused'] != false,
          'isBuffering': state?['isBuffering'] == true,
          'playingURI': 'spotify:episode:${clip.episode}',
        });
      } else if (!clip.ready && nowMs() - clip.since > 20000) {
        await _fail(
          clip,
          'Spotify could not reach the clip timestamp. Open Spotify and connect playback.',
        );
      }
    } catch (error) {
      await _fail(clip, error.toString());
    } finally {
      _polling = false;
    }
  }

  Future<void> _fail(_Clip clip, String message) async {
    if (!_current(clip)) return;
    await stop();
    await _emit({'sessionId': clip.id, 'type': 'error', 'message': message});
  }

  Future<void> stop() async {
    final previous = _active;
    _active = null;
    _timer?.cancel();
    _timer = null;
    if (previous != null) {
      try {
        await _command(previous, {'op': 'stop'});
      } catch (_) {}
    }
  }

  void pageClosed(Object identity) {
    final clip = _active;
    if (clip?.page?.identity == identity) {
      unawaited(_closed(clip!));
    }
  }

  Future<void> _closed(_Clip clip) async {
    if (!_current(clip)) return;
    await stop();
    await _emit({'sessionId': clip.id, 'type': 'closed'});
  }

  Future<void> setForeground(bool foreground) async {
    _foreground = foreground;
    final clip = _active;
    if (clip == null) return;
    clip.since = nowMs();
    try {
      await _command(clip, {'op': 'visibility', 'foreground': foreground});
    } catch (_) {}
  }

  void dispose() {
    unawaited(stop());
    _disposed = true;
  }
}
