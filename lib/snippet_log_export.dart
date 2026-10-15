import 'dart:convert';
import 'dart:typed_data';

import 'save_file.dart';

/// Save the visible log as a UTF-8 text snapshot through the native file picker.
/// New messages arriving while the picker is open belong to the next export.
Future<String?> saveSnippetLog(Iterable<String> entries) {
  final snapshot = List<String>.of(entries);
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final text = snapshot.isEmpty ? '' : '${snapshot.join('\n')}\n';
  return saveBytesToPickedFile(
    dialogTitle: 'Save snippet log',
    fileName: 'cupitor-snippet-$stamp.txt',
    bytes: Uint8List.fromList(utf8.encode(text)),
  );
}
