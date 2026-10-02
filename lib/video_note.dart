/// A note typed or dictated against the moment a video is at, sent to the
/// language webapp as a manual playlist item.
///
/// It rides the caption-capture path (`buildCaptionCaptureDetail` →
/// `cupitorCaptionCapture`) as a one-line `caption` block whose start is the
/// player's current time. That is what makes the webapp's card link open the
/// video at that moment: it writes the page's own start-offset parameter
/// (`timeParam`) with the earliest line start onto the link.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'speech_hub.dart';

// Every <video> in the page and its same-origin iframes that has loaded
// enough to report a position. Shared by the presence probe and the tap, so
// the button never shows for a video the tap then cannot find.
const String _usableVideosJs = '''
function __cupNoteVideos() {
  var out = [].slice.call(document.querySelectorAll('video'));
  var frames = document.querySelectorAll('iframe');
  for (var i = 0; i < frames.length; i++) {
    try {
      var d = frames[i].contentDocument;
      if (d) out = out.concat([].slice.call(d.querySelectorAll('video')));
    } catch (e) {}
  }
  return out.filter(function (v) {
    return (v.readyState > 0 || v.currentTime > 0) && isFinite(v.currentTime);
  });
}
''';

/// Is there a video on the page? Cheap enough to poll while the button is on.
const String kHasVideoJs =
    '(function(){$_usableVideosJs return __cupNoteVideos().length > 0;})()';

/// Reads the main video's position and the page's capture identity, and
/// pauses the video when [pause] is true so the moment holds still (and the
/// soundtrack stays out of the mic) while the note is written.
///
/// The identity comes from the injected snippet's shared helpers when they
/// are there — the same builder the subtitle sidebar uses, so the page's
/// address, start-offset name and "link wanted" answer match what a caption
/// send from this page carries. Without them the address goes as it is.
String videoMomentJs({required bool pause}) => '''
(function () {
  $_usableVideosJs
  function area(v) { var r = v.getBoundingClientRect(); return r.width * r.height; }
  var vs = __cupNoteVideos();
  if (!vs.length) return JSON.stringify({ found: false });
  vs.sort(function (a, b) {
    var pa = !a.paused && !a.ended ? 1 : 0, pb = !b.paused && !b.ended ? 1 : 0;
    return pa !== pb ? pb - pa : area(b) - area(a);
  });
  var v = vs[0];
  var wasPlaying = !v.paused && !v.ended;
  if ($pause && wasPlaying) { v.pause(); window.__cupNoteVideo = v; }
  var id = { url: location.href, timeParam: '', timeLink: true, title: document.title || '' };
  try {
    var s = window.__cupShared || {};
    if (typeof s.capturePayload === 'function') {
      var site = typeof s.resolveCaptionSite === 'function' ? s.resolveCaptionSite() : null;
      var p = s.capturePayload(location.href, document.title, '', [],
          site && site.timeParam, site && site.timeLinkOn);
      id = { url: p.url, timeParam: p.timeParam, timeLink: p.timeLink !== false, title: p.title };
    }
  } catch (e) {}
  return JSON.stringify({
    found: true, time: v.currentTime, wasPlaying: wasPlaying,
    url: id.url, timeParam: id.timeParam, timeLink: id.timeLink, title: id.title
  });
})()
''';

/// Plays the video [videoMomentJs] paused, if it did pause one.
const String kResumeNoteVideoJs =
    '(function(){var v=window.__cupNoteVideo;window.__cupNoteVideo=null;'
    'if(v){try{var p=v.play();if(p&&p.catch)p.catch(function(){});}catch(e){}}})()';

class VideoMoment {
  final double seconds;
  final bool wasPlaying;
  final String title;
  final String url;
  final String timeParam;
  final bool timeLink;

  const VideoMoment({
    required this.seconds,
    required this.wasPlaying,
    required this.title,
    required this.url,
    required this.timeParam,
    required this.timeLink,
  });
}

