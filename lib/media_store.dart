import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Content-addressed store for media attachments (image / audio / video).
///
/// Files live under `<app_docs>/sentence_media/<sha1[0..2]>/<sha1><ext>`.
/// Splitting into 256 first-two-char buckets keeps any single directory
/// from getting huge. Files are shared across sentences that attach the
/// same content — the DB row (`sentence_media`) references the sha1 and
/// [CupitorDb.deleteMediaReturningOrphanSha1] returns the hash only when
/// the *last* row goes away, so callers can gc the file.
class MediaStore {
  MediaStore._();
  static final MediaStore instance = MediaStore._();

  static const String _rootDirName = 'sentence_media';

  Future<Directory> _rootDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_rootDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> fileForSha1(String sha1Hex, {String? extension}) async {
    final root = await _rootDir();
    final bucket = Directory('${root.path}/${sha1Hex.substring(0, 2)}');
    if (!await bucket.exists()) {
      await bucket.create(recursive: true);
    }
    final ext = extension == null || extension.isEmpty ? '' : '.$extension';
    return File('${bucket.path}/$sha1Hex$ext');
  }

  /// Copies [src] into the store, keyed by its content SHA-1. If the
  /// destination file already exists (someone attached the same bytes
  /// before), the copy is a no-op. Returns the metadata needed to write
  /// the `sentence_media` row.
  Future<StoredMediaInfo> ingest(File src, {String? originalFilename}) async {
    // Compute the hash first — small overhead vs the peace of mind of
    // content-addressed storage. For very large files this streams
    // efficiently through the crypto sink.
    final digest = await sha1.bind(src.openRead()).first;
    final sha1Hex = digest.toString();
    final ext = _extensionFromName(originalFilename ?? src.path);
    final dst = await fileForSha1(sha1Hex, extension: ext);
    if (!await dst.exists()) {
      await src.copy(dst.path);
    }
    return StoredMediaInfo(
      sha1: sha1Hex,
      filePath: dst.path,
      originalFilename: _basename(originalFilename ?? src.path),
      extension: ext,
      sizeBytes: await dst.length(),
    );
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    final bs = path.lastIndexOf('\\');
    final cut = slash > bs ? slash : bs;
    return cut < 0 ? path : path.substring(cut + 1);
  }

  /// Resolve an existing store entry to a File. Returns null if the
  /// file is missing on disk (broken row — caller should tolerate).
  Future<File?> resolve(String sha1Hex, {String? extension}) async {
    final f = await fileForSha1(sha1Hex, extension: extension);
    if (await f.exists()) return f;
    // If the caller didn't know the extension, try to guess by scanning
    // the bucket for any file whose stem matches the hash. Slower path,
    // used only when the extension is unknown at call time.
    if (extension == null || extension.isEmpty) {
      final bucketPath = f.path.substring(0, f.path.lastIndexOf('/'));
      final bucket = Directory(bucketPath);
      if (!await bucket.exists()) return null;
      await for (final entry in bucket.list()) {
        final base = _basename(entry.path);
        final dot = base.indexOf('.');
        final stem = dot < 0 ? base : base.substring(0, dot);
        if (stem == sha1Hex && entry is File) return entry;
      }
    }
    return null;
  }

  /// Delete the on-disk file for a hash. Idempotent — no-op if missing.
  Future<void> deleteFile(String sha1Hex, {String? extension}) async {
    final f = await resolve(sha1Hex, extension: extension);
    if (f != null && await f.exists()) {
      try { await f.delete(); } catch (_) {}
    }
  }

  static String kindFromMime(String? mime, String? ext) {
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('image/')) return 'image';
    if (m.startsWith('audio/')) return 'audio';
    if (m.startsWith('video/')) return 'video';
    // Fall back to extension-based detection.
    final e = (ext ?? '').toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    const image = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'};
    const audio = {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac', 'oga', 'opus'};
    const video = {'mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp', 'avi'};
    if (image.contains(e)) return 'image';
    if (audio.contains(e)) return 'audio';
    if (video.contains(e)) return 'video';
    return 'image'; // safest visual fallback
  }

