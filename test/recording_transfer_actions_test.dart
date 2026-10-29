import 'package:cupitor/recording_transfer_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('import is available on an empty device; export needs clips', (
    tester,
  ) async {
    var imports = 0, exports = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              RecordingTransferActions(
                selectedCount: 0,
                totalCount: 0,
                busy: false,
                onImport: () => imports++,
                onExport: () => exports++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Import recordings'));
    expect(imports, 1);
    final export = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.file_download_outlined),
    );
    expect(export.onPressed, isNull);
    expect(exports, 0);
  });
  testWidgets(
    'selection exports selected clips and busy state disables actions',
    (tester) async {
      var exports = 0;
      Future<void> show({required bool busy, required int selected}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                appBar: AppBar(
                  actions: [
                    RecordingTransferActions(
                      selectedCount: selected,
                      totalCount: 4,
                      busy: busy,
                      onImport: () {},
                      onExport: () => exports++,
                    ),
                  ],
                ),
              ),
            ),
          );
      await show(busy: false, selected: 2);
      expect(find.byTooltip('Import recordings'), findsNothing);
      await tester.tap(find.byTooltip('Export selected recordings'));
      expect(exports, 1);
      await show(busy: true, selected: 0);
      for (final button in tester.widgetList<IconButton>(
        find.byType(IconButton),
      )) {
        expect(button.onPressed, isNull);
      }
      await show(busy: false, selected: 0);
      await tester.tap(find.byTooltip('Export all recordings'));
      expect(exports, 2);
    },
  );
}
