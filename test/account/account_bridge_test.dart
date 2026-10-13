import 'dart:async';

import 'package:cupitor/account/account_bridge.dart';
import 'package:cupitor/account/github_device_signin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<(String, Map<String, Object?>)> events;
  late List<String> stored;
  late int signOuts;
  late bool hasToken;
  Future<String?> Function() signIn = () async => 'ghu_x';

  AccountBridge make() => AccountBridge(
        signIn: () => signIn(),
        storeToken: (t) async => stored.add(t),
        signOut: () async { signOuts++; hasToken = false; },
        hasToken: () => hasToken,
        emit: (e, d) => events.add((e, d)),
      );

  setUp(() {
    events = [];
    stored = [];
    signOuts = 0;
    hasToken = false;
    signIn = () async => 'ghu_x';
  });

  Map<String, Object?> lastAck() => events.last.$2;

  test('signIn stores the token and acks signed_in with the request id', () async {
    await make().handle('{"op":"signIn","request_id":"r1"}');
    expect(stored, ['ghu_x']);
    expect(events.single.$1, AccountBridge.ackEvent);
    expect(lastAck(), {'request_id': 'r1', 'op': 'signIn', 'ok': true, 'data': {'signed_in': true}});
  });

  test('a closed dialog is cancelled; nothing is stored', () async {
    signIn = () async => null;
    await make().handle('{"op":"signIn","request_id":"r2"}');
    expect(stored, isEmpty);
    expect(lastAck(), {'request_id': 'r2', 'op': 'signIn', 'ok': false, 'error': 'cancelled'});
  });

  test('device-flow failures map to their code; anything else is internal', () async {
    for (final code in ['cancelled', 'denied', 'expired', 'network']) {
      signIn = () async => throw DeviceSignInException(code, 'x');
      await make().handle('{"op":"signIn","request_id":"$code"}');
      expect(lastAck(), {'request_id': code, 'op': 'signIn', 'ok': false, 'error': code});
    }
    // The flow's generic 'error' code is not part of the bridge contract.
    signIn = () async => throw const DeviceSignInException('error', 'HTTP 500');
    await make().handle('{"op":"signIn","request_id":"e"}');
    expect(lastAck(), {'request_id': 'e', 'op': 'signIn', 'ok': false, 'error': 'internal'});
    expect(stored, isEmpty);
    signIn = () async => throw StateError('boom');
    await make().handle('{"op":"signIn","request_id":"r3"}');
    expect(lastAck()['error'], 'internal');
  });

  test('a second signIn while one is running is busy; the first still completes', () async {
    final gate = Completer<String?>();
    signIn = () => gate.future;
    final bridge = make();
    final first = bridge.handle('{"op":"signIn","request_id":"a"}');
    await bridge.handle('{"op":"signIn","request_id":"b"}');
    expect(lastAck(), {'request_id': 'b', 'op': 'signIn', 'ok': false, 'error': 'busy'});
    gate.complete('ghu_y');
    await first;
    expect(stored, ['ghu_y']);
    expect(events.where((e) => e.$2['request_id'] == 'a').single.$2['ok'], true);
    // And a third one after completion runs again.
    signIn = () async => 'ghu_z';
    await bridge.handle('{"op":"signIn","request_id":"c"}');
    expect(lastAck()['ok'], true);
  });

  test('signOut clears the token and acks signed_in:false', () async {
    hasToken = true;
    await make().handle('{"op":"signOut","request_id":"s"}');
    expect(signOuts, 1);
    expect(lastAck(), {'request_id': 's', 'op': 'signOut', 'ok': true, 'data': {'signed_in': false}});
  });

  test('a failing signOut acks internal instead of throwing', () async {
    final bridge = AccountBridge(
      signIn: () async => null,
      storeToken: (_) async {},
      signOut: () async => throw StateError('disk'),
      hasToken: () => true,
      emit: (e, d) => events.add((e, d)),
    );
    await bridge.handle('{"op":"signOut","request_id":"sf"}');
    expect(lastAck(), {'request_id': 'sf', 'op': 'signOut', 'ok': false, 'error': 'internal'});
  });

  test('getStatus reports whether a token is stored', () async {
    await make().handle('{"op":"getStatus","request_id":"g1"}');
    expect(lastAck()['data'], {'signed_in': false});
    hasToken = true;
    await make().handle('{"op":"getStatus","request_id":"g2"}');
    expect(lastAck(), {'request_id': 'g2', 'op': 'getStatus', 'ok': true, 'data': {'signed_in': true}});
  });

  test('bad json and unknown ops are acked, never thrown', () async {
    final bridge = make();
    await bridge.handle('{nope');
    expect(lastAck(), {'request_id': null, 'op': 'unknown', 'ok': false, 'error': 'bad_json'});
    await bridge.handle('{"op":"dance","request_id":"u"}');
    expect(lastAck(), {'request_id': 'u', 'op': 'dance', 'ok': false, 'error': 'unknown_op'});
    await bridge.handle('{"request_id":"v"}');
    expect(lastAck(), {'request_id': 'v', 'op': 'unknown', 'ok': false, 'error': 'unknown_op'});
  });
}