  /// Best-effort kind detection for a URL — we can only look at the
  /// path extension, since we never fetch. Returns 'link' when nothing
  /// media-like is recognisable, so the UI can pick a generic icon
  /// instead of pretending it's an image.
  static String kindFromUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return 'link';
    Uri? uri;
    try {
      uri = Uri.parse(trimmed);
    } catch (_) {
      return 'link';
    }
    final path = uri.path;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'link';
    final ext = path.substring(dot + 1).toLowerCase();
    // Route through kindFromMime for the extension tables — same set of
    // recognised extensions, plus its fallback is 'image' which we
    // override to 'link' when nothing matched.
    const image = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'};
    const audio = {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac', 'oga', 'opus'};
    const video = {'mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp', 'avi'};
    if (image.contains(ext)) return 'image';
    if (audio.contains(ext)) return 'audio';
    if (video.contains(ext)) return 'video';
    return 'link';
  }

  static String _extensionFromName(String name) {
    final base = _basename(name);
    final dot = base.lastIndexOf('.');
    if (dot < 0 || dot == base.length - 1) return '';
    return base.substring(dot + 1).toLowerCase();
  }

  /// Compute the on-disk size (kB) of a stored file if we can find it.
  Future<int?> sizeOf(String sha1Hex, {String? extension}) async {
    final f = await resolve(sha1Hex, extension: extension);
    if (f == null) return null;
    return f.length();
  }

  /// Every file currently in the store, keyed by its SHA-1 stem. Used
  /// by the media manager to reconcile disk state against the DB and
  /// surface orphaned files for cleanup.
  Future<Map<String, File>> listAllFiles() async {
    final root = await _rootDir();
    final out = <String, File>{};
    if (!await root.exists()) return out;
    await for (final bucket in root.list()) {
      if (bucket is! Directory) continue;
      await for (final f in bucket.list()) {
        if (f is! File) continue;
        final base = _basename(f.path);
        final dot = base.indexOf('.');
        final stem = dot < 0 ? base : base.substring(0, dot);
        if (stem.length == 40) out[stem] = f; // sha1 hex length
      }
    }
    return out;
  }

  /// Delete every file in the store whose SHA-1 is not in [referenced].
  /// Returns the number of files removed. Safe to call whenever — the
  /// content-addressed layout means we never delete something a live
  /// row still points at.
  Future<int> deleteOrphans(Set<String> referenced) async {
    final files = await listAllFiles();
    var removed = 0;
    for (final entry in files.entries) {
      if (referenced.contains(entry.key)) continue;
      try {
        await entry.value.delete();
        removed++;
      } catch (_) { /* best effort */ }
    }
    return removed;
  }
}

/// Return value from [MediaStore.ingest] — enough for the caller to
/// write the corresponding `sentence_media` row.
class StoredMediaInfo {
  final String sha1;
  final String filePath;
  final String originalFilename;
  final String extension;
  final int sizeBytes;
  const StoredMediaInfo({
    required this.sha1,
    required this.filePath,
    required this.originalFilename,
    required this.extension,
    required this.sizeBytes,
  });
}

/// Utility for JSON-serialising a media row for display (used by the
/// capture sheet's temporary state before it hits the DB).
String encodeStoredMediaInfo(StoredMediaInfo info) => jsonEncode({
      'sha1': info.sha1,
      'filePath': info.filePath,
      'originalFilename': info.originalFilename,
      'extension': info.extension,
      'sizeBytes': info.sizeBytes,
    });

/// Image compression settings + one-shot compressor. Presets balance
/// perceived quality against on-disk footprint; the "original" preset
/// short-circuits so users who don't care about size see no change.
enum ImageCompressionPreset { original, high, medium, low }

class ImageCompressionSpec {
  final int quality; // JPEG quality 0..100
  final int maxDim;  // Longest edge in pixels
  final String label;
  const ImageCompressionSpec({
    required this.quality,
    required this.maxDim,
    required this.label,
  });
}

