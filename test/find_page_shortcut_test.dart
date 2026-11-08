import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/find_page_shortcut.dart';

void main() {
  test('Cmd+F and Ctrl+F open page Find', () {
    expect(isDesktopFindShortcut(
      key: LogicalKeyboardKey.keyF, metaPressed: true, controlPressed: false), isTrue);
    expect(isDesktopFindShortcut(
      key: LogicalKeyboardKey.keyF, metaPressed: false, controlPressed: true), isTrue);
  });

  test('unrelated shortcuts are not claimed', () {
    expect(isDesktopFindShortcut(
      key: LogicalKeyboardKey.keyF, metaPressed: false, controlPressed: false), isFalse);
    expect(isDesktopFindShortcut(
      key: LogicalKeyboardKey.keyG, metaPressed: true, controlPressed: false), isFalse);
    expect(isDesktopFindShortcut(
      key: LogicalKeyboardKey.keyF, metaPressed: true, controlPressed: false, shiftPressed: true), isFalse);
    expect(isDesktopFindShortcut(
      key: LogicalKeyboardKey.keyF, metaPressed: false, controlPressed: true, altPressed: true), isFalse);
  });

  test('web view fallback detects both platform modifiers', () {
    expect(kDesktopFindShortcutJs, contains('event.metaKey || event.ctrlKey'));
    expect(kDesktopFindShortcutJs, contains("event.preventDefault()"));
    expect(kDesktopFindShortcutJs, contains("FindInPageShortcut.postMessage('open')"));
  });
}
