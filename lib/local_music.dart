/// Helpers for the background-music files the user picks from the device.
///
/// Pure — no Flutter, no I/O — so the two decisions that matter can be unit
/// tested: what the copy is called, and whether a `file://` URL the page hands
/// back really names a file inside the directory it claims to.
library;

/// A filename the copy can safely carry.
///
/// The basename only, with the characters Android's filesystem or a URL path
/// would choke on replaced. Letters in any script are kept on purpose — a
/// track called `Калинка.mp3` stays readable in the panel and on disk.
String musicSafeFileName(String original) {
  final base = original.replaceAll('\\', '/').split('/').last;
  var cleaned = base
      .replaceAll(RegExp(r'[\x00-\x1f:*?"<>|%#]'), '_')
      .trim();
  // A leading dot hides the file and breaks the stem/extension split.
  cleaned = cleaned.replaceFirst(RegExp(r'^\.+'), '');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'track';
  return cleaned;
}

/// The display name a track starts with: the filename without its extension.
String musicDisplayName(String pathOrName) {
  final base = pathOrName.replaceAll('\\', '/').split('/').last;
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  return stem.isEmpty ? base : stem;
}

/// `("Song", ".mp3")` for `Song.mp3`; `("Song", "")` when there is no
/// extension. A leading dot is not an extension.
(String, String) musicSplitExt(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return (fileName, '');
  return (fileName.substring(0, dot), fileName.substring(dot));
}

/// The on-disk path a `file://` URL names, if — and only if — it is a file
/// directly inside [dirPath]. Null for anything else.
///
/// `..` segments are collapsed BEFORE the check, so
/// `file://<dir>/../elsewhere/x` is refused rather than waved through by a
/// prefix test. Nested paths are refused too: nothing this app writes lives in
/// a subdirectory, so a request for one is not ours.
String? filePathInsideDir(String url, String dirPath) {
  if (!url.startsWith('file://')) return null;
  final raw = url.substring('file://'.length);
  if (raw.isEmpty) return null;
  final String path;
  final String dir;
  try {
    path = Uri.file(raw).normalizePath().toFilePath();
    dir = Uri.directory(dirPath).normalizePath().toFilePath();
  } catch (_) {
    return null;
  }
  if (!path.startsWith(dir)) return null;
  final rest = path.substring(dir.length);
  if (rest.isEmpty || rest.contains('/')) return null;
  return path;
}
