// JSON-lines harness for the real host bridge + the two JavaScript WebViews.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/spotify_clip_bridge.dart';

void main() {
  var serial = 0;
  final pending = <int, Completer<Object?>>{};
  void write(Map<String, Object?> value) => stdout.writeln(jsonEncode(value));
  final page = SpotifyClipPage(
    identity: Object(),
    install: () async {},
    show: () async {},
    evaluate: (script) {
      final id = ++serial, result = Completer<Object?>();
      pending[id] = result;
      write({'kind': 'evaluate', 'id': id, 'script': script});
      return result.future;
    },
  );
  final bridge = SpotifyClipBridge(
    openPage: (_, isCurrent) async => page,
    send: (detail) async {
      write({'kind': 'event', 'detail': detail});
    },
    autoPoll: false,
  );
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          final message = jsonDecode(line) as Map;
          if (message['kind'] == 'result') {
            pending.remove(message['id'])?.complete(message['value']);
            return;
          }
          final operation = message['kind'] == 'handle'
              ? bridge.handle(jsonEncode(message['packet']))
              : bridge.poll();
          unawaited(
            operation.then(
              (_) {
                write({'kind': 'done', 'id': message['id']});
              },
              onError: (Object error) {
                write({
                  'kind': 'done',
                  'id': message['id'],
                  'error': error.toString(),
                });
              },
            ),
          );
        },
        onDone: () {
          bridge.dispose();
        },
      );
}
