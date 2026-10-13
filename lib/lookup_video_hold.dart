/// Holds the page's videos while the lookup dialog (dialog1) is over them.
///
/// A word tap or a subtitle send from the main page opens dialog1 on top of
/// whatever is playing. [kHoldVideosForLookupJs] pauses every video that is
/// playing at that moment and remembers exactly those; when dialog1 goes away
/// [kReleaseVideosAfterLookupJs] plays them again. A video that was already
/// paused is never touched, so closing the dialog does not start something the
/// user had stopped.
///
/// Page scripts can tell these pauses and plays apart from the user's:
///   * `video.__cupLookupHeld` is true on a video this paused, until release;
///   * `video.__cupLookupResuming` is true while release's play is starting;
///   * `window.__cupLookupHold` is true from hold to release, and the window
///     gets `cupitorLookupHold` / `cupitorLookupRelease` events at each end.
/// The caption sidebar in snippet.js uses them so a held pause does not count
/// as the user pausing, and so it waits for release instead of playing behind
/// the dialog.
library;

// Every <video> in the page and its same-origin iframes.
const String _videosJs = '''
function __cupLookupVideos() {
  var out = [].slice.call(document.querySelectorAll('video'));
  var frames = document.querySelectorAll('iframe');
  for (var i = 0; i < frames.length; i++) {
    try {
      var d = frames[i].contentDocument;
      if (d) out = out.concat([].slice.call(d.querySelectorAll('video')));
    } catch (e) {}
  }
  return out;
}
''';

/// Pauses every playing video and remembers them for release. Running it again
/// before release adds whatever has started playing since.
const String kHoldVideosForLookupJs = '''
(function () {
  $_videosJs
  var held = window.__cupLookupHeld || [];
  __cupLookupVideos().forEach(function (v) {
    if (v.paused || v.ended) return;
    // Marked before pausing: the pause event reads it.
    v.__cupLookupHeld = true;
    try { v.pause(); } catch (e) { v.__cupLookupHeld = false; return; }
    if (held.indexOf(v) < 0) held.push(v);
  });
  window.__cupLookupHeld = held;
  window.__cupLookupHold = true;
  try { window.dispatchEvent(new CustomEvent('cupitorLookupHold')); } catch (e) {}
})()
''';

/// Plays what [kHoldVideosForLookupJs] paused, unless it has left the page or
/// is no longer paused. Safe to run with nothing held.
const String kReleaseVideosAfterLookupJs = '''
(function () {
  var held = window.__cupLookupHeld || [];
  window.__cupLookupHeld = [];
  window.__cupLookupHold = false;
  held.forEach(function (v) {
    // Cleared a task later: hold's pause event may still be on its way, and
    // it must still read as held when it arrives.
    setTimeout(function () { v.__cupLookupHeld = false; }, 0);
    if (!v.isConnected || !v.paused || v.ended) return;
    // Marked before playing: the play event reads it.
    v.__cupLookupResuming = true;
    try {
      var p = v.play();
      if (p && p.catch) p.catch(function () { v.__cupLookupResuming = false; });
    } catch (e) { v.__cupLookupResuming = false; }
  });
  try { window.dispatchEvent(new CustomEvent('cupitorLookupRelease')); } catch (e) {}
})()
''';
