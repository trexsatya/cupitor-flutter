import 'package:flutter/foundation.dart';

/// Process-wide JS log sink shared by the main WebView and the EPUB
/// reader. Each surface routes its `SnippetLogChannel` messages here so
/// a single overlay can show every diagnostic from any WebView.
class JsLogSink {
  JsLogSink._();
  static const int _cap = 500;
  static final List<String> entries = <String>[];
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  /// When `true`, the JS side is asked to emit verbose diagnostics
  /// (click chain, lookup steps, capture-tap tracing, etc.). Off by
  /// default so the panel only carries lifecycle + error logs. Each
  /// WebView surface watches this and pushes `window.__cupitorVerbose`
  /// down on the next opportunity.
  static final ValueNotifier<bool> verbose = ValueNotifier<bool>(false);

  static void add(String level, String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    entries.add('[$ts] [$level] $msg');
    if (entries.length > _cap) {
      entries.removeRange(0, entries.length - _cap);
    }
    version.value++;
  }

  static void clear() {
    entries.clear();
    version.value++;
  }
}
