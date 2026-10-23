import 'package:file_picker/file_picker.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Android WebView has no built-in file chooser. Return the files explicitly
/// chosen by the user as URIs; a cancelled or failed picker returns no files.
/// Use all-files mode so providers that label JSON as text/octet-stream still
/// show it. The requesting page remains responsible for validating its input.
Future<List<String>> pickWebViewFiles(
  FileSelectorParams params, {
  Future<List<String?>> Function(bool multiple)? pickPaths,
  void Function()? onError,
}) async {
  if (params.mode == FileSelectorMode.save) return const [];
  try {
    final multiple = params.mode == FileSelectorMode.openMultiple;
    final List<String?> paths;
    if (pickPaths != null) {
      paths = await pickPaths(multiple);
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: multiple,
        withData: false,
      );
      paths = result?.files.map((file) => file.path).toList() ?? const [];
    }
    final uris = paths.whereType<String>().where((path) => path.isNotEmpty)
        .map((path) => path.startsWith('content://') || path.startsWith('file://')
            ? path : Uri.file(path).toString());
    return (multiple ? uris : uris.take(1)).toList();
  } catch (_) {
    onError?.call();
    return const [];
  }
}
