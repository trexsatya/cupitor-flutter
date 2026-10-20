// Standalone Dart tests: no device, Flutter engine or Spotify account needed.
// Run: dart tool/test_spotify_clip_bridge.dart
import 'dart:async';
import 'dart:convert';
import '../lib/spotify_clip_bridge.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

const url = 'https://open.spotify.com/episode/317TI86OHwkAxLtwi1VnXN';
String request(
  String op, [
  String id = 'one',
  Map<String, Object?> extra = const {},
]) => jsonEncode({
  'op': op,
  'sessionId': id,
  if (op == 'cue') ...{'url': url, 'start': 12.52, 'end': 14.16},
  ...extra,
});

class Page {
  final packets = <Map<String, dynamic>>[];
  Map<String, Object?> state = {'sessionId': null};
  int installs = 0;
  bool installed = true, doubleEncoded = false;
  late final page = SpotifyClipPage(
    identity: this,
    evaluate: evaluate,
    install: () async {
      installed = true;
      installs++;
    },
    show: () async {},
  );
  Future<Object?> evaluate(String script) async {
    if (!installed) return '';
    final start = script.indexOf('.command(') + '.command('.length;
    final packet = Map<String, dynamic>.from(
      jsonDecode(script.substring(start, script.indexOf(')) :', start))) as Map,
    );
    packets.add(packet);
    final op = packet['op'];
    if (op == 'cue')
      state = {
        'sessionId': packet['sessionId'],
        'ready': false,
        'complete': false,
        'position': 12520,
        'duration': 3307760,
        'isPaused': true,
      };
    if (packet['sessionId'] == state['sessionId']) {
      if (op == 'play') state['isPaused'] = false;
      if (op == 'pause' ||
          (op == 'visibility' && packet['foreground'] == false))
        state['isPaused'] = true;
      if (op == 'stop') state = {'sessionId': null, 'isPaused': true};
    }
    return doubleEncoded ? jsonEncode(jsonEncode(state)) : state;
  }
}

