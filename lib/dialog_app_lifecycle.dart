import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Reports the host app's lifecycle to dialog1. The webapp owns its timers.
class DialogAppLifecycleBridge with WidgetsBindingObserver {
  DialogAppLifecycleBridge({
    required Future<void> Function(String script) send,
    WidgetsBinding? binding,
  }) : _send = send,
       _binding = binding ?? WidgetsBinding.instance {
    _binding.addObserver(this);
  }

  final Future<void> Function(String script) _send;
  final WidgetsBinding _binding;
  bool _disposed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(sendCurrent());
  }

  /// Also called after a page load or a late listener's getState request.
  /// Read the binding each time so navigation never replays an old state.
  Future<void> sendCurrent() async {
    if (_disposed) return;
    final state = _binding.lifecycleState ?? AppLifecycleState.detached;
    final detail = jsonEncode({
      'state': state.name,
      'isForeground': state == AppLifecycleState.resumed,
    });
    try {
      await _send(kDialogAppLifecycleJs.replaceFirst(
        '__CUPITOR_APP_LIFECYCLE__',
        detail,
      ));
    } catch (error) {
      // A navigation or reclaimed renderer must not break native lifecycle
      // handling. The next page load/request sends the latest state again.
      debugPrint('[dialog1-lifecycle] $error');
    }
  }

  void dispose() {
    _disposed = true;
    _binding.removeObserver(this);
  }
}

/// A snapshot supports scripts that start after the initial page-load event.
const kDialogAppLifecycleJs = r'''
(function () {
  const detail = Object.freeze(__CUPITOR_APP_LIFECYCLE__);
  window.CupitorAppLifecycle = detail;
  window.dispatchEvent(new CustomEvent('cupitorAppLifecycle', { detail }));
})();
''';
