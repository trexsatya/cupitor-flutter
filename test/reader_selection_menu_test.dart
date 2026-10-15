import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupitor/reader_selection_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final calls = <String>[];
  final previewKey = GlobalKey();

  setUpAll(() async {
    final font = Platform.environment['CUPITOR_SCREENSHOT_FONT'];
    if (font != null) {
      final loader = FontLoader('Preview')
        ..addFont(
          File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
    final icons = Platform.environment['CUPITOR_SCREENSHOT_ICONS'];
    if (icons != null) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          File(
            icons,
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });

  Widget menu({Offset anchor = const Offset(195, 130)}) => ReaderSelectionMenu(
    anchor: anchor,
    background: const Color(0xFFF7F7F8),
    foreground: const Color(0xFF202124),
    onDismiss: () => calls.add('dismiss'),
    onLookup: () => calls.add('lookup'),
    onSearch: () => calls.add('search'),
    onHighlight: () => calls.add('highlight'),
    onNote: () => calls.add('note'),
    onCopy: () => calls.add('copy'),
  );

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 200),
    Offset anchor = const Offset(195, 130),
    double textScale = 1,
  }) async {
    calls.clear();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily:
              Platform.environment.containsKey('CUPITOR_SCREENSHOT_FONT')
              ? 'Preview'
              : null,
        ),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: RepaintBoundary(
            key: previewKey,
            child: Material(
              color: Colors.white,
              child: Stack(
                children: [
                  const Positioned(
                    left: 24,
                    top: 24,
                    child: Text(
                      'EPUB / DOCX',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                  ),
                  const Positioned(
                    left: 24,
                    top: 132,
                    child: Text(
                      'Sökbar svensk text.',
                      style: TextStyle(
                        fontSize: 20,
                        backgroundColor: Color(0xFFB6D7FF),
                      ),
                    ),
                  ),
                  Positioned.fill(child: menu(anchor: anchor)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Search and all existing actions dispatch the correct callbacks',
    (tester) async {
      await pump(tester);
      for (final label in ['Lookup', 'Search', 'Highlight', 'Note', 'Copy']) {
        await tester.tap(find.text(label));
        await tester.pump();
      }
      expect(calls, ['lookup', 'search', 'highlight', 'note', 'copy']);
      await tester.tapAt(const Offset(5, 190));
      expect(calls.last, 'dismiss');
    },
  );

  testWidgets('toolbar fits a narrow viewport and large text at either edge', (
    tester,
  ) async {
    for (final anchor in [const Offset(0, 0), const Offset(280, 190)]) {
      await pump(
        tester,
        size: const Size(280, 200),
        anchor: anchor,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-selection-toolbar')),
      );
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(272));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.bottom, lessThanOrEqualTo(192));
    }
  });

  testWidgets('renders the actual reader toolbar for an optional PNG preview', (
    tester,
  ) async {
    final output = Platform.environment['CUPITOR_SELECTION_SCREENSHOT'];
    final shadows = debugDisableShadows;
    try {
      if (output != null) debugDisableShadows = false;
      await pump(tester);
      expect(find.text('Search'), findsOneWidget);
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              previewKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(output).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
    } finally {
      debugDisableShadows = shadows;
    }
  });
}
