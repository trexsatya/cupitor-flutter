import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/native_recording_start.dart';

void main() {
  test('one pending or active recorder excludes another start', () {
    final starts = NativeRecordingStart();
    final first = starts.begin(recording: false)!;
    expect(starts.isPending, true);
    expect(starts.begin(recording: false), isNull);
    expect(starts.complete(first), true);
    expect(starts.isPending, false);
    expect(starts.begin(recording: true), isNull);
  });

  test('cancel during a permission/platform await invalidates that start', () async {
    final starts = NativeRecordingStart();
    final first = starts.begin(recording: false)!;
    var nativeStarts = 0;
    Future<void> continueStart() async {
      await Future<void>.value();
      if (!starts.isCurrent(first)) return;
      nativeStarts++;
    }
    final pending = continueStart();
    starts.cancel();
    await pending;
    expect(nativeStarts, 0);
    expect(starts.complete(first), false);
  });

  test('a cancelled completion cannot clear a newer pending start', () {
    final starts = NativeRecordingStart();
    final first = starts.begin(recording: false)!;
    starts.cancel();
    final second = starts.begin(recording: false)!;
    expect(starts.complete(first), false);
    expect(starts.isCurrent(second), true);
    expect(starts.complete(second), true);
    expect(starts.complete(second), false);
  });
}
