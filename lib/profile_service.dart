import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';

/// Single source of truth for the currently-active tagging profile.
///
/// The active profile id is persisted to SharedPreferences under
/// [_kPrefKey] and surfaced live via [active]. Both the main WebView
/// screen and the EPUB reader listen to [active] and reload their
/// rehydrate / filter / mask state whenever it changes.
///
/// On first v3 launch the previously-global filter / mask prefs keys
/// are migrated to per-profile keys so the user's settings carry over.
class ProfileService {
  ProfileService._();
  static const String _kPrefKey = 'activeProfileId';
  static const String _kKeyMigrationDone = 'profilePrefsMigrationDone';

  /// The currently-active profile. Null only during the moment between
  /// the screen being built and [init] completing; UI should guard.
  static final ValueNotifier<ProfileRow?> active = ValueNotifier<ProfileRow?>(null);

  /// Load the active profile id from prefs, falling back to the first
  /// profile (which is always 'Default' on a clean install after the
  /// v3 migration). Also performs the one-time prefs key rename so
  /// pre-profile filter/mask state slots into the Default profile.
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = await CupitorDb.instance.listProfiles();
    if (profiles.isEmpty) {
      // DB not yet open or migration not run — leave inactive.
      active.value = null;
      return;
    }
    final id = prefs.getInt(_kPrefKey) ?? CupitorDb.defaultProfileId;
    final picked = profiles.firstWhere(
      (p) => p.id == id,
      orElse: () => profiles.first,
    );
    active.value = picked;
    if (!(prefs.getBool(_kKeyMigrationDone) ?? false)) {
      await _migratePrefsKeys(prefs);
      await prefs.setBool(_kKeyMigrationDone, true);
    }
  }

  static Future<void> setActive(int id) async {
    final profiles = await CupitorDb.instance.listProfiles();
    final picked = profiles.firstWhere(
      (p) => p.id == id,
      orElse: () => profiles.first,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPrefKey, picked.id);
    active.value = picked;
  }

  /// Reload [active] from the DB after a rename / delete so the
  /// notifier's row carries the new metadata.
  static Future<void> refresh() async {
    final id = active.value?.id;
    if (id == null) {
      await init();
      return;
    }
    final profiles = await CupitorDb.instance.listProfiles();
    if (profiles.isEmpty) {
      active.value = null;
      return;
    }
    final picked = profiles.firstWhere(
      (p) => p.id == id,
      orElse: () => profiles.first,
    );
    final prefs = await SharedPreferences.getInstance();
    if (picked.id != id) await prefs.setInt(_kPrefKey, picked.id);
    active.value = picked;
  }

  static int get currentId =>
      active.value?.id ?? CupitorDb.defaultProfileId;

  /// One-time migration of pre-v3 prefs keys into the Default profile's
  /// namespace. Old keys are removed once copied.
  static Future<void> _migratePrefsKeys(SharedPreferences prefs) async {
    const int id = CupitorDb.defaultProfileId;
    Future<void> moveStringList(String oldKey, String newKey) async {
      final v = prefs.getStringList(oldKey);
      if (v == null) return;
      await prefs.setStringList(newKey, v);
      await prefs.remove(oldKey);
    }
    Future<void> moveBool(String oldKey, String newKey) async {
      final v = prefs.getBool(oldKey);
      if (v == null) return;
      await prefs.setBool(newKey, v);
      await prefs.remove(oldKey);
    }
    await moveStringList('tagFilter:web', 'tagFilter:web:$id');
    await moveStringList('tagFilter:epub', 'tagFilter:epub:$id');
    await moveBool('tagMasks:web', 'tagMasks:web:$id');
    await moveBool('tagMasks:epub', 'tagMasks:epub:$id');
  }

  /// Per-profile preference key helpers — callers should always go
  /// through these so the keying stays in one place.
  static String filterKey(String surface, int profileId) => 'tagFilter:$surface:$profileId';
  static String masksKey(String surface, int profileId) => 'tagMasks:$surface:$profileId';
}
