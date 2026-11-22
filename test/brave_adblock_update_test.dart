import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cupitor/brave_adblock_bundle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory root, current;
  late Map<String, dynamic> bundled, remote;
  late List<int> currentBytes, nextBytes;
  late BraveBundleUpdater updater;
  late List<String> activations;
  late List<Uri> requests;
  late MockClient client;

  List<int> bundle(int version) => utf8.encode(
    jsonEncode({
      'schema': 1,
      'engine_version': '0.13.6',
      'version': version,
      'lists': [
        {'text': '||ads.example^'},
      ],
      'resources': [
        {'name': 'test.js'},
      ],
    }),
  );

  Map<String, dynamic> manifest(List<int> bytes, int version) => {
    'schema': 1,
    'engine_version': '0.13.6',
    'version': version,
    'sha256': sha256.convert(bytes).toString(),
    'lists': [
      {'name': 'test'},
    ],
  };

  Future<bool> activate(Directory directory) async {
    activations.add(directory.path);
    return true;
  }

  Future<void> expectOriginalCache() async {
    expect(
      await File('${current.path}/bundle.json').readAsBytes(),
      currentBytes,
    );
    expect(await File('${root.path}/active.json').readAsString(), 'original');
    expect(root.listSync().whereType<Directory>().map((d) => d.path), [
      current.path,
    ]);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('brave-github-test-');
    current = await Directory('${root.path}/bundled-1').create();
    currentBytes = bundle(1);
    nextBytes = bundle(2);
    await File('${current.path}/bundle.json').writeAsBytes(currentBytes);
    await File('${root.path}/active.json').writeAsString('original');
    bundled = manifest(currentBytes, 1);
    remote = manifest(nextBytes, 2);
    updater = BraveBundleUpdater(root: root, bundledManifest: bundled);
    activations = [];
    requests = [];
    client = MockClient((request) async {
      requests.add(request.url);
      expect(request.followRedirects, isFalse);
      if (request.url == BraveBundleUpdater.manifestUrl) {
        return http.Response(jsonEncode(remote), 200);
      }
      expect(request.url, BraveBundleUpdater.bundleUrl);
      return http.Response(base64Encode(gzip.encode(nextBytes)), 200);
    });
  });

  tearDown(() async {
    client.close();
    await root.delete(recursive: true);
  });

  test('fetches from GitHub and promotes only after native activation', () async {
    expect(
      await updater.refresh(
        current: current,
        activate: activate,
        client: client,
      ),
      isTrue,
    );
    expect(requests, [
      BraveBundleUpdater.manifestUrl,
      BraveBundleUpdater.bundleUrl,
    ]);
    expect(
      BraveBundleUpdater.manifestUrl.toString(),
      'https://raw.githubusercontent.com/trexsatya/cupitor-flutter/main/assets/adblock/manifest.json',
    );
    final active = jsonDecode(
      await File('${root.path}/active.json').readAsString(),
    );
    final cached = File('${root.path}/${active['directory']}/bundle.json');
    expect(await cached.readAsBytes(), nextBytes);
    expect(activations, [cached.parent.path]);
    expect(active['bundleVersion'], 1);
    expect(active['version'], 2);
    expect(active['sha256'], remote['sha256']);
    expect(await File('${root.path}/last-check').exists(), isTrue);
  });

  test('unchanged data needs only the manifest request', () async {
    remote = bundled;
    expect(
      await updater.refresh(
        current: current,
        activate: activate,
        client: client,
      ),
      isFalse,
    );
    expect(requests, [BraveBundleUpdater.manifestUrl]);
    expect(activations, isEmpty);
    await expectOriginalCache();
  });

  test('checks at most once per day', () async {
    final checked = File('${root.path}/last-check');
    await checked.writeAsString('recent');
    expect(
      await updater.refresh(
        current: current,
        activate: activate,
        client: client,
      ),
      isFalse,
    );
    expect(requests, isEmpty);
    await checked.setLastModified(
      DateTime.now().subtract(const Duration(hours: 25)),
    );
    expect(
      await updater.refresh(
        current: current,
        activate: activate,
        client: client,
      ),
      isTrue,
    );
  });

  test('offline and missing GitHub data retain the working cache', () async {
    for (final status in [404, 503]) {
      final unavailable = MockClient(
        (_) async => http.Response('unavailable', status),
      );
      await expectLater(
        updater.refresh(
          current: current,
          activate: activate,
          client: unavailable,
        ),
        throwsA(isA<HttpException>()),
      );
      unavailable.close();
      await expectOriginalCache();
      await File('${root.path}/last-check').delete();
    }
    final offline = MockClient(
      (_) async => throw const SocketException('offline'),
    );
    await expectLater(
      updater.refresh(current: current, activate: activate, client: offline),
      throwsA(isA<SocketException>()),
    );
    offline.close();
    expect(activations, isEmpty);
    await expectOriginalCache();
  });

  test(
    'digest mismatch during a GitHub update never reaches the engine',
    () async {
      nextBytes = bundle(3);
      await expectLater(
        updater.refresh(current: current, activate: activate, client: client),
        throwsFormatException,
      );
      expect(activations, isEmpty);
      await expectOriginalCache();
    },
  );

  test('rejects incompatible manifests before downloading payloads', () async {
    for (final change in [
      {'schema': 2},
      {'engine_version': '99.0.0'},
      {'version': '2'},
      {'sha256': 'invalid'},
      {'lists': []},
    ]) {
      remote = {...manifest(nextBytes, 2), ...change};
      await expectLater(
        updater.refresh(current: current, activate: activate, client: client),
        throwsFormatException,
      );
      expect(requests.removeLast(), BraveBundleUpdater.manifestUrl);
      await File('${root.path}/last-check').delete();
    }
    expect(requests, isEmpty);
    expect(activations, isEmpty);
    await expectOriginalCache();
  });

  test('a valid checksum cannot hide mismatched bundle metadata', () async {
    remote['version'] = 3;
    await expectLater(
      updater.refresh(current: current, activate: activate, client: client),
      throwsFormatException,
    );
    expect(activations, isEmpty);
    await expectOriginalCache();
  });

  test(
    'same version cannot replace content or reuse cached WebKit rules',
    () async {
      remote['version'] = 1;
      await expectLater(
        updater.refresh(current: current, activate: activate, client: client),
        throwsFormatException,
      );
      expect(requests, [BraveBundleUpdater.manifestUrl]);
      await expectOriginalCache();
    },
  );

  test('older GitHub versions cannot downgrade cached data', () async {
    currentBytes = bundle(3);
    await File('${current.path}/bundle.json').writeAsBytes(currentBytes);
    await expectLater(
      updater.refresh(current: current, activate: activate, client: client),
      throwsFormatException,
    );
    expect(requests, [BraveBundleUpdater.manifestUrl]);
    await expectOriginalCache();
  });

  test(
    'native rejection restores the previous engine and removes staged files',
    () async {
      await expectLater(
        updater.refresh(
          current: current,
          client: client,
          activate: (directory) async {
            activations.add(directory.path);
            return directory.path == current.path;
          },
        ),
        throwsFormatException,
      );
      expect(activations, hasLength(2));
      expect(activations.last, current.path);
      await expectOriginalCache();
    },
  );

  test('native exceptions also restore the previous engine', () async {
    await expectLater(
      updater.refresh(
        current: current,
        client: client,
        activate: (directory) async {
          activations.add(directory.path);
          if (directory.path != current.path)
            throw StateError('native failure');
          return true;
        },
      ),
      throwsStateError,
    );
    expect(activations.last, current.path);
    await expectOriginalCache();
  });

  test('cache write failures roll back the active engine', () async {
    await Directory('${root.path}/active.tmp').create();
    await expectLater(
      updater.refresh(current: current, activate: activate, client: client),
      throwsA(isA<FileSystemException>()),
    );
    expect(activations.last, current.path);
    await Directory('${root.path}/active.tmp').delete();
    await expectOriginalCache();
  });

  test('oversized manifests and redirects are rejected', () async {
    for (final response in [
      http.Response(' ' * (256 * 1024 + 1), 200),
      http.Response('', 302),
    ]) {
      final bad = MockClient((_) async => response);
      await expectLater(
        updater.refresh(current: current, activate: activate, client: bad),
        throwsA(anyOf(isA<FormatException>(), isA<HttpException>())),
      );
      bad.close();
      await expectOriginalCache();
      await File('${root.path}/last-check').delete();
    }
    expect(activations, isEmpty);
  });

  test('bounds decompression and rejects truncated gzip data', () {
    final bomb = base64Encode(
      gzip.encode(List.filled(BraveBundleUpdater.maxBytes + 1, 32)),
    );
    expect(
      () => BraveBundleUpdater.decode(bomb, remote),
      throwsFormatException,
    );
    final compressed = gzip.encode(nextBytes);
    expect(
      () => BraveBundleUpdater.decode(
        base64Encode(compressed.sublist(0, 8)),
        remote,
      ),
      throwsFormatException,
    );
  });
}
