import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Fetches Cupitor's assembled data, rather than rebuilding upstream lists on
/// each device. The native engine must accept it before the cache is promoted.
class BraveBundleUpdater {
  BraveBundleUpdater({required this.root, required this.bundledManifest});

  static const maxBytes = 20 * 1024 * 1024;
  static const _maxDownloadBytes = 8 * 1024 * 1024;
  static const _base =
      'https://raw.githubusercontent.com/trexsatya/cupitor-flutter/main/assets/adblock/';
  static final manifestUrl = Uri.parse('${_base}manifest.json');
  static final bundleUrl = Uri.parse('${_base}bundle.json.gz.b64');
  final Directory root;
  final Map<String, dynamic> bundledManifest;

  /// Also bounds decompression, so a small compressed response cannot expand
  /// without limit. A racing GitHub update fails its digest check and is retried
  /// on the next check; it never replaces working data.
  static List<int> decode(String encoded, Map<String, dynamic> manifest) {
    if (encoded.length > _maxDownloadBytes) {
      throw const FormatException('Brave download too large');
    }
    final compressed = base64Decode(encoded.replaceAll(RegExp(r'\s'), ''));
    final output = _LimitedBytes(maxBytes);
    final decoder = gzip.decoder.startChunkedConversion(output);
    decoder.add(compressed);
    decoder.close();
    final bytes = output.bytes.takeBytes();
    if (sha256.convert(bytes).toString() != manifest['sha256']) {
      throw const FormatException('Invalid Brave bundle checksum');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map ||
        data['schema'] != 1 ||
        data['engine_version'] != manifest['engine_version'] ||
        data['version'] != manifest['version'] ||
        data['lists'] is! List ||
        (data['lists'] as List).isEmpty ||
        data['lists'].length != (manifest['lists'] as List).length ||
        data['resources'] is! List ||
        (data['resources'] as List).isEmpty) {
      throw const FormatException('Invalid Brave bundle contents');
    }
    return bytes;
  }

  static Future<String> _download(
    http.Client client,
    Uri url, {
    required int limit,
  }) async {
    final request = http.Request('GET', url)
      ..followRedirects = false
      ..headers['Cache-Control'] = 'no-cache';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('Brave download failed: ${response.statusCode}');
    }
    final output = _LimitedBytes(limit);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      output.add(chunk);
    }
    return utf8.decode(output.bytes.takeBytes());
  }

  /// Throws on failed downloads/activation; the caller keeps using its current
  /// engine. [client] is injectable for offline, corruption and rollback tests.
  Future<bool> refresh({
    required Directory current,
    required Future<bool> Function(Directory) activate,
    http.Client? client,
  }) async {
    final checked = File('${root.path}/last-check');
    if (await checked.exists() &&
        DateTime.now().difference(await checked.lastModified()) <
            const Duration(hours: 24)) {
      return false;
    }
    final requestClient = client ?? http.Client();
    Directory? candidate;
    var activationAttempted = false;
    var promoted = false;
    try {
      final remote = jsonDecode(
        await _download(requestClient, manifestUrl, limit: 256 * 1024),
      );
      if (remote is! Map<String, dynamic> ||
          remote['schema'] != 1 ||
          remote['engine_version'] != bundledManifest['engine_version'] ||
          remote['version'] is! int ||
          remote['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(remote['sha256'] as String) ||
          remote['lists'] is! List ||
          (remote['lists'] as List).isEmpty) {
        throw const FormatException('Incompatible Brave bundle manifest');
      }
      final currentBytes = await File(
        '${current.path}/bundle.json',
      ).readAsBytes();
      final currentVersion =
          jsonDecode(utf8.decode(currentBytes))['version'] as int;
      final version = remote['version'] as int;
      if (version < currentVersion ||
          version < (bundledManifest['version'] as int)) {
        throw const FormatException('Outdated Brave bundle');
      }
      if (version == currentVersion) {
        if (sha256.convert(currentBytes).toString() != remote['sha256']) {
          throw const FormatException('Changed Brave data needs a new version');
        }
        return false;
      }
      final bytes = decode(
        await _download(requestClient, bundleUrl, limit: _maxDownloadBytes),
        remote,
      );
      final name = 'update-${DateTime.now().microsecondsSinceEpoch}';
      candidate = Directory('${root.path}/$name');
      await candidate.create();
      await File(
        '${candidate.path}/bundle.json',
      ).writeAsBytes(bytes, flush: true);
      activationAttempted = true;
      if (!await activate(candidate)) {
        throw const FormatException('Native engine rejected Brave bundle');
      }
      final temp = File('${root.path}/active.tmp');
      await temp.writeAsString(
        jsonEncode({
          'directory': name,
          'bundleVersion': bundledManifest['version'],
          'version': version,
          'sha256': remote['sha256'],
        }),
        flush: true,
      );
      await temp.rename('${root.path}/active.json');
      promoted = true;
      for (final entity
          in root.listSync(followLinks: false).whereType<Directory>()) {
        if (entity.path != candidate.path &&
            entity.path != current.path &&
            entity.path.split('/').last.startsWith('update-')) {
          await entity.delete(recursive: true);
        }
      }
      return true;
    } finally {
      if (client == null) requestClient.close();
      try {
        if (!promoted && candidate != null) {
          if (activationAttempted) await activate(current);
          await candidate.delete(recursive: true);
        }
      } finally {
        try {
          await checked.writeAsString(DateTime.now().toUtc().toIso8601String());
        } catch (_) {
          // A read-only cache must not hide the original download failure.
        }
      }
    }
  }
}

class _LimitedBytes implements Sink<List<int>> {
  _LimitedBytes(this.limit);

  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('Brave data too large');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
