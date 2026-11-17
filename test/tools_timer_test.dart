import 'package:cupitor/tools_timer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Tools timer keeps its deadline outside the sheet', (
    tester,
  ) async {
    var now = DateTime(2026, 1, 1);
    var completions = 0;
    final timer = ToolsTimer(now: () => now, onFinish: () => completions++);
    addTearDown(timer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolsTimerSheet(timer: timer, onBack: () {}),
        ),
      ),
    );
    await tester.tap(find.text('5 min'));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('05:00'), findsOneWidget);

    now = now.add(const Duration(minutes: 2));
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('03:00'), findsOneWidget);
    now = now.add(const Duration(hours: 1));
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(find.text('03:00'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    now = now.add(const Duration(minutes: 4));
    timer.refresh();
    timer.refresh();
    expect(completions, 1);
    expect(timer.state, ToolsTimerState.finished);
    timer.reset();
    expect(timer.remaining, const Duration(minutes: 5));
  });
}
