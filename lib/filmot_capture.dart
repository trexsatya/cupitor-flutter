import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum FilmotScript {
  capture('filmot-capture.js'),
  annotator('filmot-annotator.js'),
  saveVideo('filmot-save-video.js');

  const FilmotScript(this.filename);
  final String filename;
}

/// Filmot markup changes independently of app releases. Fetch scripts from
/// the Cupitor repo and keep the last successful copy for transient failures.
class FilmotScripts {
  static const _base =
      'https://raw.githubusercontent.com/trexsatya/cupitor/refs/heads/master/'
      'frontend/vue3/cupitor-frontend/public/page-scripts/';
  final _loads = <FilmotScript, Future<String>>{};

  Future<String> load(FilmotScript script) async {
    final task = _loads.putIfAbsent(script, () => _fetch(script));
    try {
      return await task;
    } catch (_) {
      if (identical(_loads[script], task)) _loads.remove(script);
      rethrow;
    }
  }

  Future<String> _fetch(FilmotScript script) async {
    final key = 'filmotScript.v1.${script.filename}';
    try {
      final response = await http
          .get(Uri.parse('$_base${script.filename}'))
          .timeout(const Duration(seconds: 5));
      final source = utf8.decode(response.bodyBytes);
      if (response.statusCode == 200 && _isScript(source)) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(key, source);
        } catch (_) {
          // The fetched script is still usable in this session.
        }
        return source;
      }
    } catch (_) {
      // Try the last successfully fetched copy.
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(key);
      if (cached != null && _isScript(cached)) return cached;
    } catch (_) {}
    throw StateError('Could not load ${script.filename} from Cupitor.');
  }

  bool _isScript(String source) =>
      source.trimLeft().startsWith('(function') && source.trimRight().endsWith('})();');
}

/// Android can wrap JavaScript JSON text in a second JSON string.
Map<String, dynamic>? decodeFilmotReply(Object? raw) {
  var value = raw;
  try {
    for (var layer = 0; layer < 2 && value is String; layer++) {
      value = jsonDecode(value);
    }
  } on FormatException {
    return null;
  }
  return value is Map<String, dynamic> ? value : null;
}

Map<String, dynamic>? decodeFilmotCapture(Object? raw) {
  final value = decodeFilmotReply(raw);
  final lines = value?['lines'];
  if (lines is! List || lines.any((line) => line is! Map<String, dynamic>)) {
    return null;
  }
  return value;
}
