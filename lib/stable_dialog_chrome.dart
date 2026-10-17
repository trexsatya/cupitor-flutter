import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// WKWebView can consume events before Flutter's pointer router sees them.
// Passive notifications complement the widget's Listener without taking over
// any of the webapp's gestures or playback controls.
const kDialogChromeActivityJs = r'''
(function () {
  if (window.__cupDialogChromeActivity) return;
  window.__cupDialogChromeActivity = true;
  document.addEventListener('pointerdown', function () {
    if (window.DialogChromeActivity) window.DialogChromeActivity.postMessage('activity');
  }, {capture: true, passive: true});
})();
''';

/// Fades a dialog's toolbar while keeping its full layout space reserved.
/// Pointer activity is observed without consuming the child's gestures.
class StableDialogChrome extends StatefulWidget {
  const StableDialogChrome({
    super.key,
    required this.toolbar,
    required this.child,
    this.enabled = true,
    this.holdVisible,
    this.activity,
    this.idle = const Duration(seconds: 3),
  });

  final Widget toolbar;
  final Widget child;
  final bool enabled;
  final ValueListenable<bool>? holdVisible;
  final Listenable? activity;
  final Duration idle;

  @override
  State<StableDialogChrome> createState() => _StableDialogChromeState();
}

class _StableDialogChromeState extends State<StableDialogChrome> {
  Timer? _timer;
  bool _visible = true;
  final Set<int> _pointers = {};

  @override
  void initState() {
    super.initState();
    widget.activity?.addListener(_reveal);
    widget.holdVisible?.addListener(_reveal);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant StableDialogChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity != widget.activity) {
      oldWidget.activity?.removeListener(_reveal);
      widget.activity?.addListener(_reveal);
    }
    if (oldWidget.holdVisible != widget.holdVisible) {
      oldWidget.holdVisible?.removeListener(_reveal);
      widget.holdVisible?.addListener(_reveal);
    }
    if (oldWidget.enabled != widget.enabled) _reveal();
  }

  void _reveal() {
    if (!_visible) setState(() => _visible = true);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!widget.enabled ||
        _pointers.isNotEmpty ||
        widget.holdVisible?.value == true)
      return;
    _timer = Timer(widget.idle, () {
      if (!mounted) return;
      // A picker or menu opened from the toolbar still owns its controls.
      if (ModalRoute.of(context)?.isCurrent == false) {
        _schedule();
        return;
      }
      setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.activity?.removeListener(_reveal);
    widget.holdVisible?.removeListener(_reveal);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      _pointers.add(event.pointer);
      _reveal();
    },
    onPointerUp: (event) {
      _pointers.remove(event.pointer);
      _schedule();
    },
    onPointerCancel: (event) {
      _pointers.remove(event.pointer);
      _schedule();
    },
    child: Column(
      children: [
        if (widget.enabled)
          IgnorePointer(
            ignoring: !_visible,
            child: ExcludeSemantics(
              excluding: !_visible,
              child: FocusScope(
                canRequestFocus: _visible,
                descendantsAreFocusable: _visible,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: widget.toolbar,
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    ),
  );
}
