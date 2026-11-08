import 'dart:convert';

import 'package:flutter/services.dart';

/// The browser-style Find shortcut on desktop. Shift+Cmd/Ctrl+F remains
/// available to pages that use it for a different search command.
bool isDesktopFindShortcut({
  required LogicalKeyboardKey key,
  required bool metaPressed,
  required bool controlPressed,
  bool altPressed = false,
  bool shiftPressed = false,
}) =>
    key == LogicalKeyboardKey.keyF &&
    (metaPressed || controlPressed) &&
    !altPressed &&
    !shiftPressed;

/// WKWebView and other native platform views can consume keys before Flutter
/// receives a KeyEvent. Listen in the page too and forward only the shortcut,
/// keeping the actual Find UI and search state in the Flutter host.
const String kDesktopFindShortcutJs = r'''
(function() {
  if (window.__cupitorFindShortcutInstalled) return;
  window.__cupitorFindShortcutInstalled = true;
  document.addEventListener('keydown', function(event) {
    if (event.isComposing || event.repeat || event.altKey || event.shiftKey ||
        !(event.metaKey || event.ctrlKey) ||
        String(event.key).toLowerCase() !== 'f') return;
    if (typeof FindInPageShortcut === 'undefined' ||
        typeof FindInPageShortcut.postMessage !== 'function') return;
    event.preventDefault();
    event.stopImmediatePropagation();
    FindInPageShortcut.postMessage('open');
  }, true);
})();
''';


/// Enter / Shift+Enter navigate without submitting or closing the field.
int findEnterDirection(LogicalKeyboardKey key, {bool shiftPressed = false}) {
  if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) {
    return 0;
  }
  return shiftPressed ? -1 : 1;
}

/// Browser-standard next/previous shortcuts.
int findNavigationDirection({
  required LogicalKeyboardKey key,
  required bool metaPressed,
  required bool controlPressed,
  bool altPressed = false,
  bool shiftPressed = false,
}) {
  if (altPressed) return 0;
  if (key == LogicalKeyboardKey.f3 && !metaPressed && !controlPressed) {
    return shiftPressed ? -1 : 1;
  }
  if (key == LogicalKeyboardKey.keyG && (metaPressed || controlPressed)) {
    return shiftPressed ? -1 : 1;
  }
  return 0;
}

class FindMatchState {
  const FindMatchState({required this.current, required this.total, this.searching = false});
  final int current;
  final int total;
  final bool searching;

  String get label => searching ? 'Searching…' : total == 0 ? 'No matches' : '$current of $total';

  static const empty = FindMatchState(current: 0, total: 0);
}

/// WebKit returns JSON text, while Android may add another layer of quoting.
FindMatchState parseFindMatchState(Object? raw) {
  Object? value = raw;
  for (var i = 0; i < 2 && value is String; i++) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return FindMatchState.empty;
    }
  }
  if (value is! Map) return FindMatchState.empty;
  final total = (value['total'] as num?)?.toInt() ?? 0;
  final current = (value['current'] as num?)?.toInt() ?? 0;
  if (total <= 0) return FindMatchState.empty;
  return FindMatchState(current: current.clamp(1, total).toInt(), total: total);
}

/// Search the displayed document without moving keyboard focus out of the
/// Flutter Find field. Report the selected match and total to the host.
/// Active matches have a vivid orange fill and blue outline; other matches
/// remain yellow. Search wraps in both directions.
String pageFindJavaScript(String query, {bool navigate = true, bool forward = true}) {
  final encoded = jsonEncode(query);
  return '''
(function() {
  var query = $encoded;
  var navigate = %%NAVIGATE%%;
  var forward = %%FORWARD%%;
  function clear() {
    document.querySelectorAll('mark._fh').forEach(function(mark) {
      if (!mark.parentNode) return;
      var parent = mark.parentNode;
      parent.replaceChild(document.createTextNode(mark.textContent || ''), mark);
      parent.normalize();
    });
    window._findMarks = [];
    window._findIdx = -1;
  }
  if (!query || !document.body) {
    clear();
    window._findQuery = '';
    return JSON.stringify({current: 0, total: 0});
  }
  var rebuilding = window._findQuery !== query ||
    !Array.isArray(window._findMarks) ||
    window._findMarks.some(function(mark) { return !mark.isConnected; });
  if (rebuilding) {
    clear();
    window._findQuery = query;
    var lower = query.toLowerCase();
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    var textNode, matches = [];
    while ((textNode = walker.nextNode())) {
      var parent = textNode.parentElement;
      if (!parent || !parent.isConnected ||
          parent.closest('script,style,noscript,textarea,select,option,mark._fh,[contenteditable="true"],[hidden],[aria-hidden="true"]')) continue;
      var style = getComputedStyle(parent);
      if (style.display === 'none' || style.visibility === 'hidden' || !parent.getClientRects().length) continue;
      var haystack = (textNode.textContent || '').toLowerCase();
      var offset = 0, at;
      while ((at = haystack.indexOf(lower, offset)) !== -1) {
        matches.push({node: textNode, start: at, length: query.length});
        offset = at + Math.max(1, query.length);
      }
    }
    // Reverse insertion preserves the original text offsets.
    for (var i = matches.length - 1; i >= 0; i--) {
      var match = matches[i];
      if (!match.node.parentNode) continue;
      var range = document.createRange();
      range.setStart(match.node, match.start);
      range.setEnd(match.node, match.start + match.length);
      var mark = document.createElement('mark');
      mark.className = '_fh';
      range.surroundContents(mark);
    }
    window._findMarks = Array.from(document.querySelectorAll('mark._fh'));
    window._findIdx = forward ? 0 : window._findMarks.length - 1;
  } else if (navigate && window._findMarks.length) {
    window._findIdx = (window._findIdx + (forward ? 1 : -1) +
      window._findMarks.length) % window._findMarks.length;
  }
  var marks = window._findMarks;
  marks.forEach(function(mark) {
    mark.style.setProperty('background-color', '#ffe066', 'important');
    mark.style.setProperty('color', '#111', 'important');
    mark.style.removeProperty('box-shadow');
    mark.style.removeProperty('border-radius');
  });
  if (!marks.length) return JSON.stringify({current: 0, total: 0});
  var current = marks[window._findIdx];
  current.style.setProperty('background-color', '#ff7518', 'important');
  current.style.setProperty('color', '#111', 'important');
  current.style.setProperty('box-shadow', '0 0 0 2px #155eef', 'important');
  current.style.setProperty('border-radius', '2px', 'important');
  current.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'auto'});
  return JSON.stringify({current: window._findIdx + 1, total: marks.length});
})()
'''.replaceAll('%%NAVIGATE%%', navigate ? 'true' : 'false')
   .replaceAll('%%FORWARD%%', forward ? 'true' : 'false');
}

/// Clean up every highlight on close or empty query.
const String kClearFindJavaScript = r'''
(function() {
  document.querySelectorAll('mark._fh').forEach(function(mark) {
    if (!mark.parentNode) return;
    var parent = mark.parentNode;
    parent.replaceChild(document.createTextNode(mark.textContent || ''), mark);
    parent.normalize();
  });
  window._findQuery = '';
  window._findIdx = -1;
  window._findMarks = [];
})()
''';
