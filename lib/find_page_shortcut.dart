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