/// Parses what [videoMomentJs] returned. Null when there is no video or the
/// answer cannot be read. Android hands back a JSON-encoded string, WKWebView
/// the string itself, so one extra decode is tried.
VideoMoment? parseVideoMoment(Object? raw) {
  if (raw == null) return null;
  Object? v = raw.toString();
  for (var i = 0; i < 2 && v is String; i++) {
    try {
      v = jsonDecode(v);
    } catch (_) {
      return null;
    }
  }
  if (v is! Map || v['found'] != true) return null;
  final t = v['time'];
  if (t is! num || !t.isFinite || t < 0) return null;
  String s(Object? x) => x == null ? '' : x.toString().trim();
  return VideoMoment(
    seconds: t.toDouble(),
    wasPlaying: v['wasPlaying'] == true,
    title: s(v['title']),
    url: s(v['url']),
    timeParam: s(v['timeParam']),
    timeLink: v['timeLink'] != false,
  );
}

/// The raw block [buildCaptionCaptureDetail] accepts: one line at the moment,
/// or at [seconds] when the user moved it in the dialog.
Map<String, dynamic> videoNoteBlock(VideoMoment m, String text,
        {double? seconds}) =>
    {
      'source': 'caption',
      'title': m.title,
      'url': m.url,
      'timeParam': m.timeParam,
      'timeLink': m.timeLink,
      'lines': [
        {
          'start': seconds ?? m.seconds,
          'end': seconds ?? m.seconds,
          'text': text.trim(),
        },
      ],
    };

