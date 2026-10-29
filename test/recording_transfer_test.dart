import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/recording_transfer.dart';
import 'package:cupitor/recording_urls.dart';

Uint8List bundle(
  Map<String, List<int>> audio, {
  Map<String, Object>? extra,
  void Function(Map<String, Object?>)? editManifest,
}) {
  final manifest = <String, Object?>{
    'format': 'cupitor-recordings',
    'version': 1,
    'recordings': audio.entries
        .map(
          (e) => <String, Object>{
            'name': e.key,
            'size': e.value.length,
            'sha256': sha256.convert(e.value).toString(),
            'modified': 1700000000000,
          },
        )
        .toList(),
  };
  editManifest?.call(manifest);
  final archive = Archive();
  final json = utf8.encode(jsonEncode(manifest));
  archive.addFile(ArchiveFile('manifest.json', json.length, json));
  for (final e in audio.entries)
    archive.addFile(ArchiveFile('audio/${e.key}', e.value.length, e.value));
  for (final e in (extra ?? {}).entries) {
    final data = e.value as List<int>;
    archive.addFile(ArchiveFile(e.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory temp, source, target;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cupitor-recording-transfer-');
    source = await Directory(
      '${temp.path}/source/manual_audio',
    ).create(recursive: true);
    target = Directory('${temp.path}/other-device/manual_audio');
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'selected clips round-trip onto another device with names, bytes and dates intact',
    () async {
      final file = File('${source.path}/card-123.ogg');
      await file.writeAsBytes([0, 255, 1, 2, 3]);
      final modified = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await file.setLastModified(modified);
      await File('${source.path}/unselected.m4a').writeAsBytes([4, 5]);
      final bytes = await RecordingTransfer.exportBundle(
        directory: source,
        names: ['card-123.ogg'],
      );
      final result = await RecordingTransfer.importBundle(
        directory: target,
        bytes: bytes,
      );
      expect(result.imported, 1);
      final restored = File('${target.path}/card-123.ogg');
      expect(await restored.readAsBytes(), [0, 255, 1, 2, 3]);
      expect(
        (await restored.lastModified()).millisecondsSinceEpoch,
        modified.millisecondsSinceEpoch,
      );
      expect(await File('${target.path}/unselected.m4a').exists(), false);
      final oldCardUrl = 'file://${file.path}';
      expect(recordingPathFromUrl(oldCardUrl, target.path), restored.path);
    },
  );

  test(
    'reimport skips identical audio and keeps different audio with the same name',
    () async {
      final bytes = bundle({
        'same.ogg': [1, 2],
        'conflict.m4a': [3, 4],
        'new.webm': [5, 6],
      });
      await target.create(recursive: true);
      await File('${target.path}/same.ogg').writeAsBytes([1, 2]);
      await File('${target.path}/conflict.m4a').writeAsBytes([8, 9]);
      final result = await RecordingTransfer.importBundle(
        directory: target,
        bytes: bytes,
      );
      expect(result.imported, 1);
      expect(result.unchanged, 1);
      expect(result.conflicts, ['conflict.m4a']);
      expect(await File('${target.path}/conflict.m4a').readAsBytes(), [8, 9]);
      final again = await RecordingTransfer.importBundle(
        directory: target,
        bytes: bytes,
      );
      expect(again.imported, 0);
      expect(again.unchanged, 2);
      expect(again.conflicts, ['conflict.m4a']);
      expect(
        await target.list().length,
        3,
        reason: 'no temporary files or duplicate clips remain',
      );
    },
  );

  test('all checksums are checked before any clip is written', () async {
    final bytes = bundle(
      {
        'first.ogg': [1],
        'bad.ogg': [2],
      },
      editManifest: (m) {
        ((m['recordings'] as List)[1] as Map)['sha256'] = 'corrupt';
      },
    );
    await expectLater(
      RecordingTransfer.importBundle(directory: target, bytes: bytes),
      throwsFormatException,
    );
    expect(await target.exists(), false);
  });

  test(
    'rejects unsafe filenames, unexpected paths and extra files without changing existing data',
    () async {
      for (final bytes in [
        bundle({
          '../outside.ogg': [1],
        }),
        bundle(
          {
            'valid.ogg': [1],
          },
          extra: {
            'outside.txt': <int>[2],
          },
        ),
        bundle(
          {
            'valid.ogg': [1],
          },
          extra: {
            'audio/nested/evil.ogg': <int>[2],
          },
        ),
      ]) {
        await expectLater(
          RecordingTransfer.importBundle(directory: target, bytes: bytes),
          throwsFormatException,
        );
        expect(await target.exists(), false);
      }
      expect(await File('${temp.path}/outside.ogg').exists(), false);
    },
  );

  test(
    'rejects unsupported version, missing audio and duplicated manifest identities',
    () async {
      for (final edit in <void Function(Map<String, Object?>)>[
        (m) => m['version'] = 99,
        (m) => ((m['recordings'] as List).first as Map)['name'] = 'missing.ogg',
        (m) => (m['recordings'] as List).add((m['recordings'] as List).first),
      ]) {
        await expectLater(
          RecordingTransfer.importBundle(
            directory: target,
            bytes: bundle({
              'one.ogg': [1],
            }, editManifest: edit),
          ),
          throwsFormatException,
        );
        expect(await target.exists(), false);
      }
    },
  );

  test('rejects empty/corrupt archives and changed lengths', () async {
    for (final bytes in [
      bundle({}),
      Uint8List.fromList([1, 2, 3]),
      bundle(
        {
          'one.ogg': [1],
        },
        editManifest: (m) =>
            ((m['recordings'] as List).first as Map)['size'] = 9,
      ),
    ]) {
      await expectLater(
        RecordingTransfer.importBundle(directory: target, bytes: bytes),
        throwsA(anything),
      );
      expect(await target.exists(), false);
    }
  });

  test('export refuses missing clips, unsafe names and symlinks', () async {
    for (final name in ['missing.ogg', '../outside.ogg']) {
      await expectLater(
        RecordingTransfer.exportBundle(directory: source, names: [name]),
        throwsFormatException,
      );
    }
    final outside = await File('${temp.path}/outside.ogg').writeAsBytes([7]);
    await Link('${source.path}/linked.ogg').create(outside.path);
    await expectLater(
      RecordingTransfer.exportBundle(directory: source, names: ['linked.ogg']),
      throwsFormatException,
    );
    await expectLater(
      RecordingTransfer.exportBundle(directory: source, names: []),
      throwsFormatException,
    );
  });

  test(
    'an existing symlink is a conflict and never followed or replaced',
    () async {
      await target.create(recursive: true);
      final outside = await File('${temp.path}/outside.ogg').writeAsBytes([7]);
      await Link('${target.path}/linked.ogg').create(outside.path);
      final result = await RecordingTransfer.importBundle(
        directory: target,
        bytes: bundle({
          'linked.ogg': [3],
        }),
      );
      expect(result.conflicts, ['linked.ogg']);
      expect(await outside.readAsBytes(), [7]);
      expect(
        await FileSystemEntity.type(
          '${target.path}/linked.ogg',
          followLinks: false,
        ),
        FileSystemEntityType.link,
      );
    },
  );

  test('portable URL resolution is confined to manual_audio basenames', () {
    const root = '/new/device/manual_audio';
    expect(
      recordingPathFromUrl('file:///old/device/manual_audio/clip-1.ogg', root),
      '$root/clip-1.ogg',
    );
    expect(
      recordingPathFromUrl('file://$root/clip-1.ogg', root),
      '$root/clip-1.ogg',
    );
    for (final url in [
      'https://example/manual_audio/clip.ogg',
      'file:///old/other/clip.ogg',
      'file:///old/manual_audio/../clip.ogg',
      'file:///old/manual_audio/%2e%2e/clip.ogg',
      'file:///old/manual_audio/nested/clip.ogg',
      'file://remote/old/manual_audio/clip.ogg',
      'file:///old/manual_audio/clip.ogg?x=1',
      'file:///old/manual_audio/clip.ogg#fragment',
    ]) {
      expect(recordingPathFromUrl(url, root), isNull, reason: url);
    }
  });
}
