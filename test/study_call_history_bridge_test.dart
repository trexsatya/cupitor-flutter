import 'dart:async';
import 'package:cupitor/study_call_history_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const raw = {'id': 'missed-7', 'profile_id': 7, 'open_id': 'tap-1'};

  test('a cold pending tap is consumed at startup and keeps its owning profile', () async {
    final queue = <Object?>[raw, null];
    final opened = <StudyCallHistoryTarget>[];
    final bridge = StudyCallHistoryBridge(supported: true,
      takePending: () async => queue.removeAt(0), onOpen: (target) async { opened.add(target); });
    await bridge.start();
    expect(opened.single.id, 'missed-7');
    expect(opened.single.profileId, 7);
    expect(opened.single.openId, 'tap-1');
    bridge.dispose();
  });

  test('concurrent resume and warm tap checks serialize navigation without dropping the next tap', () async {
    final first = Completer<void>();
    final opened = <String>[];
    final queue = <Object?>[raw, {'id': 'missed-9', 'profile_id': 9, 'open_id': 'tap-2'}, null];
    var inFlight = 0, maxInFlight = 0;
    final bridge = StudyCallHistoryBridge(supported: true,
      takePending: () async => queue.isEmpty ? null : queue.removeAt(0),
      onOpen: (target) async {
        inFlight++; if (inFlight > maxInFlight) maxInFlight = inFlight;
        opened.add(target.id);
        if (target.id == 'missed-7') await first.future;
        inFlight--;
      });
    final running = bridge.checkPending();
    await Future<void>.delayed(Duration.zero);
    await bridge.checkPending();
    first.complete(); await running;
    expect(opened, ['missed-7', 'missed-9']);
    expect(maxInFlight, 1);
    bridge.dispose();
  });

  test('unsupported platforms, disposed pages and malformed payloads never navigate', () async {
    var opens = 0, takes = 0;
    final unsupported = StudyCallHistoryBridge(supported: false,
      takePending: () async { takes++; return raw; }, onOpen: (_) async { opens++; });
    await unsupported.start(); expect(takes, 0); unsupported.dispose();
    for (final bad in [null, [], {'id': '', 'profile_id': 7, 'open_id': 'x'},
      {'id': 'x', 'profile_id': 0, 'open_id': 'x'}, {'id': 'x', 'profile_id': 1.5, 'open_id': 'x'}]) {
      expect(StudyCallHistoryTarget.parse(bad), isNull);
    }
    final reply = Completer<Object?>();
    final bridge = StudyCallHistoryBridge(supported: true, takePending: () => reply.future,
      onOpen: (_) async { opens++; });
    final pending = bridge.checkPending(); bridge.dispose(); reply.complete(raw); await pending;
    expect(opens, 0);
  });
}
