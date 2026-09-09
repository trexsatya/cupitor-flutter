/// In-page probe for diagnosing "this won't scroll" reports.
///
/// The probe answers, in order, the three questions that separate a host
/// (Flutter / platform-view) problem from a page (CSS / JS) problem:
///
///  1. Does the page receive the touch at all? If no `DOWN` line appears when
///     you drag, the WebView never got the gesture — that is host-side, and
///     nothing in the page can be at fault.
///  2. Is page JavaScript cancelling the scroll? The probe listens on
///     `document` in the capture phase (before page handlers) and on `window`
///     in the bubble phase (after them), so a `defaultPrevented` that flips
///     between the two pins the blame on a page handler.
///  3. Is CSS/layout the reason? It walks the ancestor chain under the finger
///     reporting `overflow-y`, `position`, `touch-action`, `pointer-events`
///     and `scrollHeight/clientHeight`, and flags any full-viewport
///     fixed/sticky element sitting on top of the touch point.
///
/// Every listener is registered `passive: true`, so the probe can never
/// itself change whether the page scrolls. Output goes to `SnippetLogChannel`
/// at level `scroll`, i.e. into the existing "View snippet logs" screen.
library;

import 'dart:convert';

/// Log level the probe posts under, so the log viewer groups its output.
const String kScrollDiagLogLevel = 'scroll';

/// JS that calls the probe's one-shot snapshot. Safe if the probe is absent.
const String scrollDiagSnapshotJs =
    'window.__cupScrollDiag && window.__cupScrollDiag.snapshot();';

/// Installs the probe (idempotent) and sets its enabled flag.
///
/// [tag] labels the WebView the output came from (`main`, `dialog1`), since
/// both report into the same log.
String scrollDiagnosticsJs({required bool enabled, required String tag}) {
  return '$_installer\n'
      'if (window.__cupScrollDiag) {\n'
      '  window.__cupScrollDiag.tag = ${jsonEncode(tag)};\n'
      '  window.__cupScrollDiag.setEnabled(${enabled ? 'true' : 'false'});\n'
      '}\n';
}

