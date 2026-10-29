import 'local_music.dart';

/// IDs and extensions written by the native/WebView recorders. A restored
/// filename is an identity, so reject unsafe names rather than renaming them.
bool validRecordingFileName(String name) =>
    name.length <= 255 &&
    RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]*\.[A-Za-z0-9_-]+$').hasMatch(name) &&
    !name.contains('..');

/// Old cards contain absolute file URLs. After restoring audio onto another
/// device, resolve only their manual_audio basename into this device's store.
/// The same resolver is used for playback and deletion.
String? recordingPathFromUrl(String url, String directory) {
  final local = filePathInsideDir(url, directory);
  if (local != null) return local;
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'file' ||
      (uri.host.isNotEmpty && uri.host != 'localhost') ||
      uri.hasQuery ||
      uri.hasFragment ||
      !uri.path.startsWith('/')) {
    return null;
  }
  final parts = uri.pathSegments;
  if (parts.length < 2 ||
      parts.contains('..') ||
      parts.contains('.') ||
      parts[parts.length - 2] != 'manual_audio' ||
      !validRecordingFileName(parts.last)) {
    return null;
  }
  final root = directory.endsWith('/') ? directory : '$directory/';
  return '$root${parts.last}';
}
