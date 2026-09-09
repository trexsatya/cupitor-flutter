import 'package:cupitor/page_zoom.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pageZoomScale', () {
    test('each step is ~15% on top of 1.0', () {
      expect(pageZoomScale(0), 1.0);
      expect(pageZoomScale(2), closeTo(1.3, 1e-9));
      expect(pageZoomScale(-2), closeTo(0.7, 1e-9));
    });

    test('clamps to [0.5, 2.5]', () {
      expect(pageZoomScale(10), 2.5);
      expect(pageZoomScale(-4), 0.5);
    });
  });

  group('pageZoomJs', () {
    // The bug: `transform: scale()` on <html> makes the root element the
    // containing block for every `position: fixed` descendant, so in-page
    // modals size against the document box instead of the viewport and their
    // overflow-y:auto scroll area never overflows — the modal cannot scroll.
    test('never sets a transform on the root element', () {
      for (final level in [-4, -2, -1, 0, 1, 2, 5, 10]) {
        final js = pageZoomJs(level);
        expect(js, isNot(contains('scale(')), reason: 'level $level');
        expect(js, isNot(matches(RegExp(r'transform\s*='))), reason: 'level $level');
        expect(js, isNot(matches(RegExp(r"setProperty\(\s*'transform"))),
            reason: 'level $level');
      }
    });

    test('clears any transform left by a previous implementation', () {
      for (final level in [0, 3]) {
        final js = pageZoomJs(level);
        expect(js, contains("removeProperty('transform')"), reason: 'level $level');
        expect(js, contains("removeProperty('transform-origin')"),
            reason: 'level $level');
      }
    });

    test('applies the zoom via CSS zoom when the level is non-zero', () {
      expect(pageZoomJs(2), contains("setProperty('zoom', '1.3"));
      expect(pageZoomJs(-2), contains("setProperty('zoom', '0.7"));
    });

    test('clears zoom at level 0', () {
      final js = pageZoomJs(0);
      expect(js, contains("removeProperty('zoom')"));
      expect(js, isNot(contains("setProperty('zoom'")));
    });

    test('never applies the width / overflow-x compensation the transform '
        'implementation needed — zoom reflows, so it only breaks layout', () {
      for (final level in [-4, -2, 0, 2, 10]) {
        final js = pageZoomJs(level);
        expect(js, isNot(matches(RegExp(r"style\.width\s*="))), reason: 'level $level');
        expect(js, isNot(matches(RegExp(r'overflowX\s*='))), reason: 'level $level');
        expect(js, contains("removeProperty('width')"), reason: 'level $level');
        expect(js, contains("removeProperty('overflow-x')"), reason: 'level $level');
      }
    });
  });
}