const String _installer = r'''
(function () {
  if (window.__cupScrollDiag) return;
  var S = window.__cupScrollDiag = { on: false, tag: '?', seq: 0, last: null };

  function post(msg) {
    try { SnippetLogChannel.postMessage('scroll|[' + S.tag + '] ' + msg); } catch (e) {}
  }
  S.post = post;

  function desc(el) {
    if (!el) return '(none)';
    if (el === document.documentElement) return 'html';
    if (el === document.body) return 'body';
    var s = el.tagName ? el.tagName.toLowerCase() : '?';
    if (el.id) s += '#' + el.id;
    var c = (typeof el.className === 'string') ? el.className.trim() : '';
    if (c) s += '.' + c.split(/\s+/).slice(0, 3).join('.');
    return s;
  }

  // CSS overflow propagation: the viewport takes its overflow from <html>,
  // unless html computes to `visible`, in which case it is taken from <body>
  // instead. So the usual modal lock — `body { overflow: hidden }` with html
  // left alone — makes the whole document unscrollable even though html still
  // computes to `visible`. Reading html's own value would report the document
  // as scrollable when the user cannot scroll it at all.
  function viewportOverflowY() {
    try {
      var hy = getComputedStyle(document.documentElement).overflowY;
      if (hy !== 'visible') return hy;
      var b = document.body;
      return b ? getComputedStyle(b).overflowY : 'visible';
    } catch (e) { return 'visible'; }
  }
  S.viewportOverflowY = viewportOverflowY;

  // "Can a drag here actually move this box right now?" — needs both an
  // overflow that allows scrolling AND content taller than the box.
  function scrollableY(el) {
    try {
      var de = document.documentElement;
      if (el === de || el === document.body || el === document.scrollingElement) {
        // These all drive the one viewport scroller.
        var vy = viewportOverflowY();
        if (vy === 'hidden' || vy === 'clip') return false;
        var se = document.scrollingElement || de;
        return se.scrollHeight > se.clientHeight + 1;
      }
      var oy = getComputedStyle(el).overflowY;
      return (oy === 'auto' || oy === 'scroll' || oy === 'overlay')
        && el.scrollHeight > el.clientHeight + 1;
    } catch (e) { return false; }
  }
  S.scrollableY = scrollableY;

  function nearestScrollable(el) {
    var n = 0;
    while (el && n++ < 15) {
      if (scrollableY(el)) return el;
      el = el.parentElement;
    }
    return null;
  }

  function chain(el) {
    var out = [], n = 0;
    while (el && n++ < 12) {
      var cs;
      try { cs = getComputedStyle(el); } catch (e) { break; }
      out.push(desc(el)
        + ' {oy:' + cs.overflowY
        + ' pos:' + cs.position
        + ' ta:' + (cs.touchAction || '-')
        + ' pe:' + cs.pointerEvents
        + ' sh/ch:' + el.scrollHeight + '/' + el.clientHeight
        + (scrollableY(el) ? ' SCROLLABLE' : '') + '}');
      el = el.parentElement;
    }
    return out.join('\n       -> ');
  }
  S.chain = chain;

  // A full-viewport fixed/sticky element on top of the touch point that
  // cannot itself scroll is the classic invisible backdrop eating the drag.
  function coverAt(x, y) {
    var el = document.elementFromPoint(x, y), n = 0;
    while (el && n++ < 12) {
      var cs;
      try { cs = getComputedStyle(el); } catch (e) { break; }
      if (cs.position === 'fixed' || cs.position === 'sticky') {
        var r = el.getBoundingClientRect();
        if (r.width >= innerWidth * 0.9 && r.height >= innerHeight * 0.9) {
          return desc(el) + ' (' + cs.position + ', '
            + Math.round(r.width) + 'x' + Math.round(r.height)
            + ', scrollable=' + scrollableY(el) + ')';
        }
      }
      el = el.parentElement;
    }
    return null;
  }

  S.snapshot = function () {
    try {
      var pt = S.last
        || { x: Math.round(innerWidth / 2), y: Math.round(innerHeight / 2) };
      var de = document.documentElement, b = document.body;
      var dcs = getComputedStyle(de), bcs = b ? getComputedStyle(b) : null;
      var se = document.scrollingElement || de;
      var vv = window.visualViewport;
      var at = document.elementFromPoint(pt.x, pt.y);
      var lines = [
        '--- snapshot at (' + pt.x + ',' + pt.y + ')'
          + (S.last ? ' [last touch]' : ' [viewport centre]'),
        'url   ' + String(location.href).slice(0, 140),
        'html  oy:' + dcs.overflowY
          + ' inline:' + (de.style.overflow || de.style.overflowY || '-')
          + ' transform:' + dcs.transform
          + ' zoom:' + (dcs.zoom || '-'),
        'body  oy:' + (bcs ? bcs.overflowY : '-')
          + ' inline:' + (b ? (b.style.overflow || b.style.overflowY || '-') : '-')
          + ' pos:' + (bcs ? bcs.position : '-')
          + ' height:' + (bcs ? bcs.height : '-'),
        'root  ' + desc(se) + ' scrollTop:' + se.scrollTop
          + ' sh/ch:' + se.scrollHeight + '/' + se.clientHeight
          + (scrollableY(se) ? ' SCROLLABLE' : ' NOT-SCROLLABLE'),
        'vpoy  ' + viewportOverflowY()
          + (scrollableY(se) ? '' : ' — DOCUMENT SCROLL LOCKED'),
        'view  layout:' + de.clientWidth + 'x' + de.clientHeight
          + ' inner:' + innerWidth + 'x' + innerHeight
          + (vv ? ' visual:' + Math.round(vv.width) + 'x' + Math.round(vv.height)
                  + ' scale:' + vv.scale.toFixed(4) : ''),
      ];
      // The layout viewport is what fixed-position boxes and the compositor's
      // hit-testing use. When the page is zoomed out these diverge, and a page
      // that sizes a floating panel from innerWidth/innerHeight builds it
      // bigger than the box it is actually positioned in.
      if (vv && Math.abs(vv.scale - 1) > 0.01) {
        lines.push('!! PAGE SCALE ' + vv.scale.toFixed(4)
          + ' — layout viewport is ' + de.clientWidth + 'x' + de.clientHeight
          + ' but window.inner* reports ' + innerWidth + 'x' + innerHeight
          + '; anything sized from innerWidth/innerHeight overflows the box'
          + ' fixed elements are laid out in. Suspect this first.');
      }
      var cov = coverAt(pt.x, pt.y);
      if (cov) lines.push('COVERED BY ' + cov);
      var sc = nearestScrollable(at);
      lines.push('nearest scrollable under point: ' + (sc ? desc(sc) : 'NONE'));
      lines.push('chain: ' + chain(at));
      post(lines.join('\n  '));
    } catch (e) { post('snapshot failed: ' + e); }
  };

  var g = null;

  document.addEventListener('touchstart', function (e) {
    if (!S.on) return;
    try {
      var t = (e.touches && e.touches[0]) || {};
      var x = Math.round(t.clientX || 0), y = Math.round(t.clientY || 0);
      S.last = { x: x, y: y };
      var el = document.elementFromPoint(x, y);
      var se = document.scrollingElement || document.documentElement;
      var sc = nearestScrollable(el);
      g = {
        id: ++S.seq, el: el, y0: y,
        root0: se.scrollTop, sc: sc, sc0: sc ? sc.scrollTop : null,
        moves: 0, dy: 0, prevented: false, cancelable: null,
      };
      post('DOWN #' + g.id + ' at (' + x + ',' + y + ') on ' + desc(el)
        + ' nearestScrollable:' + (sc ? desc(sc) : 'NONE'));
    } catch (err) { post('touchstart probe failed: ' + err); }
  }, { capture: true, passive: true });

  // Capture phase on document: runs BEFORE page handlers.
  document.addEventListener('touchmove', function (e) {
    if (!S.on || !g) return;
    if (g.cancelable === null) g.cancelable = e.cancelable;
  }, { capture: true, passive: true });

  // Bubble phase on window: runs AFTER page handlers, so defaultPrevented
  // here means a page handler cancelled the scroll.
  window.addEventListener('touchmove', function (e) {
    if (!S.on || !g) return;
    g.moves++;
    var t = (e.touches && e.touches[0]) || {};
    g.dy = Math.max(g.dy, Math.abs((t.clientY || 0) - g.y0));
    if (e.defaultPrevented) g.prevented = true;
  }, { capture: false, passive: true });

  function end() {
    if (!g) return;
    if (!S.on) { g = null; return; }
    try {
      var se = document.scrollingElement || document.documentElement;
      var rootMoved = se.scrollTop !== g.root0;
      var scMoved = !!(g.sc && g.sc.scrollTop !== g.sc0);
      var verdict;
      if (g.moves === 0) {
        verdict = 'NO touchmove reached the page — the host swallowed the drag '
          + '(Flutter / platform-view side, not the page)';
      } else if (g.dy < 8) {
        verdict = 'finger barely moved (dy=' + g.dy + ') — inconclusive, drag further';
      } else if (rootMoved || scMoved) {
        verdict = 'scrolled OK (' + (scMoved ? desc(g.sc) : 'root') + ')';
      } else if (g.prevented) {
        verdict = 'BLOCKED BY PAGE JS — a touchmove handler called preventDefault';
      } else if (!g.sc) {
        verdict = 'BLOCKED BY CSS/LAYOUT — nothing under the finger is scrollable: '
          + 'no ancestor pairs overflow-y auto/scroll with content taller than its box';
      } else {
        verdict = 'delivered and not prevented, but ' + desc(g.sc)
          + ' did not move';
        var vv = window.visualViewport;
        var de = document.documentElement;
        if (vv && Math.abs(vv.scale - 1) > 0.01) {
          // The compositor picks the scroll layer using the layout viewport.
          // Zoomed out, the coordinates the page reasons about no longer sit
          // inside it, so the gesture latches onto the root scroller — which
          // a modal's body-scroll lock has usually pinned. Hence: touch
          // delivered, gesture consumed (cancelable:false), nothing moves.
          verdict += ' — PAGE SCALE ' + vv.scale.toFixed(4)
            + ': layout viewport is only ' + de.clientWidth + 'x' + de.clientHeight
            + ' while the page sees ' + innerWidth + 'x' + innerHeight
            + '. Suspect the zoom-out, not the scroll container.';
        } else {
          verdict += ' — check nested scroll containers / transforms';
        }
      }
      post('UP   #' + g.id + ' moves:' + g.moves + ' dy:' + g.dy
        + ' cancelable:' + g.cancelable + ' prevented:' + g.prevented
        + ' rootMoved:' + rootMoved + ' scMoved:' + scMoved
        + '\n  => ' + verdict
        + '\n  chain: ' + chain(g.el));
    } catch (err) { post('touchend probe failed: ' + err); }
    g = null;
  }
  document.addEventListener('touchend', end, { capture: false, passive: true });
  document.addEventListener('touchcancel', end, { capture: false, passive: true });

  S.setEnabled = function (on) {
    var was = S.on;
    S.on = !!on;
    g = null;
    if (S.on && !was) {
      post('probe armed — drag on the stuck area now. '
        + 'If no DOWN line follows, the page never received the touch.');
    } else if (!S.on && was) {
      post('probe disarmed');
    }
  };
})();
''';
