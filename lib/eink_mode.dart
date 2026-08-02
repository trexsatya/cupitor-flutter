import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide E-ink display mode: dampens saturation and lifts blacks so
/// bright colours don't strobe on E-ink panels. Consumers wrap the
/// widget tree in a `ColorFiltered` gated on this notifier's value —
/// see the main WebView shell and the EPUB reader.
///
/// Top-level (not a State field) so screens opened via a fresh
/// `MaterialPageRoute` — most importantly the EPUB reader — read the
/// same value as the shell that owns the Tools-drawer toggle.
///
/// Default is `true` to match the app's opinionated preference. Call
/// [initEinkMode] once at app startup (after
/// `WidgetsFlutterBinding.ensureInitialized`) to hydrate the value
/// from SharedPreferences and wire the persistence listener; every
/// subsequent change to `einkMode.value` is written back to disk.
final ValueNotifier<bool> einkMode = ValueNotifier<bool>(true);

/// SharedPreferences key backing [einkMode].
const String _kEinkModePrefKey = 'einkMode';

bool _einkModeInitialized = false;

/// Load the persisted [einkMode] value and attach a save-on-change
/// listener. Idempotent — safe to call more than once (subsequent
/// calls no-op). Failing to read prefs leaves the default in place.
Future<void> initEinkMode() async {
  if (_einkModeInitialized) return;
  _einkModeInitialized = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_kEinkModePrefKey);
    if (stored != null) einkMode.value = stored;
  } catch (_) {
    // Best-effort — keep the default if prefs is unavailable.
  }
  einkMode.addListener(_persistEinkMode);
}

Future<void> _persistEinkMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEinkModePrefKey, einkMode.value);
  } catch (_) { /* best effort */ }
}

/// The colour matrix used when [einkMode] is on. Reduces saturation
/// (weighted-luma channels + a tiny lift on the black point) to
/// something readable on an E-ink panel without going pure greyscale.
const ColorFilter einkColorFilter = ColorFilter.matrix([
  0.1913, 0.6437, 0.0650, 0, 0.05,
  0.1850, 0.6222, 0.0628, 0, 0.04,
  0.1722, 0.5793, 0.0585, 0, 0.02,
  0,      0,      0,      1, 0,
]);

/// Pass-through matrix used when [einkMode] is off — keeps the widget
/// tree wrapped in the same `ColorFiltered` so toggling doesn't
/// force a rebuild of the child subtree.
const ColorFilter identityColorFilter = ColorFilter.matrix([
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
]);
