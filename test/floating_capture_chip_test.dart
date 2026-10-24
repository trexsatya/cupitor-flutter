import 'package:cupitor/tag_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const portrait = Size(430, 932);
  const landscape = Size(932, 430);
  const portraitPadding = EdgeInsets.only(top: 24, bottom: 24);
  const landscapePadding = EdgeInsets.only(left: 32, bottom: 24);
  const captureKey = ValueKey('capture');
  const noteKey = ValueKey('video-note');
  const studyKey = ValueKey('study');
  final taps = <String>[];
  final moved = <Offset>[];

  Future<void> pump(
    WidgetTester tester, {
    Size size = portrait,
    EdgeInsets padding = portraitPadding,
    bool fullscreen = false,
    bool capture = true,
    Offset notePosition = const Offset(-1, -1),
  }) async {
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, padding: padding),
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => taps.add('video'),
                    child: ColoredBox(
                      color: fullscreen ? Colors.black : Colors.white,
                    ),
                  ),
                ),
                if (capture)
                  TagCaptureFloatingChip(
                    key: captureKey,
                    armed: true,
                    initialPos: const Offset(-1, -1),
                    onTap: () => taps.add('capture'),
                    onHide: () => taps.add('hide-capture'),
                    onMoved: moved.add,
                  ),
                TagCaptureFloatingChip(
                  key: noteKey,
                  armed: true,
                  armedIcon: Icons.edit_note,
                  initialPos: notePosition.dx >= 0
                      ? notePosition
                      : Offset(
                          size.width - 64,
                          size.height - padding.bottom - 208,
                        ),
                  onTap: () => taps.add('note'),
                  onHide: () => taps.add('hide-note'),
                  onMoved: moved.add,
                ),
                TagCaptureFloatingChip(
                  key: studyKey,
                  armed: true,
                  armedIcon: Icons.fullscreen,
                  initialPos: Offset(
                    size.width - 64,
                    size.height - padding.bottom - 272,
                  ),
                  onTap: () => taps.add('study'),
                  onHide: () => taps.add('hide-study'),
                  onMoved: moved.add,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Rect chipRect(WidgetTester tester, Key key) => tester.getRect(
    find.descendant(
      of: find.byKey(key),
      matching: find.byType(GestureDetector),
    ),
  );

  void expectVisible(WidgetTester tester, Size size, EdgeInsets padding) {
    final safe = Rect.fromLTRB(
      padding.left,
      padding.top,
      size.width - padding.right,
      size.height - padding.bottom,
    );
    final rects = [captureKey, noteKey, studyKey]
        .where((key) => find.byKey(key).evaluate().isNotEmpty)
        .map((key) => chipRect(tester, key))
        .toList();
    for (final rect in rects) {
      expect(rect.left, greaterThanOrEqualTo(safe.left));
      expect(rect.top, greaterThanOrEqualTo(safe.top));
      expect(rect.right, lessThanOrEqualTo(safe.right));
      expect(rect.bottom, lessThanOrEqualTo(safe.bottom));
    }
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(
          rects[i].overlaps(rects[j]),
          isFalse,
          reason: 'Fullscreen controls must not cover each other',
        );
      }
    }
  }

  setUp(() {
    taps.clear();
    moved.clear();
  });

  testWidgets(
    'capture and study buttons remain visible and tappable in fullscreen',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester);
      final before = [
        captureKey,
        noteKey,
        studyKey,
      ].map((key) => chipRect(tester, key)).toList();
      await pump(
        tester,
        size: landscape,
        padding: landscapePadding,
        fullscreen: true,
      );
      expectVisible(tester, landscape, landscapePadding);
      for (final key in [captureKey, noteKey, studyKey]) {
        await tester.tap(find.byKey(key));
      }
      await tester.tapAt(const Offset(100, 100));
      expect(taps, ['capture', 'note', 'study', 'video']);
      expect(
        moved,
        isEmpty,
        reason: 'Relayout must not be reported as a user drag',
      );
      await pump(tester);
      expect(
        [
          captureKey,
          noteKey,
          studyKey,
        ].map((key) => chipRect(tester, key)).toList(),
        before,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragged controls stay inside landscape cutouts and can still move',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester);
      await tester.drag(find.byKey(noteKey), const Offset(-300, -500));
      await tester.pump();
      final before = chipRect(tester, noteKey);
      await pump(
        tester,
        size: landscape,
        padding: landscapePadding,
        fullscreen: true,
      );
      expectVisible(tester, landscape, landscapePadding);
      await tester.drag(find.byKey(noteKey), const Offset(-1000, -1000));
      await tester.pump();
      expect(chipRect(tester, noteKey).topLeft, const Offset(32, 0));
      await tester.drag(find.byKey(noteKey), const Offset(80, 80));
      await tester.pump();
      expect(chipRect(tester, noteKey).left, greaterThan(32));
      expect(chipRect(tester, noteKey).top, greaterThan(0));
      expect(moved, isNotEmpty);
      expect(before.topLeft, isNot(chipRect(tester, noteKey).topLeft));
      await tester.tap(find.byKey(noteKey));
      expect(taps, ['note']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved positions outside the viewport are brought back on screen',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(
        tester,
        size: landscape,
        padding: landscapePadding,
        notePosition: const Offset(2000, 2000),
        capture: false,
      );
      final rect = chipRect(tester, noteKey);
      expect(rect.right, landscape.width);
      expect(rect.bottom, landscape.height - landscapePadding.bottom);
      await tester.tap(find.byKey(noteKey));
      expect(taps, ['note']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hiding another control preserves the study button position', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester);
    await tester.drag(find.byKey(studyKey), const Offset(-200, -100));
    await tester.pump();
    final position = chipRect(tester, studyKey);
    await pump(tester, capture: false);
    expect(chipRect(tester, studyKey), position);
    await tester.tap(find.byKey(studyKey));
    expect(taps, ['study']);
    expect(tester.takeException(), isNull);
  });
}
