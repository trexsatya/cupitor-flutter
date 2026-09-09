/// Page-zoom JavaScript for the main WebView.
///
/// Uses CSS `zoom`, deliberately NOT `transform: scale()`.
///
/// Any non-`none` transform on `<html>` makes the root element the containing
/// block for every `position: fixed` descendant (CSS Transforms Level 1 §3).
/// In-page modals then size against the full document box instead of the
/// viewport, so a `height: 100%` scroll area inside the modal ends up taller
/// than its own content, its `overflow-y: auto` never overflows, and the modal
/// cannot be scrolled at all. The transform also leaves the root's scrollable
/// overflow unextended, which puts the bottom of a scaled-up page out of reach.
///
/// `zoom` reflows layout instead: scroll extents stay correct and fixed
/// elements keep resolving against the viewport. It is also why the width /
/// `overflow-x` compensation the transform version needed at scale < 1 is gone
/// — with a reflow there is no phantom horizontal overflow to hide, and
/// forcing `overflow-x: hidden` on `<body>` would itself suppress legitimate
/// horizontal scrolling.
library;

/// Each zoom step is ~15 % on top of 1.0; the result is clamped to [0.5, 2.5].
double pageZoomScale(int level) =>
    (1.0 + level * 0.15).clamp(0.5, 2.5).toDouble();

/// JS that applies zoom [level] to the current document. Level 0 clears it.
///
/// Both branches also clear the properties the old `transform: scale()`
/// implementation set, so a document that already picked up a transform (an
/// earlier injection on the same page, or a build from before this change)
/// gets cleaned up rather than left with a stale containing block.
String pageZoomJs(int level) {
  final apply = level == 0
      ? "document.documentElement.style.removeProperty('zoom');"
      : "document.documentElement.style.setProperty("
          "'zoom', '${pageZoomScale(level)}');";
  return '''
    $apply
    document.documentElement.style.removeProperty('transform');
    document.documentElement.style.removeProperty('transform-origin');
    if (document.body) {
      document.body.style.removeProperty('width');
      document.body.style.removeProperty('overflow-x');
    }
  ''';
}
