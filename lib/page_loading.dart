import 'package:flutter/foundation.dart';

/// Whether the main page is loading, for the toolbar's spinner.
///
/// Fed from the main WebView's navigation callbacks. A load ends when the
/// page finishes, when the main frame fails (WKWebView reports a failed
/// navigation as an error with no "finished" after it), or when progress
/// reaches 100 (a backstop for a "finished" that never arrives). An error in
/// a sub-resource — an image, an ad frame — does not end it.
///
/// WebView callbacks can still arrive after the screen is gone; once disposed,
/// every update is ignored.
class PageLoading extends ValueNotifier<bool> {
  PageLoading() : super(false);

  bool _disposed = false;

  void started() => _set(true);

  void finished() => _set(false);

  void failed({required bool isMainFrame}) {
    if (isMainFrame) _set(false);
  }

  void progress(int percent) {
    if (percent >= 100) _set(false);
  }

  void _set(bool loading) {
    if (!_disposed) value = loading;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
