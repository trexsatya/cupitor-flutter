import 'dart:convert';

import 'package:cupitor/study_call_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<(String, Map<String, Object?>)> events;
  late List<(String, Map<String, Object?>)> invocations;
  var profile = 7;
  var refreshFails = false;
  late StudyCallBridge bridge;
  setUp(() {
    events = [];
    invocations = [];
    profile = 7;
    refreshFails = false;
    bridge = StudyCallBridge(
      supported: true,
      activeProfileId: () => profile,
      emit: (name, data) => events.add((name, data)),
      invoke: (op, args) async {
        invocations.add((op, args));
        if (op == 'getCalls') {
          if (refreshFails) throw PlatformException(code: 'storage_error');
          return {'version': 1, 'calls': <Object>[]};
        }
        if (op == 'cancel') throw PlatformException(code: 'unknown_call');
        return {'id': 'native-id'};
      },
    );
  });

  test(
    'host supplies profile; successful mutation acks once and pushes history',
    () async {
      await bridge.handle(
        jsonEncode({'op': 'schedule', 'request_id': 'r', 'profile_id': 99}),
      );
      expect(invocations.map((i) => i.$1), ['schedule', 'getCalls']);
      expect(invocations.every((i) => i.$2['profile_id'] == 7), true);
      expect(events.map((e) => e.$1), ['cupitorCallAck', 'cupitorCalls']);
      expect(events.first.$2, {
        'request_id': 'r',
        'op': 'schedule',
        'ok': true,
        'data': {'id': 'native-id'},
      });
    },
  );

  test('new pending operations use host profile and publish a snapshot', () async {
    for (final op in ['scheduleBatch', 'update', 'setEnabled', 'remove']) {
      invocations.clear(); events.clear();
      await bridge.handle(jsonEncode({'op': op, 'request_id': op,
        'profile_id': 99, 'id': 'x', 'enabled': false,
        'calls': [{'profile_id': 99}]}));
      expect(invocations.map((i) => i.$1), [op, 'getCalls']);
      expect(invocations.first.$2['profile_id'], 7);
      expect(events.first.$2['ok'], true);
      expect(events.last.$1, 'cupitorCalls');
    }
  });

  test('a failed refresh cannot produce a contradictory second ack', () async {
    refreshFails = true;
    await bridge.handle('{"op":"callNow","request_id":"r"}');
    expect(events, hasLength(1));
    expect(events.single.$2['ok'], true);
  });

  test(
    'bad JSON, nonobjects, unknown operations and platform errors all ack',
    () async {
      for (final input in ['{bad', '[]', 'null']) {
        await bridge.handle(input);
        expect(events.last.$2['error'], 'bad_json');
      }
      await bridge.handle('{"op":"oops"}');
      expect(events.last.$2['error'], 'unknown_op');
      await bridge.handle('{"op":"cancel"}');
      expect(events.last.$2['error'], 'unknown_call');
    },
  );

  test(
    'non-Android advertises unsupported and never invokes native code',
    () async {
      final unsupported = StudyCallBridge(
        supported: false,
        activeProfileId: () => 1,
        emit: (e, d) => events.add((e, d)),
        invoke: (_, __) async => fail('unexpected native call'),
      );
      await unsupported.handle('{"op":"getCapabilities"}');
      expect(events.single.$2['data'], {'supported': false});
      await unsupported.handle('{"op":"callNow"}');
      expect(events.last.$2['error'], 'unsupported');
    },
  );

  test(
    'profile switch during an async fetch never publishes another profile snapshot',
    () async {
      bridge = StudyCallBridge(
        supported: true,
        activeProfileId: () => profile,
        emit: (e, d) => events.add((e, d)),
        invoke: (_, __) async {
          profile = 8;
          return {'calls': []};
        },
      );
      await bridge.handle('{"op":"getCalls"}');
      expect(events.where((e) => e.$1 == 'cupitorCalls'), isEmpty);
    },
  );
}
