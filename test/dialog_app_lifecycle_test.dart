import 'dart:convert';

import 'package:cupitor/dialog_app_lifecycle.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _detail(String script) =>
    jsonDecode(RegExp(r'Object.freeze\((\{[^\n]+\})\)').firstMatch(script)!.group(1)!)
        as Map<String, dynamic>;

void main() {
  testWidgets('signals every host lifecycle state and foreground return', (
    tester,
  ) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final events = <Map<String, dynamic>>[];
    final bridge = DialogAppLifecycleBridge(
      binding: binding,
      send: (script) async => events.add(_detail(script)),
    );
    addTearDown(() {
      bridge.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    expect(events, [
      {'state': 'inactive', 'isForeground': false},
      {'state': 'hidden', 'isForeground': false},
      {'state': 'paused', 'isForeground': false},
      {'state': 'detached', 'isForeground': false},
      {'state': 'resumed', 'isForeground': true},
    ]);
  });

  testWidgets('page loads and late listeners receive the current state', (
    tester,
  ) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final events = <Map<String, dynamic>>[];
    final bridge = DialogAppLifecycleBridge(
      binding: binding,
      send: (script) async => events.add(_detail(script)),
    );
    addTearDown(() {
      bridge.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await bridge.sendCurrent();
    expect(events.single, {'state': 'paused', 'isForeground': false});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await bridge.sendCurrent();
    expect(events.last, {'state': 'resumed', 'isForeground': true});
    expect(events.length, 3);
  });

  testWidgets('a failed page send recovers and disposal stops delivery', (
    tester,
  ) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var attempts = 0;
    final events = <Map<String, dynamic>>[];
    final bridge = DialogAppLifecycleBridge(
      binding: binding,
      send: (script) async {
        if (++attempts == 1) throw StateError('renderer reclaimed');
        events.add(_detail(script));
      },
    );
    addTearDown(() {
      bridge.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await bridge.sendCurrent();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(events.single, {'state': 'inactive', 'isForeground': false});
    bridge.dispose();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await bridge.sendCurrent();
    await tester.pump();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
}