Future<void> main() async {
  var passed = 0;
  Future<void> test(String name, FutureOr<void> Function() body) async {
    await body();
    passed++;
    print('PASS $name');
  }

  await test('episode URLs are matched by stable ID', () {
    check(
      spotifyEpisodeId('$url?t=12') == '317TI86OHwkAxLtwi1VnXN',
      'episode timestamp',
    );
    check(
      spotifyEpisodeId('spotify:episode:317TI86OHwkAxLtwi1VnXN') != null,
      'episode URI',
    );
    check(
      spotifyEpisodeId(url.replaceFirst('episode', 'track')) == null,
      'music link',
    );
    check(
      spotifyEpisodeId(url.replaceFirst('open.spotify.com', 'evil.test')) ==
          null,
      'other host',
    );
  });
  await test(
    'both timestamps reach the real page and ready waits for observed seeking',
    () async {
      final page = Page(), events = <Map<String, Object?>>[];
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async => page.page,
        send: (event) async {
          events.add(event);
        },
        autoPoll: false,
      );
      try {
        await bridge.handle(request('cue'));
        final cue = page.packets.firstWhere((p) => p['op'] == 'cue');
        check(cue['start'] == 12.52 && cue['end'] == 14.16, 'both bounds');
        check(events.isEmpty, 'no fake ready');
        page.state['ready'] = true;
        await bridge.poll();
        check(
          events.first['type'] == 'ready' && events.last['position'] == 12520,
          'ready and real time',
        );
        await bridge.handle(request('play'));
        check(page.state['isPaused'] == false, 'actual play command');
        await bridge.handle(request('pause'));
        check(page.state['isPaused'] == true, 'actual pause command');
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  await test(
    'the packaged agent is installed when the remote snippet is unavailable',
    () async {
      final page = Page()..installed = false;
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async => page.page,
        send: (_) async {},
        autoPoll: false,
      );
      try {
        await bridge.handle(request('cue'));
        check(page.installs == 1, 'packaged installation');
        check(page.state['sessionId'] == 'one', 'cue after installation');
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  await test('stale stop and seek cannot affect the next card', () async {
    final page = Page();
    final bridge = SpotifyClipBridge(
      openPage: (_, isCurrent) async => page.page,
      send: (_) async {},
      autoPoll: false,
    );
    try {
      await bridge.handle(request('cue'));
      await bridge.handle(request('cue', 'two', {'start': 30, 'end': 32}));
      final count = page.packets.length;
      await bridge.handle(request('stop'));
      await bridge.handle(request('seek', 'one', {'time': 13}));
      check(page.packets.length == count, 'stale commands ignored');
      await bridge.handle(request('seek', 'two', {'time': 12}));
      check(page.packets.length == count, 'out-of-range seek ignored');
      await bridge.handle(request('seek', 'two', {'time': 31}));
      check(page.packets.last['time'] == 31, 'valid seek forwarded');
      await bridge.handle(request('stop', 'two'));
      check(page.state['isPaused'] == true, 'stop pauses real page');
    } finally {
      await bridge.stop();
      bridge.dispose();
    }
  });
  await test(
    'a cancelled asynchronous open cannot cue or play behind the next card',
    () async {
      final first = Page(),
          second = Page(),
          pending = Completer<SpotifyClipPage>();
      var opens = 0;
      final events = <Map<String, Object?>>[];
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) =>
            ++opens == 1 ? pending.future : Future.value(second.page),
        send: (event) async {
          events.add(event);
        },
        autoPoll: false,
      );
      try {
        final old = bridge.handle(request('cue'));
        await Future<void>.delayed(Duration.zero);
        await bridge.handle(request('cue', 'two'));
        pending.complete(first.page);
        await old;
        check(first.packets.isEmpty, 'old page receives no cue');
        check(second.state['sessionId'] == 'two', 'next page owns playback');
        check(
          events.every((event) => event['sessionId'] != 'one'),
          'old events suppressed',
        );
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  await test('the actual page end completes a clip exactly once', () async {
    final page = Page(), events = <Map<String, Object?>>[];
    final bridge = SpotifyClipBridge(
      openPage: (_, isCurrent) async => page.page,
      send: (event) async {
        events.add(event);
      },
      autoPoll: false,
    );
    try {
      await bridge.handle(request('cue'));
      page.state.addAll({'ready': true, 'complete': true});
      await bridge.poll();
      await bridge.poll();
      check(
        events.where((event) => event['type'] == 'ended').length == 1,
        'one completion',
      );
      check(
        events.firstWhere((event) => event['type'] == 'ended')['position'] ==
            14160,
        'end in milliseconds',
      );
    } finally {
      await bridge.stop();
      bridge.dispose();
    }
  });
  await test(
    'Android and WKWebView return encodings are both decoded',
    () async {
      final page = Page()..doubleEncoded = true;
      final events = <Map<String, Object?>>[];
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async => page.page,
        send: (event) async {
          events.add(event);
        },
        autoPoll: false,
      );
      try {
        await bridge.handle(request('cue'));
        page.state['ready'] = true;
        await bridge.poll();
        check(events.first['type'] == 'ready', 'decoded native result');
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  await test(
    'backgrounding pauses the real WebView and cannot start a pending clip',
    () async {
      final page = Page();
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async => page.page,
        send: (_) async {},
        autoPoll: false,
      );
      try {
        await bridge.handle(request('cue'));
        await bridge.handle(request('play'));
        await bridge.setForeground(false);
        check(page.state['isPaused'] == true, 'native background pause');
        await bridge.handle(request('play'));
        check(page.state['isPaused'] == true, 'background play rejected');
        await bridge.setForeground(true);
        check(
          page.state['isPaused'] == true,
          'foreground alone does not autoplay',
        );
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  await test(
    'closing the Spotify WebView reports closure and clears ownership',
    () async {
      final page = Page(), events = <Map<String, Object?>>[];
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async => page.page,
        send: (event) async {
          events.add(event);
        },
        autoPoll: false,
      );
      try {
        await bridge.handle(request('cue'));
        bridge.pageClosed(page);
        await Future<void>.delayed(Duration.zero);
        check(events.last['type'] == 'closed', 'closed error');
        final count = page.packets.length;
        await bridge.handle(request('play'));
        check(page.packets.length == count, 'no replay after close');
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  await test('missing playback is bounded by a foreground timeout', () async {
    final page = Page(), events = <Map<String, Object?>>[];
    var now = 0;
    final bridge = SpotifyClipBridge(
      openPage: (_, isCurrent) async => page.page,
      send: (event) async {
        events.add(event);
      },
      nowMs: () => now,
      autoPoll: false,
    );
    try {
      await bridge.handle(request('cue'));
      now = 21000;
      await bridge.poll();
      check(events.last['type'] == 'error', 'timeout failure');
      check(page.state['isPaused'] == true, 'timeout stops page');
    } finally {
      await bridge.stop();
      bridge.dispose();
    }
  });
  await test(
    'invalid ranges and non-JSON input cannot open a player',
    () async {
      var opened = 0;
      final errors = <Map<String, Object?>>[];
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async {
          opened++;
          return Page().page;
        },
        send: (event) async {
          errors.add(event);
        },
        autoPoll: false,
      );
      try {
        await bridge.handle('not json');
        await bridge.handle('[]');
        for (final extra in [
          {'end': 12},
          {'start': -1},
          {'end': null},
          {'url': 'https://evil.test/episode/317TI86OHwkAxLtwi1VnXN'},
        ]) {
          await bridge.handle(request('cue', 'one', extra));
        }
        check(opened == 0 && errors.length == 4, 'invalid cue rejection');
      } finally {
        bridge.dispose();
      }
    },
  );
  await test(
    'losing the study-page listener pauses the real Spotify page',
    () async {
      final page = Page();
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async => page.page,
        send: (_) async {
          throw StateError('study renderer gone');
        },
        autoPoll: false,
      );
      try {
        await bridge.handle(request('cue'));
        page.state['ready'] = true;
        await bridge.handle(request('play'));
        await bridge.poll();
        check(page.state['isPaused'] == true, 'lost owner stops real playback');
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  await test(
    'a background cue installs its paused guard before waiting for foreground',
    () async {
      final page = Page()..installed = false;
      final events = <Map<String, Object?>>[];
      final bridge = SpotifyClipBridge(
        openPage: (_, isCurrent) async => page.page,
        send: (event) async {
          events.add(event);
        },
        autoPoll: false,
      );
      try {
        await bridge.setForeground(false);
        await bridge.handle(request('cue'));
        check(
          page.installs == 1 && page.state['sessionId'] == 'one',
          'background guard is installed',
        );
        check(
          page.packets.last['op'] == 'visibility' &&
              page.state['isPaused'] == true,
          'background guard is paused',
        );
        check(events.isEmpty, 'background cue does not advance the queue');
      } finally {
        await bridge.stop();
        bridge.dispose();
      }
    },
  );
  print('$passed Spotify host bridge tests passed.');
}
