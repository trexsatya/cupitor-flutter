import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Owns the shared, offline-first Brave filter data. Native platforms share the
/// exact bundle and Rust engine; only WebView interception differs.
class BraveAdblock {
  static const _channel = MethodChannel('cupitor/brave_adblock');
  static Future<void>? _starting;
  static bool ready = false;
  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isMacOS);
  static const _maxBytes = 20 * 1024 * 1024;

  static Future<void> initialize() => _starting ??= _initialize();

  static Future<bool> _activate(Directory directory) async {
    final value = await _channel
        .invokeMapMethod<String, dynamic>('initialize', {
          'directory': directory.path,
          'platform': Platform.isAndroid ? 'android' : 'macos',
        });
    ready = value?['ready'] == true;
    if (!ready)
      debugPrint('[brave-adblock] ${value?['error'] ?? 'engine unavailable'}');
    return ready;
  }

  static Future<void> _initialize() async {
    if (!supported) return;
    try {
      final manifest =
          jsonDecode(
                await rootBundle.loadString('assets/adblock/manifest.json'),
              )
              as Map<String, dynamic>;
      final root = Directory(
        '${(await getApplicationSupportDirectory()).path}/brave-adblock',
      );
      await root.create(recursive: true);
      final bundled = Directory('${root.path}/bundled-${manifest['version']}');
      final file = File('${bundled.path}/bundle.json');
      if (!await file.exists() ||
          sha256.convert(await file.readAsBytes()).toString() !=
              manifest['sha256']) {
        final encoded = await rootBundle.loadString(
          'assets/adblock/bundle.json.gz.b64',
        );
        final bytes = gzip.decode(
          base64Decode(encoded.replaceAll(RegExp(r'\s'), '')),
        );
        if (sha256.convert(bytes).toString() != manifest['sha256'])
          throw const FormatException('Invalid bundled Brave data');
        await bundled.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
      var current = bundled;
      final active = File('${root.path}/active.json');
      if (await active.exists()) {
        try {
          final saved =
              jsonDecode(await active.readAsString()) as Map<String, dynamic>;
          final name = saved['directory'] as String;
          if (saved['bundleVersion'] == manifest['version'] &&
              RegExp(r'^update-\d+$').hasMatch(name)) {
            final candidate = Directory('${root.path}/$name');
            final bytes = await File(
              '${candidate.path}/bundle.json',
            ).readAsBytes();
            if (bytes.length <= _maxBytes &&
                sha256.convert(bytes).toString() == saved['sha256'])
              current = candidate;
          }
        } catch (_) {
          /* use the verified offline bundle */
        }
      }
      if (!await _activate(current) && current.path != bundled.path) {
        current = bundled;
        await _activate(current);
      }
      if (ready) unawaited(_refresh(root, current, manifest));
    } catch (error) {
      debugPrint('[brave-adblock] initialization failed: $error');
      // Keep the existing host/pruning fallback if the native engine cannot load.
    }
  }

  static Future<void> install(WebViewController controller) async {
    await initialize();
    if (!ready ||
        !Platform.isAndroid ||
        controller.platform is! AndroidWebViewController)
      return;
    // Reinstall after navigation delegates change or filter updates arrive.
    await _channel.invokeMethod<bool>('install', {
      'webViewId':
          (controller.platform as AndroidWebViewController).webViewIdentifier,
    });
  }

  static Future<String> _download(http.Client client, Uri uri) async {
    if (uri.scheme != 'https' || uri.host != 'raw.githubusercontent.com')
      throw const FormatException('Invalid filter source');
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200)
      throw HttpException('Filter download failed: ${response.statusCode}');
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBytes)
        throw const FormatException('Filter download too large');
    }
    final text = utf8.decode(bytes);
    if (text.trimLeft().startsWith('<') || text.trim().isEmpty)
      throw const FormatException('Invalid filter response');
    return text;
  }

  static Future<void> _refresh(
    Directory root,
    Directory current,
    Map<String, dynamic> manifest,
  ) async {
    final checked = File('${root.path}/last-check');
    var attempted = false;
    try {
      if (await checked.exists() &&
          DateTime.now().difference(await checked.lastModified()) <
              const Duration(hours: 24))
        return;
      attempted = true;
      final client = http.Client();
      try {
        final fetched = <Uri, String>{};
        Future<String> expand(Uri uri, [int depth = 0]) async {
          if (depth > 4)
            throw const FormatException('Recursive filter include');
          final text = fetched[uri] ??= await _download(client, uri);
          final lines = <String>[];
          for (final line in const LineSplitter().convert(text)) {
            if (line.startsWith('!#include ')) {
              final name = line.substring(10).trim();
              if (!RegExp(r'^[A-Za-z0-9_-]+\.txt$').hasMatch(name))
                throw const FormatException('Invalid filter include');
              lines.add(await expand(uri.resolve(name), depth + 1));
            } else {
              lines.add(line);
            }
          }
          return '${lines.join('\n')}\n';
        }

        final lists = <Map<String, dynamic>>[];
        for (final entry in manifest['lists'] as List) {
          final text = await expand(Uri.parse(entry['url'] as String));
          if (text.length < 100 || !RegExp(r'^\s*[!\[]').hasMatch(text)) {
            throw const FormatException('Invalid filter list');
          }
          lists.add({
            'name': entry['name'],
            'permission': entry['permission'],
            'platforms': entry['platforms'] ?? [],
            'text': text,
          });
        }
        final resources = <String, dynamic>{};
        for (final entry in manifest['resources'] as List) {
          final data =
              jsonDecode(
                    await _download(client, Uri.parse(entry['url'] as String)),
                  )
                  as List;
          for (final resource in data) {
            resources[resource['name'] as String] = resource;
          }
        }
        if (resources.length < 100)
          throw const FormatException('Incomplete scriptlet resources');
        final contents = jsonEncode({
          'schema': 1,
          'engine_version': manifest['engine_version'],
          'version': DateTime.now().millisecondsSinceEpoch,
          'lists': lists,
          'resources': resources.values.toList(),
        });
        if (utf8.encode(contents).length > _maxBytes)
          throw const FormatException('Filter bundle too large');
        final name = 'update-${DateTime.now().millisecondsSinceEpoch}';
        final candidate = Directory('${root.path}/$name');
        await candidate.create();
        await File(
          '${candidate.path}/bundle.json',
        ).writeAsString(contents, flush: true);
        if (await _activate(candidate)) {
          final temp = File('${root.path}/active.tmp');
          await temp.writeAsString(
            jsonEncode({
              'directory': name,
              'bundleVersion': manifest['version'],
              'sha256': sha256.convert(utf8.encode(contents)).toString(),
            }),
            flush: true,
          );
          await temp.rename('${root.path}/active.json');
          for (final entity
              in root.listSync(followLinks: false).whereType<Directory>()) {
            if (entity.path != candidate.path &&
                entity.path != current.path &&
                entity.path.split('/').last.startsWith('update-')) {
              await entity.delete(recursive: true);
            }
          }
        } else {
          await _activate(current);
          await candidate.delete(recursive: true);
        }
      } finally {
        client.close();
      }
    } catch (error) {
      debugPrint(
        '[brave-adblock] refresh unavailable, retaining last good data: $error',
      );
    } finally {
      if (attempted) {
        try {
          await checked.writeAsString(DateTime.now().toUtc().toIso8601String());
        } catch (_) {}
      }
    }
  }
}
