import 'package:cupitor/stable_dialog_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bodyKey = ValueKey('page');
  const barKey = ValueKey('bar');

  Widget fixture({
    ValueNotifier<bool>? hold,
    ValueNotifier<int>? activity,
    VoidCallback? press,
  }) => MaterialApp(
    home: Scaffold(
      body: StableDialogChrome(
        holdVisible: hold,
        activity: activity,
        toolbar: SizedBox(
          key: barKey,
          height: 40,
          child: TextButton(
            onPressed: press ?? () {},
            child: const Text('Close'),
          ),
        ),
        child: const SizedBox.expand(key: bodyKey),
      ),
    ),
  );

  testWidgets(
    'idle and tap change opacity without moving or resizing the page',
    (tester) async {
      await tester.pumpWidget(fixture());
      final before = tester.getRect(find.byKey(bodyKey));
      final toolbar = tester.getRect(find.byKey(barKey));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      expect(tester.getRect(find.byKey(bodyKey)), before);
      expect(tester.getRect(find.byKey(barKey)), toolbar);
      await tester.tapAt(before.center);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      expect(tester.getRect(find.byKey(bodyKey)), before);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('tap on an invisible button only reveals the bar', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(fixture(press: () => presses++));
    final button = tester.getCenter(find.text('Close'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(button);
    await tester.pumpAndSettle();
    expect(presses, 0);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    await tester.tapAt(button);
    await tester.pump();
    expect(presses, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an open study menu holds the toolbar past the idle timeout', (
    tester,
  ) async {
    final menuOpen = ValueNotifier(false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StableDialogChrome(
            menuOpen: menuOpen,
            toolbar: MenuAnchor(
              onOpen: () => menuOpen.value = true,
              onClose: () => menuOpen.value = false,
              menuChildren: [
                MenuItemButton(onPressed: () {}, child: const Text('Reload')),
              ],
              builder: (_, controller, _) => TextButton(
                onPressed: () => controller.open(),
                child: const Text('Study tools'),
              ),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Study tools'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Reload'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
          .opacity,
      1,
    );
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
          .opacity,
      0,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    menuOpen.dispose();
  });

  testWidgets(
    'voice capture and held pointers keep controls visible; JS activity reveals them',
    (tester) async {
      final hold = ValueNotifier(true);
      final activity = ValueNotifier(0);
      await tester.pumpWidget(fixture(hold: hold, activity: activity));
      await tester.pump(const Duration(seconds: 5));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      hold.value = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      activity.value++;
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(bodyKey)),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await gesture.up();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      hold.dispose();
      activity.dispose();
    },
  );
}
