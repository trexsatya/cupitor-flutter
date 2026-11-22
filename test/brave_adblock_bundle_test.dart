import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cupitor/brave_adblock_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'offline Brave data matches its manifest and contains complete resources',
    () async {
      final manifest = jsonDecode(
        await File('assets/adblock/manifest.json').readAsString(),
      );
      final encoded = await File(
        'assets/adblock/bundle.json.gz.b64',
      ).readAsString();
      final bytes = BraveBundleUpdater.decode(encoded, manifest);
      expect(sha256.convert(bytes).toString(), manifest['sha256']);
      final bundle = jsonDecode(utf8.decode(bytes));
      expect(bundle['version'], manifest['version']);
      expect(bundle['engine_version'], '0.13.6');
      expect(bundle['lists'], hasLength(manifest['lists'].length));
      final resources = bundle['resources'] as List;
      expect(resources.length, greaterThan(100));
      expect(
        resources.any((dynamic r) => r['name'] == 'json-prune.js'),
        isTrue,
      );
      for (final dynamic list in bundle['lists']) {
        expect(
          list['text'],
          isNot(contains('!#include ')),
          reason: list['name'],
        );
      }
    },
  );
}
