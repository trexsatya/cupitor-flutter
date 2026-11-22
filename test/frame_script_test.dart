import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/frame_script.dart';
import 'package:cupitor/youtube_controls.dart';

String script(int version) =>
    'window.__cupFrameBootVersion = $version; // protection';

class ProtectionAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => throw UnimplementedError();

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      key.endsWith('frame_boot.js') ? script(20) : '// controls';
}

void main() {
  test('app update beats an older stored or unversioned agent', () {
    expect(preferFrameScript(script(20), script(10)), script(20));
    expect(preferFrameScript(script(20), '// old cache'), script(20));
    expect(preferFrameScript(script(20), ''), script(20));
    expect(preferFrameScript(script(20), null), script(20));
  });

  test('a newer fetched agent remains eligible for the next navigation', () {
    expect(preferFrameScript(script(20), script(30)), script(30));
  });

  test('exact-controller injection carries protection before controls', () async {
    final combined = await youtubeProtectionScript(
      frameScript: script(10),
      bundle: ProtectionAssets(),
    );
    expect(combined, '${script(20)}\n// controls');
    final fresh = await youtubeProtectionScript(
      frameScript: script(30),
      bundle: ProtectionAssets(),
    );
    expect(fresh, '${script(30)}\n// controls');
  });
}

