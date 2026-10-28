import 'package:cupitor/main_subtitle_capture_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('YouTube capture stays available without the app bar and follows navigation', (tester) async {
    final address = TextEditingController(text: 'https://m.youtube.com/watch?v=abcdefghijk');
    addTearDown(address.dispose);
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [
      const Positioned.fill(child: ColoredBox(color: Colors.black)),
      MainSubtitleCaptureButton(address: address, onPressed: () => calls++),
    ]))));
    final capture = find.byTooltip('Capture SRT subtitles');
    expect(capture, findsOneWidget);
    await tester.tap(capture);
    expect(calls, 1);
    address.text = 'https://m.youtube.com/';
    await tester.pump();
    expect(capture, findsNothing);
    address.text = 'https://m.youtube.com/shorts/lmnopqrstuv';
    await tester.pump();
    expect(capture, findsOneWidget);
    await tester.tap(capture);
    expect(calls, 2);
  });
}
