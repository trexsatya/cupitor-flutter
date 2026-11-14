import 'package:flutter/services.dart';

const double desktopToolbarMinWidth = 720;

enum DesktopBrowserShortcut {
  address('L', LogicalKeyboardKey.keyL, 'Focus the address bar'),
  reload('R', LogicalKeyboardKey.keyR, 'Reload the page'),
  addBookmark('D', LogicalKeyboardKey.keyD, 'Bookmark the current page'),
  bookmarks('B', LogicalKeyboardKey.keyB, 'Open Bookmarks'),
  tools(',', LogicalKeyboardKey.comma, 'Open Tools');

  const DesktopBrowserShortcut(this.label, this.key, this.description);

  final String label;
  final LogicalKeyboardKey key;
  final String description;
}

DesktopBrowserShortcut? desktopBrowserShortcutForKey(
  LogicalKeyboardKey key, {
  required bool macOS,
  required bool metaPressed,
  required bool controlPressed,
  required bool altPressed,
  required bool shiftPressed,
}) {
  final primaryPressed = macOS
      ? metaPressed && !controlPressed
      : controlPressed && !metaPressed;
  if (!primaryPressed || altPressed || shiftPressed) {
    return null;
  }
  for (final action in DesktopBrowserShortcut.values) {
    if (key == action.key) return action;
  }
  return null;
}
