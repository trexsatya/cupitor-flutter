import 'dart:io';
import 'dart:typed_data';

import 'package:cupitor/snippet_log_export.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

class _Picker extends FilePicker {
  String? path;
  String? title;
  String? filename;
  void Function()? whileOpen;
  bool fail = false;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    title = dialogTitle;
    filename = fileName;
    if (fail) throw const FileSystemException('Picker unavailable');
    whileOpen?.call();
    return path;
  }
}

void main() {
  late Directory tmp;
  late _Picker picker;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cupitor_log_');
    picker = _Picker()..path = '${tmp.path}/snippet.txt';
    FilePicker.platform = picker;
  });
  tearDown(() async => tmp.delete(recursive: true));

  test(
    'saves all visible lines as UTF-8 without including later messages',
    () async {
      final entries = [
        '[12:34:56] [log] Åäö – sökning',
        '[12:34:57] [warn] Second',
      ];
      picker.whileOpen = () => entries.add('Arrived while choosing the file');
      final path = await saveSnippetLog(entries);
      expect(
        await File(path!).readAsString(),
        '[12:34:56] [log] Åäö – sökning\n[12:34:57] [warn] Second\n',
      );
      expect(picker.title, 'Save snippet log');
      expect(picker.filename, matches(r'^cupitor-snippet-[0-9T.\-]+\.txt$'));
    },
  );

  test('cancelling creates no file', () async {
    picker.path = null;
    expect(await saveSnippetLog(['Keep this log']), isNull);
    expect(tmp.listSync(), isEmpty);
  });

  test(
    'save errors reach the caller so the log screen can report failure',
    () async {
      picker.fail = true;
      await expectLater(
        saveSnippetLog(['Error log']),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
