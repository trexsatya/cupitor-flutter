import 'package:flutter/material.dart';
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

  test('Enter and Shift+Enter navigate forward/backward', () {
    expect(findEnterDirection(LogicalKeyboardKey.enter), 1);
    expect(findEnterDirection(LogicalKeyboardKey.numpadEnter), 1);
    expect(findEnterDirection(LogicalKeyboardKey.enter, shiftPressed: true), -1);
    expect(findEnterDirection(LogicalKeyboardKey.numpadEnter, shiftPressed: true), -1);
    expect(findEnterDirection(LogicalKeyboardKey.keyF, shiftPressed: true), 0);
  });

  test('F3 and Cmd/Ctrl+G support next/previous, without hijacking other keys', () {
    expect(findNavigationDirection(
      key: LogicalKeyboardKey.f3, metaPressed: false, controlPressed: false), 1);
    expect(findNavigationDirection(
      key: LogicalKeyboardKey.f3, metaPressed: false, controlPressed: false,
      shiftPressed: true), -1);
    expect(findNavigationDirection(
      key: LogicalKeyboardKey.keyG, metaPressed: true, controlPressed: false), 1);
    expect(findNavigationDirection(
      key: LogicalKeyboardKey.keyG, metaPressed: false, controlPressed: true,
      shiftPressed: true), -1);
    expect(findNavigationDirection(
      key: LogicalKeyboardKey.keyG, metaPressed: false, controlPressed: false), 0);
    expect(findNavigationDirection(
      key: LogicalKeyboardKey.keyG, metaPressed: true, controlPressed: false,
      altPressed: true), 0);
  });

  test('match counter handles WebKit, Android and no-results responses', () {
    expect(parseFindMatchState('{"current":2,"total":7}').label, '2 of 7');
    expect(parseFindMatchState('"{\\"current\\":3,\\"total\\":5}"').label, '3 of 5');
    expect(parseFindMatchState(<String, int>{'current': 6, 'total': 6}).label, '6 of 6');
    expect(parseFindMatchState('{"current":0,"total":0}').label, 'No matches');
    expect(parseFindMatchState('broken').label, 'No matches');
    expect(parseFindMatchState('{"current":100,"total":3}').label, '3 of 3');
    expect(const FindMatchState(current:0,total:0,searching:true).label, 'Searching…');
  });

  test('Find JS wraps, highlights active match and excludes editable controls', () {
    final script = pageFindJavaScript('foo"\\\\bar', navigate: false);
    expect(script, contains('var navigate = false;'));
    expect(script, contains('var forward = true;'));
    expect(script, contains('window._findMarks'));
    expect(script, contains("box-shadow', '0 0 0 2px #155eef'"));
    expect(script, contains('[contenteditable="true"]'));
    expect(script, contains('current.scrollIntoView'));
    expect(pageFindJavaScript('foo', forward: false),
      contains('var forward = false;'));
    expect(kClearFindJavaScript, contains("window._findQuery = '';"));
  });

  testWidgets('Enter and Shift+Enter keep the Find text field focused', (tester) async {
    final focusNode = FocusNode();
    final directions = <int>[];
    focusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final direction = findEnterDirection(
        event.logicalKey,
        shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      );
      if (direction == 0) return KeyEventResult.ignored;
      directions.add(direction);
      return KeyEventResult.handled;
    };
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: TextField(
        focusNode: focusNode,
        onEditingComplete: () {},
        onSubmitted: (_) {},
        textInputAction: TextInputAction.search,
      ),
    )));
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(directions, <int>[1, -1]);
    expect(focusNode.hasFocus, isTrue);
  });

  test('web view fallback detects both platform modifiers', () {
    expect(kDesktopFindShortcutJs, contains('event.metaKey || event.ctrlKey'));
    expect(kDesktopFindShortcutJs, contains("event.preventDefault()"));
    expect(kDesktopFindShortcutJs, contains("FindInPageShortcut.postMessage('open')"));
  });
}
