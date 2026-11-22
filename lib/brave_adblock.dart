import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'brave_adblock_bundle.dart';

/// Owns the shared, offline-first Brave filter data. Native platforms share the
/// exact bundle and Rust engine; only WebView interception differs.
class BraveAdblock {
  static const _channel = MethodChannel('cupitor/brave_adblock');
  static Future<void>? _starting;
  static bool ready = false;
  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isMacOS);

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
        final bytes = BraveBundleUpdater.decode(encoded, manifest);
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
            if (bytes.length <= BraveBundleUpdater.maxBytes &&
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

  static Future<void> _refresh(
    Directory root,
    Directory current,
    Map<String, dynamic> manifest,
  ) async {
    try {
      await BraveBundleUpdater(
        root: root,
        bundledManifest: manifest,
      ).refresh(current: current, activate: _activate);
    } catch (error) {
      debugPrint(
        '[brave-adblock] refresh unavailable, retaining last good data: $error',
      );
    }
  }
}
