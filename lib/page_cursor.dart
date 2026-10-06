import 'dart:io';

import 'package:flutter/widgets.dart';

/// Leaves the mouse cursor over a web page to the page.
///
/// On macOS a WebView is a native view that sets the cursor itself — an I-beam
/// over text, a hand over links. Flutter's Android platform views tell the
/// framework to keep out (`MouseCursor.uncontrolled`), but the macOS one does
/// not, so Flutter kept putting its default arrow back over the page while the
/// page kept putting its own cursor back: a flicker on every move near text.
/// A no-op elsewhere.
Widget pageCursor(Widget webView) => Platform.isMacOS
    ? MouseRegion(cursor: MouseCursor.uncontrolled, child: webView)
    : webView;
