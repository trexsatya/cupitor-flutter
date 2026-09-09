import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/recording_selection.dart';

void main() {
  group('toggleSelection', () {
    test('adds then removes', () {
      var s = toggleSelection(<String>{}, 'a');
      expect(s, {'a'});
      s = toggleSelection(s, 'b');
      expect(s, {'a', 'b'});
      s = toggleSelection(s, 'a');
      expect(s, {'b'});
    });

    test('does not mutate the set it was given', () {
      final original = {'a'};
      final next = toggleSelection(original, 'b');
      expect(original, {'a'});
      expect(next, {'a', 'b'});
    });

    test('emptying reads as "no longer selecting"', () {
      // The screen derives selection mode from emptiness, so this is the
      // exit path, not just a state change.
      final s = toggleSelection({'a'}, 'a');
      expect(s, isEmpty);
    });
  });

  group('selectAllOrNone', () {
    const all = ['a', 'b', 'c'];

    test('from nothing selects everything', () {
      expect(selectAllOrNone(<String>{}, all), {'a', 'b', 'c'});
    });

    test('from a partial selection selects everything', () {
      expect(selectAllOrNone({'b'}, all), {'a', 'b', 'c'});
    });

    test('from everything clears', () {
      expect(selectAllOrNone({'a', 'b', 'c'}, all), isEmpty);
    });

    test('ignores stale ids when deciding it is already full', () {
      // A selection carrying an id that is no longer listed must still count
      // as "all of them" so the toggle clears rather than re-selecting.
      expect(selectAllOrNone({'a', 'b', 'c', 'gone'}, all), isEmpty);
    });

    test('an empty list has nothing to select', () {
      expect(selectAllOrNone({'a'}, const []), isEmpty);
    });
  });

  group('pruneSelection', () {
    test('drops ids that are gone', () {
      expect(pruneSelection({'a', 'b'}, const ['b', 'c']), {'b'});
    });

    test('keeps everything still present', () {
      expect(pruneSelection({'a', 'b'}, const ['a', 'b', 'c']), {'a', 'b'});
    });

    test('an empty selection stays empty', () {
      expect(pruneSelection(<String>{}, const ['a']), isEmpty);
    });

    test('everything vanishing clears the selection', () {
      expect(pruneSelection({'a'}, const []), isEmpty);
    });
  });

  group('DeleteTally', () {
    test('a clean run does not mention failures', () {
      const t = DeleteTally(removed: 3, failed: 0);
      expect(t.allSucceeded, isTrue);
      expect(t.message, 'Removed 3 recording(s)');
      expect(t.message, isNot(contains('failed')));
    });

    test('a partial failure reports both counts', () {
      const t = DeleteTally(removed: 2, failed: 1);
      expect(t.allSucceeded, isFalse);
      expect(t.message, 'Removed 2 — 1 failed');
    });

    test('a total failure still reports', () {
      const t = DeleteTally(removed: 0, failed: 4);
      expect(t.message, 'Removed 0 — 4 failed');
    });
  });

  group('deleteConfirmBody', () {
    test('reads naturally for one clip', () {
      final s = deleteConfirmBody(1, '12 KB');
      expect(s, contains('this clip (12 KB)'));
      expect(s, contains('reference it will lose'));
    });

    test('reads naturally for several', () {
      final s = deleteConfirmBody(4, '1.2 MB');
      expect(s, contains('all 4 clips (1.2 MB)'));
      expect(s, contains('reference any of these will lose'));
    });
  });
}
