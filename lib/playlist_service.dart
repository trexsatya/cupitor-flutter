import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';

/// Application-wide playlist state.
///
/// The active playlist id is what capture-tap in the EPUB reader appends
/// to. When it's null (no playlist created yet, or user hasn't picked
/// one) capture-tap prompts to create / select. State is exposed as
/// [ValueNotifier]s so the reader chip and the playlist screen can
/// react to changes without a shared parent widget.
///
/// A separate [changes] notifier fires whenever *any* playlist or
/// playlist item is mutated — used by main.dart to push updated JSON
/// into dialog1's WebView so the language app stays in sync without
/// polling.
class PlaylistService {
  PlaylistService._();

  static const _activePrefKey = 'activePlaylistId';

  static final ValueNotifier<int?> activeId = ValueNotifier<int?>(null);

  /// Bumped on any playlist / item mutation. Value is a monotonically
  /// increasing counter — subscribers only care that it changed.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getInt(_activePrefKey);
      activeId.value = id;
    } catch (_) { /* prefs unavailable — active stays null */ }
  }

  static Future<void> setActive(int? id) async {
    activeId.value = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null) {
        await prefs.remove(_activePrefKey);
      } else {
        await prefs.setInt(_activePrefKey, id);
      }
    } catch (_) { /* best effort */ }
  }

  static void _bumpChanges() {
    changes.value = changes.value + 1;
  }

  /// Add a captured EPUB sentence to the active playlist. If nothing is
  /// active, no-ops and returns null — the caller should surface a
  /// "pick a playlist first" hint.
  static Future<PlaylistItemRow?> addToActive({
    required String sentenceText,
    String? bookKey,
    String? bookTitle,
    int? chapterIdx,
    String? chapterTitle,
  }) async {
    final id = activeId.value;
    if (id == null) return null;
    final row = await CupitorDb.instance.addPlaylistItem(
      playlistId: id,
      sentenceText: sentenceText,
      bookKey: bookKey,
      bookTitle: bookTitle,
      chapterIdx: chapterIdx,
      chapterTitle: chapterTitle,
    );
    _bumpChanges();
    return row;
  }

  static Future<PlaylistRow?> createPlaylist(String name) async {
    final row = await CupitorDb.instance.createPlaylist(name);
    if (row != null) {
      // First playlist auto-activates so capture-tap has a destination.
      if (activeId.value == null) await setActive(row.id);
      _bumpChanges();
    }
    return row;
  }

  static Future<void> deletePlaylist(int id) async {
    await CupitorDb.instance.deletePlaylist(id);
    if (activeId.value == id) await setActive(null);
    _bumpChanges();
  }

  static Future<void> renamePlaylist(int id, String newName) async {
    await CupitorDb.instance.renamePlaylist(id, newName);
    _bumpChanges();
  }

  static Future<void> deleteItem(int id) async {
    await CupitorDb.instance.deletePlaylistItem(id);
    _bumpChanges();
  }

  static Future<void> reorderItems(int playlistId, List<int> orderedIds) async {
    await CupitorDb.instance.reorderPlaylistItems(playlistId, orderedIds);
    _bumpChanges();
  }

  /// Snapshot every playlist + its items in the shape the language app
  /// consumes. Kept intentionally minimal (text + book/chapter labels
  /// + book_key for jump-back). The receiver never sees Cupitor's
  /// internal profile / tag ids.
  static Future<Map<String, Object?>> buildPayload() async {
    final db = CupitorDb.instance;
    final playlists = await db.listPlaylists();
    final out = <Map<String, Object?>>[];
    for (final p in playlists) {
      final items = await db.listPlaylistItems(p.id);
      out.add({
        'id': p.id,
        'name': p.name,
        'created_at': p.createdAt,
        'cards': items.map((i) => i.toJson()).toList(),
      });
    }
    return {
      'version': 1,
      'active_id': activeId.value,
      'playlists': out,
    };
  }

  static Future<String> buildPayloadJson() async {
    final p = await buildPayload();
    return jsonEncode(p);
  }
}
