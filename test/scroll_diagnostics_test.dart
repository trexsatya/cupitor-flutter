import 'package:cupitor/scroll_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('scrollDiagnosticsJs', () {
    test('installer is guarded so re-injection on every page load is safe', () {
      final js = scrollDiagnosticsJs(enabled: true, tag: 'main');
      expect(js, contains('if (window.__cupScrollDiag) return;'));
    });

    test('arms and disarms via the enabled flag', () {
      expect(scrollDiagnosticsJs(enabled: true, tag: 'main'),
          contains('setEnabled(true)'));
      expect(scrollDiagnosticsJs(enabled: false, tag: 'main'),
          contains('setEnabled(false)'));
    });

    test('tag is JSON-escaped — dialog2 tags carry generated ids', () {
      final js = scrollDiagnosticsJs(enabled: true, tag: "d2:o'brien");
      expect(js, contains(r'''"d2:o'brien"'''));
      expect(js, isNot(contains("tag = d2")));
    });

    // The probe exists to observe scrolling, so it must never be able to
    // change it. A non-passive touch listener could cancel a scroll and would
    // make every reading it produces suspect.
    test('every touch listener is registered passive', () {
      final js = scrollDiagnosticsJs(enabled: true, tag: 'main');
      // Slice from each touch registration to the start of the next
      // addEventListener call, so multi-line handler bodies stay intact.
      final calls = RegExp(r"addEventListener\('(\w+)'").allMatches(js).toList();
      final touch = <String, String>{};
      for (var i = 0; i < calls.length; i++) {
        final name = calls[i].group(1)!;
        if (!name.startsWith('touch')) continue;
        final end = i + 1 < calls.length ? calls[i + 1].start : js.length;
        touch['$name@${calls[i].start}'] = js.substring(calls[i].start, end);
      }
      expect(touch, hasLength(5), reason: 'start, 2x move, end, cancel');
      touch.forEach((name, body) {
        expect(body, contains('passive: true'),
            reason: '$name listener must be passive');
      });
    });

    test('listens both before and after page handlers so preventDefault can '
        'be attributed to page JS', () {
      final js = scrollDiagnosticsJs(enabled: true, tag: 'main');
      expect(js, contains("document.addEventListener('touchmove'"));
      expect(js, contains("window.addEventListener('touchmove'"));
      expect(js, contains('capture: true'));
      expect(js, contains('capture: false'));
      expect(js, contains('defaultPrevented'));
    });

    test('reports the three distinguishing verdicts', () {
      final js = scrollDiagnosticsJs(enabled: true, tag: 'main');
      expect(js, contains('NO touchmove reached the page'));
      expect(js, contains('BLOCKED BY PAGE JS'));
      expect(js, contains('BLOCKED BY CSS/LAYOUT'));
    });

    // A page that locks scrolling with `body { overflow: hidden }` leaves
    // html computing to `visible`, so reading html's own overflow reports the
    // document as scrollable when the user cannot move it at all. The probe
    // must apply the propagation rule instead. (Behaviour verified against a
    // real browser; this guards the rule from being refactored out.)
    test('resolves the viewport overflow through the propagation rule', () {
      final js = scrollDiagnosticsJs(enabled: true, tag: 'main');
      expect(js, contains('function viewportOverflowY()'));
      expect(js, contains("if (hy !== 'visible') return hy;"));
      expect(js, contains('DOCUMENT SCROLL LOCKED'));
    });

    // The layout/visual viewport split is what a zoomed-out Android WebView
    // produces, and it is invisible unless reported explicitly.
    test('reports layout vs inner vs visual viewport, and warns on zoom', () {
      final js = scrollDiagnosticsJs(enabled: true, tag: 'main');
      expect(js, contains("'view  layout:'"));
      expect(js, contains('!! PAGE SCALE'));
      expect(js, contains('Math.abs(vv.scale - 1) > 0.01'));
    });

    test('a stalled scroll under page zoom blames the zoom, not the container',
        () {
      final js = scrollDiagnosticsJs(enabled: true, tag: 'main');
      expect(js, contains('Suspect the zoom-out, not the scroll container.'));
    });

    test('posts under the level the log viewer groups on', () {
      expect(scrollDiagnosticsJs(enabled: true, tag: 'main'),
          contains("postMessage('$kScrollDiagLogLevel|"));
    });
  });

  group('scrollDiagSnapshotJs', () {
    test('no-ops when the probe was never installed', () {
      expect(scrollDiagSnapshotJs, startsWith('window.__cupScrollDiag &&'));
    });
  });
}
