import 'package:cupitor/webview_file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  FileSelectorParams params(FileSelectorMode mode) => FileSelectorParams(
      isCaptureEnabled: false, acceptTypes: const ['.json', 'application/json'], mode: mode);

  test('JSON upload opens the picker and returns an encoded file URI', () async {
    var opened = false;
    final result = await pickWebViewFiles(params(FileSelectorMode.open), pickPaths: (multiple) async {
      opened = true; expect(multiple, false);
      return ['/data/cache/Swedish calls å.json', '/data/cache/second.json'];
    });
    expect(opened, true);
    expect(result, [Uri.file('/data/cache/Swedish calls å.json').toString()]);
  });

  test('multiple uploads preserve selected document URIs and ignore missing paths', () async {
    final result = await pickWebViewFiles(params(FileSelectorMode.openMultiple), pickPaths: (multiple) async {
      expect(multiple, true);
      return ['content://documents/calls.json', null, '', '/cache/two.json'];
    });
    expect(result, ['content://documents/calls.json', 'file:///cache/two.json']);
  });

  test('cancel and picker failure settle without leaving a pending chooser', () async {
    var errors = 0;
    expect(await pickWebViewFiles(params(FileSelectorMode.open), pickPaths: (_) async => []), isEmpty);
    expect(await pickWebViewFiles(params(FileSelectorMode.open), pickPaths: (_) async => throw Exception('picker'),
        onError: () => errors++), isEmpty);
    expect(errors, 1);
    expect(await pickWebViewFiles(params(FileSelectorMode.save), pickPaths: (_) async => fail('unexpected picker')), isEmpty);
  });
}