const Map<ImageCompressionPreset, ImageCompressionSpec> kCompressionSpecs = {
  ImageCompressionPreset.original: ImageCompressionSpec(
      quality: 100, maxDim: 999999, label: 'Original (no compression)'),
  ImageCompressionPreset.high: ImageCompressionSpec(
      quality: 85, maxDim: 1920, label: 'High (85%, ≤1920 px)'),
  ImageCompressionPreset.medium: ImageCompressionSpec(
      quality: 70, maxDim: 1280, label: 'Medium (70%, ≤1280 px)'),
  ImageCompressionPreset.low: ImageCompressionSpec(
      quality: 50, maxDim: 800, label: 'Low (50%, ≤800 px)'),
};

ImageCompressionPreset parseCompressionPreset(String? s) {
  switch (s) {
    case 'high': return ImageCompressionPreset.high;
    case 'medium': return ImageCompressionPreset.medium;
    case 'low': return ImageCompressionPreset.low;
    case 'original':
    default:
      return ImageCompressionPreset.original;
  }
}

String encodeCompressionPreset(ImageCompressionPreset p) {
  switch (p) {
    case ImageCompressionPreset.high: return 'high';
    case ImageCompressionPreset.medium: return 'medium';
    case ImageCompressionPreset.low: return 'low';
    case ImageCompressionPreset.original: return 'original';
  }
}

/// Detect image-ness from filename extension. Non-image files are
/// never touched by the compressor — the picker also allows A/V and
/// those pass through unchanged.
bool isImageExtension(String ext) {
  const set = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'};
  return set.contains(ext.toLowerCase());
}

class _CompressJob {
  final Uint8List bytes;
  final int quality;
  final int maxDim;
  const _CompressJob(this.bytes, this.quality, this.maxDim);
}

/// Runs on a worker isolate via [compute]. Decodes, resizes, encodes
/// as JPEG. Returns null on unsupported formats so the caller can fall
/// back to the original bytes.
Uint8List? _compressBytesIsolate(_CompressJob job) {
  final decoded = img.decodeImage(job.bytes);
  if (decoded == null) return null;
  img.Image out = decoded;
  final longest = decoded.width >= decoded.height ? decoded.width : decoded.height;
  if (longest > job.maxDim) {
    if (decoded.width >= decoded.height) {
      out = img.copyResize(decoded, width: job.maxDim);
    } else {
      out = img.copyResize(decoded, height: job.maxDim);
    }
  }
  return Uint8List.fromList(img.encodeJpg(out, quality: job.quality));
}

/// One-shot compression helper. Reads the source, runs the encoder in
/// a background isolate, writes a `.jpg` under the OS temp dir, and
/// returns the temp file. Caller passes it straight to
/// [MediaStore.ingest]; the temp file can be discarded once the store
/// has hashed and copied it into the content-addressed layout.
///
/// Returns the source unchanged when the preset is [ImageCompressionPreset.original],
/// the file isn't an image, or decoding fails.
Future<File> maybeCompressImage(
  File source, {
  required ImageCompressionPreset preset,
  required String originalFilename,
}) async {
  if (preset == ImageCompressionPreset.original) return source;
  final ext = originalFilename.contains('.')
      ? originalFilename.substring(originalFilename.lastIndexOf('.') + 1).toLowerCase()
      : '';
  if (!isImageExtension(ext)) return source;
  try {
    final bytes = await source.readAsBytes();
    final spec = kCompressionSpecs[preset]!;
    final compressed = await compute(
      _compressBytesIsolate,
      _CompressJob(bytes, spec.quality, spec.maxDim),
    );
    if (compressed == null || compressed.length >= bytes.length) {
      // Decoder failed OR compression yielded a larger file (tiny
      // images sometimes do). Fall back to the original.
      return source;
    }
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final out = File('${tmp.path}/cupitor_compress_$stamp.jpg');
    await out.writeAsBytes(compressed, flush: true);
    return out;
  } catch (_) {
    // Anything went wrong — pass the source through untouched so the
    // user's attachment still lands, just uncompressed.
    return source;
  }
}

/// Format a byte count for the "Book media" indicator. Compact style
/// (e.g. "3.2 MB", "812 KB") — no trailing zeros.
String formatBytes(int n) {
  const units = ['B', 'KB', 'MB', 'GB'];
  double v = n.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++; }
  final s = v >= 100 ? v.toStringAsFixed(0)
      : v >= 10 ? v.toStringAsFixed(1)
      : v.toStringAsFixed(2);
  return '$s ${units[u]}';
}