/// `m:ss`, or `h:mm:ss` from an hour on.
String formatVideoClock(num seconds) {
  final total = seconds.floor();
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Reads `s`, `m:ss` or `h:mm:ss` back into seconds. Null for anything else,
/// including a minutes or seconds part of 60 or more after the first part.
int? parseVideoClock(String input) {
  final parts = input.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var total = 0;
  for (var i = 0; i < parts.length; i++) {
    if (!RegExp(r'^\d+$').hasMatch(parts[i])) return null;
    final n = int.parse(parts[i]);
    if (i > 0 && n >= 60) return null;
    total = total * 60 + n;
  }
  return total;
}

/// What the dialog hands back: the text, and the moment it belongs to.
class VideoNote {
  final String text;
  final double seconds;
  const VideoNote(this.text, this.seconds);
}

/// Shows the note dialog. Returns the note to send, or null when cancelled.
///
/// [prepareMic] runs before each listen; it frees the recognizer from any
/// other feature and checks permission, returning false to give up.
Future<VideoNote?> showVideoNoteDialog(
  BuildContext context, {
  required VideoMoment moment,
  required String? speechLocale,
  required Future<bool> Function() prepareMic,
}) {
  return showDialog<VideoNote>(
    context: context,
    builder: (_) => _VideoNoteDialog(
      moment: moment,
      speechLocale: speechLocale,
      prepareMic: prepareMic,
    ),
  );
}

class _VideoNoteDialog extends StatefulWidget {
  final VideoMoment moment;
  final String? speechLocale;
  final Future<bool> Function() prepareMic;

  const _VideoNoteDialog({
    required this.moment,
    required this.speechLocale,
    required this.prepareMic,
  });

  @override
  State<_VideoNoteDialog> createState() => _VideoNoteDialogState();
}

class _VideoNoteDialogState extends State<_VideoNoteDialog> {
  final TextEditingController _ctrl = TextEditingController();
  late final TextEditingController _timeCtrl =
      TextEditingController(text: formatVideoClock(widget.moment.seconds));
  // The player's own fractional time until the user changes it, so an
  // untouched note lands exactly where the video was.
  late double _seconds = widget.moment.seconds;
  bool _timeValid = true;
  stt.SpeechToText get _speech => SpeechHub.speech;
  late final SpeechHubListener _hubListener = SpeechHubListener(
    onSpeechStatus: (status) {
      if (status == 'done') _setListening(false);
    },
    onSpeechError: (SpeechRecognitionError _) => _setListening(false),
    onSpeechLost: () => _setListening(false),
  );
  bool _listening = false;
  // A tap is being handled (permission, init) — a second one is ignored.
  bool _micBusy = false;
  // Whether this dialog ever opened the mic. Closing must not cancel a
  // recognizer some other feature is using.
  bool _usedMic = false;
  // Text that is settled: what was typed before the mic opened, plus every
  // final result since. The field shows this plus the live partial.
  String _committed = '';

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
  }

  void _onTimeTyped(String v) {
    final n = parseVideoClock(v);
    setState(() {
      _timeValid = n != null;
      if (n != null && n != _seconds.floor()) _seconds = n.toDouble();
    });
  }

  void _nudge(int delta) {
    setState(() {
      _seconds = (_seconds.floorToDouble() + delta).clamp(0, double.infinity);
      _timeValid = true;
      _timeCtrl.text = formatVideoClock(_seconds);
    });
  }

  @override
  void dispose() {
    SpeechHub.release(_hubListener);
    // cancel(), not stop(): stop() can fire one last result into a disposed
    // controller.
    if (_usedMic) _speech.cancel().catchError((_) {});
    _ctrl.dispose();
    _timeCtrl.dispose();
    super.dispose();
  }

  void _setListening(bool on) {
    if (mounted && _listening != on) setState(() => _listening = on);
  }

  String _join(String a, String b) =>
      a.isEmpty || b.isEmpty || a.endsWith(' ') || a.endsWith('\n') ? '$a$b' : '$a $b';

  Future<void> _toggleMic() async {
    if (_micBusy) return;
    _micBusy = true;
    try {
      await _toggleMicNow();
    } finally {
      _micBusy = false;
    }
  }

  Future<void> _toggleMicNow() async {
    if (_listening) {
      try { await _speech.stop(); } catch (_) {}
      _setListening(false);
      return;
    }
    if (!await widget.prepareMic() || !await SpeechHub.ensureInitialized()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech recognition unavailable.')),
        );
      }
      return;
    }
    if (!mounted) return;
    _committed = _ctrl.text;
    _usedMic = true;
    _setListening(true);
    SpeechHub.acquire(_hubListener);
    try {
      await _speech.listen(
        localeId: widget.speechLocale,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 5),
        listenOptions: stt.SpeechListenOptions(partialResults: true),
        onResult: (r) {
          if (!mounted) return;
          final words = r.recognizedWords.trim();
          // The user typed while listening: what they typed is the new base,
          // rather than being overwritten by the next result.
          if (!_ctrl.text.startsWith(_committed)) _committed = _ctrl.text;
          if (r.finalResult) _committed = _join(_committed, words);
          _ctrl.text = r.finalResult ? _committed : _join(_committed, words);
          _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
        },
      );
    } catch (_) {
      _setListening(false);
      return;
    }
    // The platform can refuse silently — no throw, no callback. Don't leave
    // the mic lit over nothing.
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && _listening && !_speech.isListening) _setListening(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.moment;
    final canSend = _ctrl.text.trim().isNotEmpty && _timeValid;
    return AlertDialog(
      title: const Text('Video note'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(m.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            Row(
              children: [
                const Text('At'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _timeCtrl,
                    keyboardType: TextInputType.datetime,
                    textAlign: TextAlign.center,
                    onChanged: _onTimeTyped,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      errorText: _timeValid ? null : 'm:ss',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Back 5 seconds',
                  icon: const Icon(Icons.replay_5),
                  onPressed: () => _nudge(-5),
                ),
                IconButton(
                  tooltip: 'Forward 5 seconds',
                  icon: const Icon(Icons.forward_5),
                  onPressed: () => _nudge(5),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Type or dictate',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _listening ? 'Stop dictation' : 'Dictate',
                  icon: Icon(_listening ? Icons.mic : Icons.mic_none,
                      color: _listening ? Colors.red : null),
                  onPressed: _toggleMic,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSend
              ? () => Navigator.of(context)
                  .pop(VideoNote(_ctrl.text.trim(), _seconds))
              : null,
          child: const Text('Send'),
        ),
      ],
    );
  }
}

/// Keeps a `found a video` flag current while the button is switched on.
/// [probe] runs [kHasVideoJs] in the page and returns its raw result.
class VideoPresencePoller {
  final Future<Object?> Function() probe;
  final void Function(bool hasVideo) onChange;
  Timer? _timer;
  bool _last = false;

  VideoPresencePoller({required this.probe, required this.onChange});

  bool get hasVideo => _last;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _check());
    _check();
  }

  /// Stops polling without reporting the change — for teardown, where the
  /// listener can no longer act on it.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void stop() {
    dispose();
    if (_last) {
      _last = false;
      onChange(false);
    }
  }

  Future<void> _check() async {
    bool now;
    try {
      final r = (await probe()).toString();
      now = r == 'true' || r == '1';
    } catch (_) {
      now = false;
    }
    if (_timer == null && now) return; // stopped while the probe was out
    if (now != _last) {
      _last = now;
      onChange(now);
    }
  }
}
