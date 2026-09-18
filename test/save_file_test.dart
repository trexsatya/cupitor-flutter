// saveBytesToPickedFile has to satisfy two pickers that disagree: the mobile
// one writes the file and demands the bytes, the desktop one only names a
// path and refuses bytes outright.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cupitor/save_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker extends FilePicker {
  _FakePicker({this.chosenPath, this.refuseBytes = false});

  final String? chosenPath;

  /// macOS: passing bytes is an error, and the file is never written.
  final bool refuseBytes;

  int calls = 0;
  Uint8List? sawBytes;
  String? sawFileName;

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
    calls++;
    if (refuseBytes && bytes != null) {
      throw UnsupportedError('Bytes are not supported on macOS');
    }
    sawBytes = bytes;
    sawFileName = fileName;
    return chosenPath;
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cupitor_save_file');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('desktop: the picker is asked for a path only, and we write the bytes',
      () async {
    final target = '${tmp.path}/page.html';
    final picker = _FakePicker(chosenPath: target, refuseBytes: true);
    FilePicker.platform = picker;

    final saved = await saveBytesToPickedFile(
      dialogTitle: 'Save page HTML',
      fileName: 'page.html',
      bytes: Uint8List.fromList('<html>å</html>'.codeUnits),
      pickerWrites: false,
    );

    expect(saved, target);
    expect(picker.sawBytes, isNull, reason: 'macOS throws when given bytes');
    expect(File(target).readAsBytesSync(), '<html>å</html>'.codeUnits);
  });

  test('mobile: the bytes go to the picker, which writes the file itself',
      () async {
    final target = '${tmp.path}/page.html';
    final picker = _FakePicker(chosenPath: target);
    FilePicker.platform = picker;

    final saved = await saveBytesToPickedFile(
      dialogTitle: 'Save page HTML',
      fileName: 'page.html',
      bytes: Uint8List.fromList([1, 2, 3]),
      pickerWrites: true,
    );

    expect(saved, target);
    expect(picker.sawBytes, [1, 2, 3]);
    expect(File(target).existsSync(), isFalse,
        reason: 'the real picker writes it; we must not write it twice');
  });

  test('a cancelled dialog writes nothing and reports nothing', () async {
    final picker = _FakePicker(chosenPath: null, refuseBytes: true);
    FilePicker.platform = picker;

    final saved = await saveBytesToPickedFile(
      dialogTitle: 'Save page HTML',
      fileName: 'page.html',
      bytes: Uint8List.fromList([1, 2, 3]),
      pickerWrites: false,
    );

    expect(saved, isNull);
    expect(picker.calls, 1);
    expect(tmp.listSync(), isEmpty);
  });

  test('on this host the platform default matches the picker it will meet',
      () async {
    final target = '${tmp.path}/page.html';
    // The tests run on macOS/Linux, where the real picker throws if handed
    // bytes — so a wrong default surfaces here as that same throw.
    final picker = _FakePicker(chosenPath: target, refuseBytes: true);
    FilePicker.platform = picker;

    final saved = await saveBytesToPickedFile(
      dialogTitle: 'Save page HTML',
      fileName: 'page.html',
      bytes: utf8.encode('x'),
    );

    expect(saved, target);
    expect(picker.sawBytes, isNull);
  });

  test('non-ASCII text round-trips as the UTF-8 the caller encoded', () async {
    final target = '${tmp.path}/page.html';
    FilePicker.platform = _FakePicker(chosenPath: target, refuseBytes: true);

    const html = '<html>färg — ÅÄÖ</html>';
    await saveBytesToPickedFile(
      dialogTitle: 'Save page HTML',
      fileName: 'page.html',
      bytes: utf8.encode(html),
    );

    expect(File(target).readAsStringSync(encoding: utf8), html);
  });

  test('a path that cannot be written reports the failure', () async {
    FilePicker.platform =
        _FakePicker(chosenPath: '${tmp.path}/no/such/dir/page.html',
            refuseBytes: true);

    expect(
      () => saveBytesToPickedFile(
        dialogTitle: 'Save page HTML',
        fileName: 'page.html',
        bytes: utf8.encode('x'),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
