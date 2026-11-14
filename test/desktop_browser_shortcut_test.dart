import 'package:cupitor/desktop_browser_shortcut.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop actions use Command on Mac and Ctrl elsewhere', () {
    for (final macOS in [true, false]) {
      for (final action in DesktopBrowserShortcut.values) {
        expect(
          desktopBrowserShortcutForKey(
            action.key,
            macOS: macOS,
            metaPressed: macOS,
            controlPressed: !macOS,
            altPressed: false,
            shiftPressed: false,
          ),
          action,
        );
      }
    }
  });

  test('alternate modifiers and Find are left to their own handlers', () {
    DesktopBrowserShortcut? lookup(
      LogicalKeyboardKey key, {
      bool meta = true,
      bool ctrl = false,
      bool alt = false,
      bool shift = false,
    }) => desktopBrowserShortcutForKey(
      key,
      macOS: true,
      metaPressed: meta,
      controlPressed: ctrl,
      altPressed: alt,
      shiftPressed: shift,
    );

    expect(lookup(LogicalKeyboardKey.keyB, meta: false), isNull);
    expect(lookup(LogicalKeyboardKey.keyB, meta: false, ctrl: true), isNull);
    expect(lookup(LogicalKeyboardKey.keyB, ctrl: true), isNull);
    expect(lookup(LogicalKeyboardKey.keyB, alt: true), isNull);
    expect(lookup(LogicalKeyboardKey.keyB, shift: true), isNull);
    expect(lookup(LogicalKeyboardKey.keyF), isNull);
  });
}
