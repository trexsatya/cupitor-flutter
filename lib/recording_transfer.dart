import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'recording_urls.dart';

const maxRecordingBundleBytes = 512 * 1024 * 1024;
const maxRecordingFileBytes = 128 * 1024 * 1024;
const maxRecordingBundleFiles = 10000;

class RecordingImportResult {
  const RecordingImportResult(this.imported, this.unchanged, this.conflicts);
  final int imported;
  final int unchanged;
  final List<String> conflicts;

  String get message =>
      'Imported $imported recording(s); $unchanged already present'
      '${conflicts.isEmpty ? '' : '; ${conflicts.length} name conflict(s) — existing audio kept'}';
}

/// Portable audio bundle. Filenames identify the existing cards' attachments;
/// card/playlist definitions continue to use the existing webapp sync/export.
class RecordingTransfer {
  static Future<Uint8List> exportBundle({
    required Directory directory,
    required Iterable<String> names,
  }) async {
    final wanted = names.toSet().toList()..sort();
    if (wanted.isEmpty) {
      throw const FormatException('Select at least one recording.');
    }
    if (wanted.length > maxRecordingBundleFiles) {
      throw const FormatException('Too many recordings.');
    }
    final files = <Map<String, Object>>[];
    var total = 0;
    for (final name in wanted) {
      if (!validRecordingFileName(name)) {
        throw FormatException('Invalid recording filename: $name');
      }
      final file = File('${directory.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FormatException(
          'Recording is missing or is not a regular file: $name',
        );
      }
      final stat = await file.stat();
      total += stat.size;
      if (stat.size > maxRecordingFileBytes ||
          total > maxRecordingBundleBytes) {
        throw const FormatException(
          'Recording bundle is too large. Export fewer clips.',
        );
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != stat.size) {
        throw FormatException('Recording changed while exporting: $name');
      }
      files.add({
        'name': name,
        'bytes': bytes,
        'modified': stat.modified.millisecondsSinceEpoch,
      });
    }
    return Isolate.run(() => _encodeBundle(files));
  }

  static Future<RecordingImportResult> importBundle({
    required Directory directory,
    required Uint8List bytes,
  }) async {
    if (bytes.length > maxRecordingBundleBytes) {
      throw const FormatException('Recording bundle is too large.');
    }
    // Validate every entry and checksum before touching the destination.
    final files = await Isolate.run(() => _decodeBundle(bytes));
    await directory.create(recursive: true);
    final stage = await directory.createTemp('.recordings-import-');
    final created = <File>[];
    final conflicts = <String>[];
    var unchanged = 0;
    try {
      for (final row in files) {
        final name = row['name'] as String;
        final file = File('${stage.path}/$name');
        await file.writeAsBytes(row['bytes'] as Uint8List, flush: true);
        await file.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(row['modified'] as int),
        );
      }
      for (final row in files) {
        final name = row['name'] as String;
        final target = File('${directory.path}/$name');
        final type = await FileSystemEntity.type(
          target.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound) {
          if (type == FileSystemEntityType.file &&
              await target.length() == (row['bytes'] as Uint8List).length &&
              sha256.convert(await target.readAsBytes()).toString() ==
                  row['sha256']) {
            unchanged++;
          } else {
            conflicts.add(name);
          }
          continue;
        }
        final restored = await File('${stage.path}/$name').rename(target.path);
        created.add(restored);
      }
      return RecordingImportResult(
        created.length,
        unchanged,
        List.unmodifiable(conflicts),
      );
    } catch (_) {
      // A failed write must not leave a half-imported collection behind.
      for (final file in created.reversed) {
        await file.delete();
      }
      rethrow;
    } finally {
      await stage.delete(recursive: true);
    }
  }
}

Uint8List _encodeBundle(List<Map<String, Object>> files) {
  final archive = Archive();
  final recordings = <Map<String, Object>>[];
  for (final row in files) {
    final name = row['name'] as String;
    final bytes = row['bytes'] as Uint8List;
    recordings.add({
      'name': name,
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'modified': row['modified']!,
    });
    // Audio containers are already compressed; store them without recompressing.
    archive.addFile(
      ArchiveFile('audio/$name', bytes.length, bytes)..compress = false,
    );
  }
  final manifest = utf8.encode(
    jsonEncode({
      'format': 'cupitor-recordings',
      'version': 1,
      'recordings': recordings,
    }),
  );
  archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
  final encoded = Uint8List.fromList(ZipEncoder().encode(archive)!);
  if (encoded.length > maxRecordingBundleBytes) {
    throw const FormatException('Recording bundle is too large.');
  }
  return encoded;
}

List<Map<String, Object>> _decodeBundle(Uint8List bytes) {
  // Content is inflated lazily. Check declared sizes before reading it.
  final decoder = ZipDecoder();
  final archive = decoder.decodeBytes(bytes);
  if (decoder.directory.fileHeaders.length != archive.length) {
    throw const FormatException('Duplicate recording bundle entries.');
  }
  if (archive.length > maxRecordingBundleFiles + 1) {
    throw const FormatException('Too many recordings.');
  }
  final entries = <String, ArchiveFile>{};
  var total = 0;
  for (final entry in archive) {
    if (!entry.isFile ||
        entry.isSymbolicLink ||
        entries.containsKey(entry.name) ||
        (entry.name != 'manifest.json' &&
            (!entry.name.startsWith('audio/') ||
                !validRecordingFileName(entry.name.substring(6))))) {
      throw const FormatException('Invalid recording bundle entry.');
    }
    total += entry.size;
    final limit = entry.name == 'manifest.json'
        ? 8 * 1024 * 1024
        : maxRecordingFileBytes;
    if (entry.size < 0 ||
        entry.size > limit ||
        total > maxRecordingBundleBytes) {
      throw const FormatException('Recording bundle is too large.');
    }
    entries[entry.name] = entry;
  }
  final manifestFile = entries.remove('manifest.json');
  if (manifestFile == null) {
    throw const FormatException('Not a Cupitor recording bundle.');
  }
  final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));
  if (manifest is! Map ||
      manifest['format'] != 'cupitor-recordings' ||
      manifest['version'] != 1 ||
      manifest['recordings'] is! List) {
    throw const FormatException('Unsupported recording bundle.');
  }
  final result = <Map<String, Object>>[];
  final names = <String>{};
  for (final row in manifest['recordings'] as List) {
    if (row is! Map ||
        row['name'] is! String ||
        row['size'] is! int ||
        row['sha256'] is! String ||
        row['modified'] is! int ||
        (row['modified'] as int).abs() > 8640000000000000 ||
        !validRecordingFileName(row['name'] as String) ||
        !names.add(row['name'] as String)) {
      throw const FormatException('Invalid recording metadata.');
    }
    final entry = entries.remove('audio/${row['name']}');
    if (entry == null || entry.size != row['size']) {
      throw const FormatException('A recording is missing or damaged.');
    }
    final content = Uint8List.fromList(entry.content as List<int>);
    if (content.length != row['size'] ||
        sha256.convert(content).toString() != row['sha256']) {
      throw const FormatException('A recording checksum did not match.');
    }
    result.add({
      'name': row['name'] as String,
      'bytes': content,
      'sha256': row['sha256'] as String,
      'modified': row['modified'] as int,
    });
  }
  if (result.isEmpty || entries.isNotEmpty) {
    throw const FormatException('Invalid or empty recording bundle.');
  }
  return result;
}
