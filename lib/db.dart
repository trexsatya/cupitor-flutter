import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// First SQLite store in Cupitor. Phase 1: tags, pages, sentences,
/// sentence_tags only — existing prefs/JSON state stays put. See
/// docs/superpowers/specs/2026-06-24-sentence-tagging-design.md for the
/// data model and identity rules; the docstring on each method below
/// refers back to it.
class CupitorDb {
  CupitorDb._();
  static final CupitorDb instance = CupitorDb._();

  Database? _db;
  bool _failed = false;

  // v1 → v2: added `mask` column on sentences.
  // v2 → v3: introduced profiles. Tags and sentences are now scoped to
  // a profile_id; existing data is migrated into a "Default" profile
  // (id=1). Identity tuples gain profile_id so the same physical
  // sentence can be tagged differently under different profiles.
  // v3 → v4: added `sentence_media` table for attaching image / audio /
  // video files to a tagged sentence. Files live on disk under
  // `<app_docs>/sentence_media/`, content-addressed by SHA-1.
  // v4 → v5: `sentence_media` gains a `url` column. When non-null the
  // row references an external URL (no on-disk file) and `sha1` is an
  // empty string. When null the row is a local content-addressed file
  // exactly as before.
  // v5 → v6: `playlists` + `playlist_items` tables. User-created card
  // lists sourced from EPUB captures. Delivered to the language app
  // inside dialog1 via a JS channel. Items are snapshots (denormalised
  // book/chapter labels) so cards keep displaying even if the EPUB is
  // re-imported and its sentence ids change.
  static const int _schemaVersion = 6;
  static const String _fileName = 'cupitor.db';
  static const int defaultProfileId = 1;

  /// Escape hatch for callers that need the underlying handle for
  /// bulk operations (import / export). Follows the same
  /// null-if-unavailable contract as [_open].
  Future<Database?> rawDb() => _open();

  /// Lazy open. Returns null if the database cannot be opened — callers
  /// must treat this as "feature self-disabled" (the spec's rollout-safety
  /// rule). All DAO methods do this check internally and silently no-op.
  Future<Database?> _open() async {
    if (_failed) return null;
    if (_db != null) return _db;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/$_fileName';
      _db = await openDatabase(
        path,
        version: _schemaVersion,
        onConfigure: (db) async {
          // FKs must be OFF here so an in-flight upgrade can DROP parent
          // tables without firing ON DELETE CASCADE on link tables. SQLite
          // ignores `PRAGMA foreign_keys` changes inside a transaction —
          // and onUpgrade runs in one — so setting it here (outside any
          // transaction) is the only place that actually takes effect.
          // onOpen re-enables FKs for normal runtime use.
          await db.execute('PRAGMA foreign_keys = OFF;');
        },
        onOpen: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, v) => createSchema(db),
        onUpgrade: (db, oldV, newV) => runMigrations(db, oldV, newV),
      );
      return _db;
    } catch (e, st) {
      _failed = true;
      // ignore: avoid_print
      print('CupitorDb open failed: $e\n$st');
      return null;
    }
  }

  /// Full current-version schema. Public + static so tests can build a real
  /// database on sqflite_common_ffi without touching path_provider.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
            CREATE TABLE profiles (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
              created_at INTEGER NOT NULL
            )''');
    await db.insert('profiles', {
      'id': defaultProfileId,
      'name': 'Default',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await db.execute('''
            CREATE TABLE tags (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              name       TEXT NOT NULL COLLATE NOCASE,
              color      TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              UNIQUE(profile_id, name)
            )''');
    await db.execute('CREATE INDEX idx_tags_profile ON tags(profile_id)');
    await db.execute('''
            CREATE TABLE pages (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              surface      TEXT NOT NULL,
              locator      TEXT NOT NULL,
              title        TEXT,
              last_seen_at INTEGER NOT NULL,
              UNIQUE(surface, locator)
            )''');
    await db.execute('''
            CREATE TABLE sentences (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              page_id    INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
              text       TEXT NOT NULL,
              prev_fp    TEXT,
              next_fp    TEXT,
              mask       TEXT,
              created_at INTEGER NOT NULL,
              UNIQUE(profile_id, page_id, text, prev_fp, next_fp)
            )''');
    await db.execute('CREATE INDEX idx_sentences_page ON sentences(page_id)');
    await db.execute('CREATE INDEX idx_sentences_profile ON sentences(profile_id)');
    await db.execute('''
            CREATE TABLE sentence_tags (
              sentence_id INTEGER NOT NULL REFERENCES sentences(id) ON DELETE CASCADE,
              tag_id      INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
              PRIMARY KEY (sentence_id, tag_id)
            )''');
    await db.execute('CREATE INDEX idx_st_tag ON sentence_tags(tag_id)');
    await db.execute('''
            CREATE TABLE sentence_media (
              id          INTEGER PRIMARY KEY AUTOINCREMENT,
              sentence_id INTEGER NOT NULL REFERENCES sentences(id) ON DELETE CASCADE,
              kind        TEXT NOT NULL,
              sha1        TEXT NOT NULL,
              url         TEXT,
              mime_type   TEXT,
              filename    TEXT NOT NULL,
              size_bytes  INTEGER,
              created_at  INTEGER NOT NULL
            )''');
    await db.execute('CREATE INDEX idx_sentence_media_sentence ON sentence_media(sentence_id)');
    await db.execute('CREATE INDEX idx_sentence_media_sha1 ON sentence_media(sha1)');
    await db.execute('''
            CREATE TABLE playlists (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              name       TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )''');
    await db.execute('''
            CREATE TABLE playlist_items (
              id            INTEGER PRIMARY KEY AUTOINCREMENT,
              playlist_id   INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
              sentence_text TEXT NOT NULL,
              book_key      TEXT,
              book_title    TEXT,
              chapter_idx   INTEGER,
              chapter_title TEXT,
              position      INTEGER NOT NULL,
              created_at    INTEGER NOT NULL
            )''');
    await db.execute('CREATE INDEX idx_playlist_items_playlist ON playlist_items(playlist_id)');
  }

  /// All version-stepped migrations. Public + static for the same reason —
  /// the v6→v7 test drives this directly against an in-memory v6 fixture.
  static Future<void> runMigrations(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      await db.execute('ALTER TABLE sentences ADD COLUMN mask TEXT;');
    }
    if (oldV < 3) {
      // v2 → v3: introduce profiles. Existing rows fold into a
      // pre-created "Default" profile (id=1). Tables with new
      // composite UNIQUE constraints have to be rebuilt because
      // SQLite can't ALTER an existing UNIQUE. FKs are already OFF
      // here (set in onConfigure outside the transaction) so the
      // DROP TABLE statements below won't cascade-wipe sentence_tags.
      await db.execute('''
              CREATE TABLE profiles (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
                created_at INTEGER NOT NULL
              )''');
      await db.insert('profiles', {
        'id': defaultProfileId,
        'name': 'Default',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      await db.execute('''
              CREATE TABLE tags_new (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                name       TEXT NOT NULL COLLATE NOCASE,
                color      TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(profile_id, name)
              )''');
      await db.execute('''
              INSERT INTO tags_new (id, profile_id, name, color, created_at)
              SELECT id, $defaultProfileId, name, color, created_at FROM tags
            ''');
      await db.execute('DROP TABLE tags');
      await db.execute('ALTER TABLE tags_new RENAME TO tags');
      await db.execute('CREATE INDEX idx_tags_profile ON tags(profile_id)');
      await db.execute('''
              CREATE TABLE sentences_new (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                page_id    INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
                text       TEXT NOT NULL,
                prev_fp    TEXT,
                next_fp    TEXT,
                mask       TEXT,
                created_at INTEGER NOT NULL,
                UNIQUE(profile_id, page_id, text, prev_fp, next_fp)
              )''');
      await db.execute('''
              INSERT INTO sentences_new (id, profile_id, page_id, text, prev_fp, next_fp, mask, created_at)
              SELECT id, $defaultProfileId, page_id, text, prev_fp, next_fp, mask, created_at FROM sentences
            ''');
      await db.execute('DROP TABLE sentences');
      await db.execute('ALTER TABLE sentences_new RENAME TO sentences');
      await db.execute('CREATE INDEX idx_sentences_page ON sentences(page_id)');
      await db.execute('CREATE INDEX idx_sentences_profile ON sentences(profile_id)');
      // sentence_tags keeps its rows; FK targets still resolve
      // because tag/sentence ids were preserved.
      await db.execute('PRAGMA foreign_key_check;');
    }
    if (oldV < 4) {
      // v3 → v4: add sentence_media table for image/audio/video
      // attachments. Files live under app_docs/sentence_media,
      // content-addressed by SHA-1.
      await db.execute('''
              CREATE TABLE sentence_media (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                sentence_id INTEGER NOT NULL REFERENCES sentences(id) ON DELETE CASCADE,
                kind        TEXT NOT NULL,
                sha1        TEXT NOT NULL,
                mime_type   TEXT,
                filename    TEXT NOT NULL,
                size_bytes  INTEGER,
                created_at  INTEGER NOT NULL
              )''');
      await db.execute('CREATE INDEX idx_sentence_media_sentence ON sentence_media(sentence_id)');
      await db.execute('CREATE INDEX idx_sentence_media_sha1 ON sentence_media(sha1)');
    }
    if (oldV < 5) {
      // v4 → v5: allow URL attachments alongside on-disk files.
      // Existing rows have url = NULL and stay content-addressed.
      await db.execute('ALTER TABLE sentence_media ADD COLUMN url TEXT');
    }
    if (oldV < 6) {
      // v5 → v6: user-created playlists sourced from EPUB captures.
      await db.execute('''
              CREATE TABLE playlists (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                created_at INTEGER NOT NULL
              )''');
      await db.execute('''
              CREATE TABLE playlist_items (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                playlist_id   INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                sentence_text TEXT NOT NULL,
                book_key      TEXT,
                book_title    TEXT,
                chapter_idx   INTEGER,
                chapter_title TEXT,
                position      INTEGER NOT NULL,
                created_at    INTEGER NOT NULL
              )''');
      await db.execute('CREATE INDEX idx_playlist_items_playlist ON playlist_items(playlist_id)');
    }
  }

  /// Whether the DB is usable. Toolbar buttons hide if this is false.
  Future<bool> isReady() async {
    final db = await _open();
    return db != null;
  }

  // ---------- Profile CRUD ----------

  Future<List<ProfileRow>> listProfiles() async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.query('profiles', orderBy: 'created_at ASC');
    return rows
        .map((m) => ProfileRow(
              id: m['id'] as int,
              name: m['name'] as String,
              createdAt: m['created_at'] as int,
            ))
        .toList(growable: false);
  }

  /// Insert a profile. Returns null if the name is empty / duplicate.
  Future<ProfileRow?> createProfile(String name) async {
    final db = await _open();
    if (db == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = await db.insert(
        'profiles',
        {'name': trimmed, 'created_at': now},
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return ProfileRow(id: id, name: trimmed, createdAt: now);
    } catch (_) {
      return null;
    }
  }

  Future<bool> renameProfile(int id, String name) async {
    final db = await _open();
    if (db == null) return false;
    final t = name.trim();
    if (t.isEmpty) return false;
    try {
      final n = await db.update(
        'profiles',
        {'name': t},
        where: 'id = ?',
        whereArgs: [id],
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return n > 0;
    } catch (_) {
      return false;
    }
  }

  /// Delete a profile and (via FK CASCADE) its tags + sentences.
  /// Refuses if this is the only remaining profile.
  Future<bool> deleteProfile(int id) async {
    final db = await _open();
    if (db == null) return false;
    final c = await db.rawQuery('SELECT COUNT(*) AS n FROM profiles');
    final total = (c.first['n'] as int?) ?? 0;
    if (total <= 1) return false;
    final n = await db.delete('profiles', where: 'id = ?', whereArgs: [id]);
    return n > 0;
  }

  /// Case-insensitive lookup of a profile by name — used by importer
  /// to slot bundle contents into the local profile that shares the
  /// same name. Creates one if nothing matches.
  Future<ProfileRow> findOrCreateProfileByName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Profile name is required');
    }
    final db = await _open();
    if (db == null) {
      throw StateError('DB not ready — cannot resolve profile "$trimmed"');
    }
    final existing = await db.query(
      'profiles',
      where: 'name = ? COLLATE NOCASE',
      whereArgs: [trimmed],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final m = existing.first;
      return ProfileRow(
        id: m['id'] as int,
        name: m['name'] as String,
        createdAt: m['created_at'] as int,
      );
    }
    final created = await createProfile(trimmed);
    if (created != null) return created;
    // Duplicate-race fallback — re-select and return whatever won.
    final again = await db.query(
      'profiles',
      where: 'name = ? COLLATE NOCASE',
      whereArgs: [trimmed],
      limit: 1,
    );
    if (again.isEmpty) {
      throw StateError('Failed to create profile "$trimmed"');
    }
    final m = again.first;
    return ProfileRow(
      id: m['id'] as int,
      name: m['name'] as String,
      createdAt: m['created_at'] as int,
    );
  }

  /// (tagCount, sentenceCount) for the management UI.
  Future<({int tagCount, int sentenceCount})> profileStats(int id) async {
    final db = await _open();
    if (db == null) return (tagCount: 0, sentenceCount: 0);
    final t = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM tags WHERE profile_id = ?',
      [id],
    );
    final s = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM sentences WHERE profile_id = ?',
      [id],
    );
    return (
      tagCount: (t.first['n'] as int?) ?? 0,
      sentenceCount: (s.first['n'] as int?) ?? 0,
    );
  }

  // ---------- Tag CRUD ----------

  Future<List<TagRow>> listTags(int profileId) async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.query(
      'tags',
      where: 'profile_id = ?',
      whereArgs: [profileId],
      orderBy: 'created_at ASC',
    );
    return rows.map(TagRow.fromMap).toList(growable: false);
  }

  /// Insert a tag in [profileId]. Returns null on duplicate name within
  /// the profile (names are unique per-profile, case-insensitive).
  Future<TagRow?> createTag(int profileId, String name, String color) async {
    final db = await _open();
    if (db == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final id = await db.insert(
        'tags',
        {
          'profile_id': profileId,
          'name': trimmed,
          'color': color,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return TagRow(id: id, profileId: profileId, name: trimmed, color: color);
    } catch (_) {
      return null;
    }
  }

  /// Rename and/or recolor an existing tag. Returns true when the row
  /// was found and updated; false when [id] doesn't exist. Either field
  /// can be null to leave it as-is.
  Future<bool> updateTag(int id, {String? name, String? color}) async {
    final db = await _open();
    if (db == null) return false;
    final fields = <String, Object?>{};
    if (name != null) {
      final t = name.trim();
      if (t.isEmpty) return false;
      fields['name'] = t;
    }
    if (color != null) fields['color'] = color;
    if (fields.isEmpty) return false;
    final n = await db.update('tags', fields, where: 'id = ?', whereArgs: [id]);
    return n > 0;
  }

  Future<bool> deleteTag(int id) async {
    final db = await _open();
    if (db == null) return false;
    final n = await db.delete('tags', where: 'id = ?', whereArgs: [id]);
    return n > 0;
  }

  /// Count sentences currently tagged with [tagId]. Used for the
  /// "<N> sentences are tagged with X. Delete anyway?" confirm dialog.
  Future<int> countSentencesForTag(int tagId) async {
    final db = await _open();
    if (db == null) return 0;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM sentence_tags WHERE tag_id = ?',
      [tagId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Dump raw table counts + a sample of sentence_tags / tags rows so we
  /// can diagnose link-table breakage from a single string.
  Future<String> diagnosticsSnapshot() async {
    final db = await _open();
    if (db == null) return 'db=null';
    Future<int> count(String t) async {
      final r = await db.rawQuery('SELECT COUNT(*) AS n FROM $t');
      return (r.first['n'] as int?) ?? 0;
    }
    final tagsN = await count('tags');
    final sentN = await count('sentences');
    final stN = await count('sentence_tags');
    final pagesN = await count('pages');
    final profN = await count('profiles');
    final stSample = await db.rawQuery(
      'SELECT sentence_id, tag_id FROM sentence_tags LIMIT 5',
    );
    final tagSample = await db.rawQuery(
      'SELECT id, profile_id, name FROM tags LIMIT 5',
    );
    final sentSample = await db.rawQuery(
      'SELECT id, profile_id FROM sentences LIMIT 5',
    );
    final stRefMissing = await db.rawQuery('''
      SELECT COUNT(*) AS n FROM sentence_tags st
      WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.id = st.tag_id)
    ''');
    return 'profiles=$profN pages=$pagesN tags=$tagsN '
        'sentences=$sentN sentence_tags=$stN '
        'st_with_missing_tag_fk=${(stRefMissing.first['n'] as int?) ?? 0} '
        'st_sample=$stSample tag_sample=$tagSample sent_sample=$sentSample';
  }

  /// One-shot repair attempt: if every sentence_tags row points at a
  /// missing tag_id (FK chain broken), do nothing for now and report.
  /// If there exist tags but the user's sentence_tags is empty, also
  /// report. Caller wires this to a debug button so it never runs
  /// silently.
  Future<String> repairBrokenTagLinks() async {
    final db = await _open();
    if (db == null) return 'db=null';
    // Find sentence_tags rows whose tag_id no longer points to a real tag.
    final dangling = await db.rawQuery('''
      SELECT st.sentence_id, st.tag_id FROM sentence_tags st
      WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.id = st.tag_id)
      LIMIT 20
    ''');
    return 'dangling_sample=$dangling';
  }

  // ---------- Page / sentence write ----------

  /// Insert or update a sentence with its tag set. Identity is
  /// (page, text, prev_fp, next_fp); re-insert is idempotent. The tag
  /// set is REPLACED (not union'd) so the caller can deselect existing
  /// tags during a re-edit. [mask] is the optional replacement text
  /// shown when the "Show masks" toggle is on; passing null preserves
  /// any existing mask, passing '' clears it.
  Future<int?> upsertSentenceWithTags({
    required int profileId,
    required String surface,
    required String locator,
    String? title,
    required String text,
    String? prevFp,
    String? nextFp,
    required List<int> tagIds,
    String? mask,
  }) async {
    final db = await _open();
    if (db == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<int>((tx) async {
      // pages: upsert by (surface, locator); bump last_seen_at + title.
      await tx.insert(
        'pages',
        {
          'surface': surface,
          'locator': locator,
          'title': title,
          'last_seen_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final pageRows = await tx.query(
        'pages',
        columns: ['id'],
        where: 'surface = ? AND locator = ?',
        whereArgs: [surface, locator],
        limit: 1,
      );
      final pageId = pageRows.first['id'] as int;
      if (title != null) {
        await tx.update(
          'pages',
          {'title': title, 'last_seen_at': now},
          where: 'id = ?',
          whereArgs: [pageId],
        );
      } else {
        await tx.update(
          'pages',
          {'last_seen_at': now},
          where: 'id = ?',
          whereArgs: [pageId],
        );
      }
      // sentences: upsert by full identity tuple (now incl. profile_id).
      await tx.insert(
        'sentences',
        {
          'profile_id': profileId,
          'page_id': pageId,
          'text': text,
          'prev_fp': prevFp,
          'next_fp': nextFp,
          'mask': mask,
          'created_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final sentRows = await tx.query(
        'sentences',
        columns: ['id'],
        where:
            'profile_id = ? AND page_id = ? AND text = ? AND IFNULL(prev_fp, "") = IFNULL(?, "") AND IFNULL(next_fp, "") = IFNULL(?, "")',
        whereArgs: [profileId, pageId, text, prevFp, nextFp],
        limit: 1,
      );
      final sentenceId = sentRows.first['id'] as int;
      // Update mask on the row. null means "leave existing mask alone";
      // '' means "clear the mask"; any other string overwrites.
      if (mask != null) {
        await tx.update(
          'sentences',
          {'mask': mask.isEmpty ? null : mask},
          where: 'id = ?',
          whereArgs: [sentenceId],
        );
      }
      // sentence_tags: replace the set.
      await tx.delete(
        'sentence_tags',
        where: 'sentence_id = ?',
        whereArgs: [sentenceId],
      );
      for (final tagId in tagIds) {
        await tx.insert(
          'sentence_tags',
          {'sentence_id': sentenceId, 'tag_id': tagId},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      return sentenceId;
    });
  }

  // ---------- Page read (rehydrate) ----------

  /// Tagged sentences on a page, joined with their tag rows. Used by
  /// the page-load rehydrate hook to push state into the WebView.
  Future<List<SentenceWithTags>> sentencesForPage({
    required int profileId,
    required String surface,
    required String locator,
  }) async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.rawQuery(
      '''
      SELECT s.id AS sid, s.text, s.prev_fp, s.next_fp, s.mask,
             t.id AS tid, t.name AS tname, t.color AS tcolor
      FROM sentences s
      JOIN pages p ON p.id = s.page_id
      LEFT JOIN sentence_tags st ON st.sentence_id = s.id
      LEFT JOIN tags t ON t.id = st.tag_id
      WHERE s.profile_id = ? AND p.surface = ? AND p.locator = ?
      ORDER BY s.id, t.created_at
      ''',
      [profileId, surface, locator],
    );
    final out = <int, SentenceWithTags>{};
    for (final r in rows) {
      final sid = r['sid'] as int;
      final s = out.putIfAbsent(
        sid,
        () => SentenceWithTags(
          id: sid,
          text: r['text'] as String,
          prevFp: r['prev_fp'] as String?,
          nextFp: r['next_fp'] as String?,
          mask: r['mask'] as String?,
          tags: [],
        ),
      );
      final tid = r['tid'] as int?;
      if (tid != null) {
        s.tags.add(TagRow(
          id: tid,
          profileId: profileId,
          name: r['tname'] as String,
          color: r['tcolor'] as String,
        ));
      }
    }
    // Fold in distinct media kinds per sentence via one side query.
    // URL rows collapse to 'link' regardless of extension-inferred
    // media class so the JS marker can pick a link icon reliably.
    if (out.isNotEmpty) {
      final mediaRows = await db.rawQuery('''
        SELECT sm.sentence_id AS sid,
               sm.kind AS kind,
               CASE WHEN sm.url IS NOT NULL AND sm.url <> '' THEN 1 ELSE 0 END AS is_url
        FROM sentence_media sm
        JOIN sentences s ON s.id = sm.sentence_id
        JOIN pages p ON p.id = s.page_id
        WHERE s.profile_id = ? AND p.surface = ? AND p.locator = ?
      ''', [profileId, surface, locator]);
      final kindsBySid = <int, Set<String>>{};
      for (final r in mediaRows) {
        final sid = r['sid'] as int;
        final isUrl = (r['is_url'] as int? ?? 0) == 1;
        final k = isUrl ? 'link' : (r['kind'] as String);
        kindsBySid.putIfAbsent(sid, () => <String>{}).add(k);
      }
      return out.values
          .map((s) => s.withMediaKinds(kindsBySid[s.id] ?? const {}))
          .toList(growable: false);
    }
    return out.values.toList(growable: false);
  }

  /// All tagged sentences for [profileId] across every page, joined
  /// with their tag rows + the owning page's surface/locator/title.
  /// Used by the global "Browse tagged sentences" screen. Sorted by
  /// page's last_seen_at DESC, then sentence id ASC within a page.
  Future<List<TaggedSentenceRow>> allTaggedSentences(int profileId) async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.rawQuery('''
      SELECT s.id AS sid, s.profile_id AS psid, s.text, s.prev_fp, s.next_fp, s.mask,
             p.surface, p.locator, p.title, p.last_seen_at,
             t.id AS tid, t.name AS tname, t.color AS tcolor
      FROM sentences s
      JOIN pages p ON p.id = s.page_id
      LEFT JOIN sentence_tags st ON st.sentence_id = s.id
      LEFT JOIN tags t ON t.id = st.tag_id
      WHERE s.profile_id = ?
      ORDER BY p.last_seen_at DESC, s.id ASC, t.created_at ASC
    ''', [profileId]);
    // Collapse repeated (sentence × tag) join rows into one row per
    // sentence. The ordering above keeps a single sentence's rows
    // contiguous so a small running buffer is enough.
    final out = <int, TaggedSentenceRow>{};
    for (final r in rows) {
      final sid = r['sid'] as int;
      var entry = out[sid];
      if (entry == null) {
        entry = TaggedSentenceRow(
          profileId: r['psid'] as int,
          surface: r['surface'] as String,
          locator: r['locator'] as String,
          pageTitle: r['title'] as String?,
          lastSeenAt: r['last_seen_at'] as int,
          sentence: SentenceWithTags(
            id: sid,
            text: r['text'] as String,
            prevFp: r['prev_fp'] as String?,
            nextFp: r['next_fp'] as String?,
            mask: r['mask'] as String?,
            tags: [],
          ),
        );
        out[sid] = entry;
      }
      final tid = r['tid'] as int?;
      if (tid != null) {
        entry.sentence.tags.add(TagRow(
          id: tid,
          profileId: r['psid'] as int,
          name: r['tname'] as String,
          color: r['tcolor'] as String,
        ));
      }
    }
    // Fold in distinct media kinds per sentence via one side query
    // instead of another join (which would multiply the tag rows).
    // URL rows collapse to a 'link' kind so the browser can show a
    // link icon regardless of the pathname-inferred media class.
    final mediaRows = await db.rawQuery('''
      SELECT sm.sentence_id AS sid,
             sm.kind AS kind,
             CASE WHEN sm.url IS NOT NULL AND sm.url <> '' THEN 1 ELSE 0 END AS is_url
      FROM sentence_media sm
      JOIN sentences s ON s.id = sm.sentence_id
      WHERE s.profile_id = ?
    ''', [profileId]);
    final kindsBySid = <int, Set<String>>{};
    for (final r in mediaRows) {
      final sid = r['sid'] as int;
      final isUrl = (r['is_url'] as int? ?? 0) == 1;
      final k = isUrl ? 'link' : (r['kind'] as String);
      kindsBySid.putIfAbsent(sid, () => <String>{}).add(k);
    }
    // Rebuild the returned list so mediaKinds is populated (rows in
    // `out` were constructed with the default empty set).
    return out.values
        .map((r) => r.withMediaKinds(kindsBySid[r.sentence.id] ?? const {}))
        .toList(growable: false);
  }

  /// Delete a single sentence + its tag links. Used by the Browse
  /// screen's swipe-to-delete affordance.
  Future<bool> deleteSentence(int id) async {
    final db = await _open();
    if (db == null) return false;
    final n = await db.delete('sentences', where: 'id = ?', whereArgs: [id]);
    return n > 0;
  }

  /// Fetch a single sentence row by DB id, joined with its tag set
  /// AND the owning page (surface + locator + title). Used by the
  /// edit flow — the page metadata is needed so a re-upsert lands on
  /// the original page row instead of treating the edit as a new
  /// capture on whatever page the user is currently viewing.
  Future<TaggedSentenceRow?> sentenceById(int id) async {
    final db = await _open();
    if (db == null) return null;
    final rows = await db.rawQuery(
      '''
      SELECT s.id AS sid, s.profile_id AS psid, s.text, s.prev_fp, s.next_fp, s.mask,
             p.surface, p.locator, p.title, p.last_seen_at,
             t.id AS tid, t.name AS tname, t.color AS tcolor
      FROM sentences s
      JOIN pages p ON p.id = s.page_id
      LEFT JOIN sentence_tags st ON st.sentence_id = s.id
      LEFT JOIN tags t ON t.id = st.tag_id
      WHERE s.id = ?
      ORDER BY t.created_at
      ''',
      [id],
    );
    if (rows.isEmpty) return null;
    final profileId = rows.first['psid'] as int;
    final row = TaggedSentenceRow(
      profileId: profileId,
      surface: rows.first['surface'] as String,
      locator: rows.first['locator'] as String,
      pageTitle: rows.first['title'] as String?,
      lastSeenAt: rows.first['last_seen_at'] as int,
      sentence: SentenceWithTags(
        id: rows.first['sid'] as int,
        text: rows.first['text'] as String,
        prevFp: rows.first['prev_fp'] as String?,
        nextFp: rows.first['next_fp'] as String?,
        mask: rows.first['mask'] as String?,
        tags: [],
      ),
    );
    for (final r in rows) {
      final tid = r['tid'] as int?;
      if (tid != null) {
        row.sentence.tags.add(TagRow(
          id: tid,
          profileId: profileId,
          name: r['tname'] as String,
          color: r['tcolor'] as String,
        ));
      }
    }
    return row;
  }

  /// Existing row + tag set for a sentence identified by its full
  /// identity tuple. Used to pre-populate the capture sheet when the
  /// user taps a previously-tagged sentence in capture mode. Returns
  /// null if no row exists.
  Future<SentenceWithTags?> sentenceByIdentity({
    required int profileId,
    required String surface,
    required String locator,
    required String text,
    String? prevFp,
    String? nextFp,
  }) async {
    final db = await _open();
    if (db == null) return null;
    final rows = await db.rawQuery(
      '''
      SELECT s.id AS sid, s.text, s.prev_fp, s.next_fp, s.mask,
             t.id AS tid, t.name AS tname, t.color AS tcolor
      FROM sentences s
      JOIN pages p ON p.id = s.page_id
      LEFT JOIN sentence_tags st ON st.sentence_id = s.id
      LEFT JOIN tags t ON t.id = st.tag_id
      WHERE s.profile_id = ? AND p.surface = ? AND p.locator = ? AND s.text = ?
        AND IFNULL(s.prev_fp, "") = IFNULL(?, "")
        AND IFNULL(s.next_fp, "") = IFNULL(?, "")
      ORDER BY t.created_at
      ''',
      [profileId, surface, locator, text, prevFp, nextFp],
    );
    if (rows.isEmpty) return null;
    final s = SentenceWithTags(
      id: rows.first['sid'] as int,
      text: rows.first['text'] as String,
      prevFp: rows.first['prev_fp'] as String?,
      nextFp: rows.first['next_fp'] as String?,
      mask: rows.first['mask'] as String?,
      tags: [],
    );
    for (final r in rows) {
      final tid = r['tid'] as int?;
      if (tid != null) {
        s.tags.add(TagRow(
          id: tid,
          profileId: profileId,
          name: r['tname'] as String,
          color: r['tcolor'] as String,
        ));
      }
    }
    return s;
  }

  // ---------- Media attachments ----------

  Future<List<MediaRow>> listMediaForSentence(int sentenceId) async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.query(
      'sentence_media',
      where: 'sentence_id = ?',
      whereArgs: [sentenceId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(MediaRow.fromMap).toList();
  }

  Future<MediaRow?> addSentenceMedia({
    required int sentenceId,
    required String kind,
    required String sha1,
    required String filename,
    String? url,
    String? mimeType,
    int? sizeBytes,
  }) async {
    final db = await _open();
    if (db == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('sentence_media', {
      'sentence_id': sentenceId,
      'kind': kind,
      'sha1': sha1,
      'url': url,
      'mime_type': mimeType,
      'filename': filename,
      'size_bytes': sizeBytes,
      'created_at': now,
    });
    return MediaRow(
      id: id,
      sentenceId: sentenceId,
      kind: kind,
      sha1: sha1,
      url: url,
      mimeType: mimeType,
      filename: filename,
      sizeBytes: sizeBytes,
      createdAt: now,
    );
  }

  /// Delete a media row. Returns the row's SHA-1 iff this was the last
  /// row referencing that hash — the caller uses that to decide whether
  /// to also delete the underlying file from disk. Returns null when
  /// the row didn't exist, was a URL attachment (no file), or its file
  /// is still referenced elsewhere.
  Future<String?> deleteMediaReturningOrphanSha1(int mediaId) async {
    final db = await _open();
    if (db == null) return null;
    final rows = await db.query(
      'sentence_media',
      columns: ['sha1', 'url'],
      where: 'id = ?',
      whereArgs: [mediaId],
    );
    if (rows.isEmpty) return null;
    final sha1 = (rows.first['sha1'] as String?) ?? '';
    final url = (rows.first['url'] as String?) ?? '';
    await db.delete('sentence_media', where: 'id = ?', whereArgs: [mediaId]);
    // URL attachments don't own a file — nothing to gc.
    if (url.isNotEmpty || sha1.isEmpty) return null;
    final refs = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM sentence_media WHERE sha1 = ? AND (url IS NULL OR url = "")',
      [sha1],
    );
    final n = (refs.first['n'] as int?) ?? 0;
    return n == 0 ? sha1 : null;
  }

  /// All media rows for a profile joined with their owning sentence's
  /// text / page metadata. Used by the media-manager screen in the tag
  /// browser to show every attachment across the profile in one place.
  Future<List<MediaWithSentenceRow>> listAllMediaForProfile(int profileId) async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.rawQuery('''
      SELECT sm.*, s.text AS sentence_text, s.mask AS sentence_mask,
             p.surface AS page_surface, p.locator AS page_locator, p.title AS page_title
      FROM sentence_media sm
      JOIN sentences s ON s.id = sm.sentence_id
      JOIN pages p ON p.id = s.page_id
      WHERE s.profile_id = ?
      ORDER BY sm.created_at DESC, sm.id DESC
    ''', [profileId]);
    return rows.map(MediaWithSentenceRow.fromMap).toList(growable: false);
  }

  /// Image media rows for every tagged sentence on a page, keyed by
  /// the sentence's DB id. Used by the EPUB reader's "show maskover
  /// pictures" toggle to substitute an image for the mask text when
  /// the tagged sentence owns at least one image attachment.
  ///
  /// Only rows with `kind = 'image'` are returned. If multiple images
  /// exist per sentence the first one (by `created_at`) wins — enough
  /// for the current mask-substitution use case; the media manager
  /// exposes the full set for detail views.
  Future<Map<int, MediaRow>> imageMediaByDbidForPage({
    required int profileId,
    required String surface,
    required String locator,
  }) async {
    final db = await _open();
    if (db == null) return const {};
    final rows = await db.rawQuery('''
      SELECT sm.*
      FROM sentence_media sm
      JOIN sentences s ON s.id = sm.sentence_id
      JOIN pages p ON p.id = s.page_id
      WHERE s.profile_id = ? AND p.surface = ? AND p.locator = ?
        AND sm.kind = 'image'
      ORDER BY sm.sentence_id, sm.created_at ASC, sm.id ASC
    ''', [profileId, surface, locator]);
    final out = <int, MediaRow>{};
    for (final r in rows) {
      final row = MediaRow.fromMap(r);
      // First-wins per sentence.
      out.putIfAbsent(row.sentenceId, () => row);
    }
    return out;
  }

  // ── Playlists ────────────────────────────────────────────────────
  // User-created lists of captured EPUB sentences. Delivered to the
  // language WebView (dialog1) as manual-card decks. Items snapshot
  // their book / chapter labels so a re-imported EPUB (which gets new
  // internal ids) doesn't break the visible card.

  Future<List<PlaylistRow>> listPlaylists() async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.query('playlists', orderBy: 'created_at ASC, id ASC');
    return rows.map(PlaylistRow.fromMap).toList(growable: false);
  }

  Future<PlaylistRow?> createPlaylist(String name) async {
    final db = await _open();
    if (db == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('playlists', {'name': name, 'created_at': now});
    return PlaylistRow(id: id, name: name, createdAt: now);
  }

  Future<void> renamePlaylist(int id, String newName) async {
    final db = await _open();
    if (db == null) return;
    await db.update('playlists', {'name': newName}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deletePlaylist(int id) async {
    final db = await _open();
    if (db == null) return;
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<PlaylistItemRow>> listPlaylistItems(int playlistId) async {
    final db = await _open();
    if (db == null) return const [];
    final rows = await db.query(
      'playlist_items',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position ASC, id ASC',
    );
    return rows.map(PlaylistItemRow.fromMap).toList(growable: false);
  }

  /// Append a new item to the end of [playlistId]. Deduped on
  /// (playlist_id, sentence_text, book_key, chapter_idx) so re-tapping
  /// the same sentence in armed capture mode is a no-op instead of
  /// bloating the list.
  Future<PlaylistItemRow?> addPlaylistItem({
    required int playlistId,
    required String sentenceText,
    String? bookKey,
    String? bookTitle,
    int? chapterIdx,
    String? chapterTitle,
  }) async {
    final db = await _open();
    if (db == null) return null;
    final existing = await db.query(
      'playlist_items',
      where: 'playlist_id = ? AND sentence_text = ? '
          'AND IFNULL(book_key,"") = IFNULL(?,"") '
          'AND IFNULL(chapter_idx,-1) = IFNULL(?,-1)',
      whereArgs: [playlistId, sentenceText, bookKey, chapterIdx],
      limit: 1,
    );
    if (existing.isNotEmpty) return PlaylistItemRow.fromMap(existing.first);
    final maxPosRow = await db.rawQuery(
      'SELECT COALESCE(MAX(position), -1) AS m FROM playlist_items WHERE playlist_id = ?',
      [playlistId],
    );
    final nextPos = ((maxPosRow.first['m'] as int?) ?? -1) + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('playlist_items', {
      'playlist_id': playlistId,
      'sentence_text': sentenceText,
      'book_key': bookKey,
      'book_title': bookTitle,
      'chapter_idx': chapterIdx,
      'chapter_title': chapterTitle,
      'position': nextPos,
      'created_at': now,
    });
    return PlaylistItemRow(
      id: id,
      playlistId: playlistId,
      sentenceText: sentenceText,
      bookKey: bookKey,
      bookTitle: bookTitle,
      chapterIdx: chapterIdx,
      chapterTitle: chapterTitle,
      position: nextPos,
      createdAt: now,
    );
  }

  Future<void> deletePlaylistItem(int id) async {
    final db = await _open();
    if (db == null) return;
    await db.delete('playlist_items', where: 'id = ?', whereArgs: [id]);
  }

  /// Rewrite [playlistId]'s items to the given order. Caller passes
  /// item ids in the desired sequence — positions are re-numbered from
  /// 0 in a single transaction so a partial failure can't leave the
  /// list scrambled.
  Future<void> reorderPlaylistItems(int playlistId, List<int> orderedIds) async {
    final db = await _open();
    if (db == null) return;
    await db.transaction((tx) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await tx.update(
          'playlist_items',
          {'position': i},
          where: 'id = ? AND playlist_id = ?',
          whereArgs: [orderedIds[i], playlistId],
        );
      }
    });
  }

  /// Sum of on-disk bytes for every file-backed media row attached to
  /// sentences on pages matching a locator. When [prefixMatch] is true
  /// (EPUB — use the `epub:<sha>:` prefix so all chapters roll up to
  /// the book) the query uses LIKE; otherwise it's an exact match.
  /// URL rows carry size_bytes = NULL and don't contribute to the sum.
  Future<int> mediaBytesForLocator({
    required int profileId,
    required String surface,
    required String locator,
    bool prefixMatch = false,
  }) async {
    final db = await _open();
    if (db == null) return 0;
    final where = prefixMatch ? 'p.locator LIKE ?' : 'p.locator = ?';
    final arg = prefixMatch ? '$locator%' : locator;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(sm.size_bytes), 0) AS n '
      'FROM sentence_media sm '
      'JOIN sentences s ON s.id = sm.sentence_id '
      'JOIN pages p ON p.id = s.page_id '
      'WHERE s.profile_id = ? AND p.surface = ? AND $where',
      [profileId, surface, arg],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Per-book breakdown for the memory manager. Groups pages by EPUB
  /// book_key (the second segment of the locator), aggregating sentence
  /// counts, tag counts, media rows, and total media bytes. URL media
  /// rows carry NULL size_bytes so they don't inflate the byte total.
  ///
  /// When [profileId] is null the stats span all profiles — this is
  /// what the memory manager wants since on-disk storage is shared
  /// across profiles.
  Future<List<BookMemoryStat>> perBookMemoryStats({int? profileId}) async {
    final db = await _open();
    if (db == null) return const [];
    // SQLite doesn't have a direct 'split' — we rely on locator format
    // `epub:<sha>:<chapter>` and take the substring between the two
    // colons as the book key. GROUP BY that computed key.
    final profileFilter = profileId == null ? '' : 'AND s.profile_id = ?';
    final args = profileId == null ? <Object?>[] : <Object?>[profileId];
    final rows = await db.rawQuery('''
      SELECT
        SUBSTR(p.locator, 6, INSTR(SUBSTR(p.locator, 6), ':') - 1) AS book_key,
        COUNT(DISTINCT s.id) AS sentence_count,
        COUNT(DISTINCT st.tag_id) AS tag_count,
        COUNT(DISTINCT sm.id) AS media_count,
        COALESCE(SUM(DISTINCT sm.size_bytes), 0) AS media_bytes
      FROM pages p
      LEFT JOIN sentences s ON s.page_id = p.id $profileFilter
      LEFT JOIN sentence_tags st ON st.sentence_id = s.id
      LEFT JOIN sentence_media sm ON sm.sentence_id = s.id
      WHERE p.surface = 'epub'
      GROUP BY book_key
      HAVING sentence_count > 0
      ORDER BY media_bytes DESC, sentence_count DESC
    ''', args);
    return [
      for (final r in rows)
        BookMemoryStat(
          bookKey: (r['book_key'] as String?) ?? '',
          sentenceCount: (r['sentence_count'] as num?)?.toInt() ?? 0,
          tagCount: (r['tag_count'] as num?)?.toInt() ?? 0,
          mediaCount: (r['media_count'] as num?)?.toInt() ?? 0,
          mediaBytes: (r['media_bytes'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// Delete every DB row scoped to a specific EPUB book — pages,
  /// sentences, sentence_tags (via CASCADE), sentence_media (via
  /// CASCADE). Also wipes playlist_items pointing at this book. Media
  /// files on disk are handled by the caller (it should call
  /// [referencedFileSha1s] + [MediaStore.deleteOrphans] afterwards).
  /// Tags themselves are preserved — a tag lives across books.
  Future<void> deleteBookData({
    required int profileId,
    required String bookKey,
  }) async {
    final db = await _open();
    if (db == null) return;
    await db.transaction((tx) async {
      // Pages for this book. CASCADE on `page_id` will drop sentences,
      // which CASCADEs through sentence_tags + sentence_media.
      await tx.delete(
        'pages',
        where: "surface = 'epub' AND locator LIKE ?",
        whereArgs: ['epub:$bookKey:%'],
      );
      await tx.delete(
        'playlist_items',
        where: 'book_key = ?',
        whereArgs: [bookKey],
      );
    });
  }

  /// Size of the on-disk sqlite file in bytes. Used by the memory
  /// manager to include the DB in the storage summary. Returns 0 if
  /// the file isn't yet accessible.
  Future<int> dbFileBytes() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// Every SHA-1 currently referenced by at least one file-backed media
  /// row. Callers cross-reference this against the on-disk bucket to
  /// find orphan files (row was deleted but the bytes remain).
  Future<Set<String>> referencedFileSha1s() async {
    final db = await _open();
    if (db == null) return const {};
    final rows = await db.rawQuery(
      'SELECT DISTINCT sha1 FROM sentence_media WHERE (url IS NULL OR url = "") AND sha1 <> ""',
    );
    return {for (final r in rows) r['sha1'] as String};
  }

  /// Reverse of the orphan-file check: rows that reference a SHA-1 not
  /// present in [onDiskSha1s] are dangling — file was deleted (manually,
  /// during a partial import, or across an app-data restore) but the
  /// row still points at nothing. Drop them so Clean leaves the store
  /// consistent in both directions.
  Future<int> deleteMediaRowsForMissingFiles(Set<String> onDiskSha1s) async {
    final db = await _open();
    if (db == null) return 0;
    final all = await db.query(
      'sentence_media',
      columns: ['id', 'sha1'],
      where: '(url IS NULL OR url = "") AND sha1 <> ""',
    );
    final missing = <int>[
      for (final r in all)
        if (!onDiskSha1s.contains(r['sha1'] as String)) r['id'] as int,
    ];
    if (missing.isEmpty) return 0;
    // Chunk deletes so we don't blow the SQLite variable limit on a
    // huge sweep. 500 per batch is well under the default 999 cap.
    var removed = 0;
    for (var i = 0; i < missing.length; i += 500) {
      final chunk = missing.sublist(i, i + 500 > missing.length ? missing.length : i + 500);
      final placeholders = List.filled(chunk.length, '?').join(',');
      removed += await db.delete(
        'sentence_media',
        where: 'id IN ($placeholders)',
        whereArgs: chunk,
      );
    }
    return removed;
  }
}

// ---------- Plain rows ----------

class ProfileRow {
  final int id;
  final String name;
  final int createdAt;
  const ProfileRow({required this.id, required this.name, required this.createdAt});
}

/// Per-book storage rollup for the memory manager. Populated by
/// [CupitorDb.perBookMemoryStats]. Book title/path aren't tracked in
/// the DB — the manager screen joins these against `EpubLibrary`
/// (loaded from prefs) to render human-readable rows.
class BookMemoryStat {
  final String bookKey;
  final int sentenceCount;
  final int tagCount;
  final int mediaCount;
  final int mediaBytes;
  const BookMemoryStat({
    required this.bookKey,
    required this.sentenceCount,
    required this.tagCount,
    required this.mediaCount,
    required this.mediaBytes,
  });
}

class PlaylistRow {
  final int id;
  final String name;
  final int createdAt;
  const PlaylistRow({required this.id, required this.name, required this.createdAt});

  static PlaylistRow fromMap(Map<String, Object?> m) => PlaylistRow(
        id: m['id'] as int,
        name: m['name'] as String,
        createdAt: m['created_at'] as int,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'created_at': createdAt,
      };
}

class PlaylistItemRow {
  final int id;
  final int playlistId;
  final String sentenceText;
  final String? bookKey;
  final String? bookTitle;
  final int? chapterIdx;
  final String? chapterTitle;
  final int position;
  final int createdAt;
  const PlaylistItemRow({
    required this.id,
    required this.playlistId,
    required this.sentenceText,
    required this.bookKey,
    required this.bookTitle,
    required this.chapterIdx,
    required this.chapterTitle,
    required this.position,
    required this.createdAt,
  });

  static PlaylistItemRow fromMap(Map<String, Object?> m) => PlaylistItemRow(
        id: m['id'] as int,
        playlistId: m['playlist_id'] as int,
        sentenceText: m['sentence_text'] as String,
        bookKey: m['book_key'] as String?,
        bookTitle: m['book_title'] as String?,
        chapterIdx: (m['chapter_idx'] as num?)?.toInt(),
        chapterTitle: m['chapter_title'] as String?,
        position: (m['position'] as num?)?.toInt() ?? 0,
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'text': sentenceText,
        'book_key': bookKey,
        'book_title': bookTitle,
        'chapter_idx': chapterIdx,
        'chapter_title': chapterTitle,
        'position': position,
        'created_at': createdAt,
      };
}

class TagRow {
  final int id;
  final int profileId;
  final String name;
  final String color;
  const TagRow({
    required this.id,
    required this.profileId,
    required this.name,
    required this.color,
  });

  static TagRow fromMap(Map<String, Object?> m) => TagRow(
        id: m['id'] as int,
        profileId: (m['profile_id'] as int?) ?? CupitorDb.defaultProfileId,
        name: m['name'] as String,
        color: m['color'] as String,
      );
}

/// A tagged sentence + the page it lives on. Used by the global
/// "Browse tagged sentences" screen, which needs page metadata for
/// grouping / sorting / navigating back.
class TaggedSentenceRow {
  final int profileId;
  final String surface;     // 'web' | 'epub'
  final String locator;     // canonical URL or 'epub:<sha>:<chap>'
  final String? pageTitle;
  final int lastSeenAt;     // ms since epoch
  final SentenceWithTags sentence;
  /// Distinct kinds of media attached to this sentence — subset of
  /// {'image','audio','video','link'}. Populated by
  /// [CupitorDb.allTaggedSentences] / [CupitorDb.sentenceById] via a
  /// side query so the browser can show media-kind icons inline
  /// without a per-row DB round trip.
  final Set<String> mediaKinds;
  const TaggedSentenceRow({
    required this.profileId,
    required this.surface,
    required this.locator,
    required this.pageTitle,
    required this.lastSeenAt,
    required this.sentence,
    this.mediaKinds = const {},
  });

  TaggedSentenceRow withMediaKinds(Set<String> kinds) => TaggedSentenceRow(
        profileId: profileId,
        surface: surface,
        locator: locator,
        pageTitle: pageTitle,
        lastSeenAt: lastSeenAt,
        sentence: sentence,
        mediaKinds: kinds,
      );
}

class SentenceWithTags {
  final int id;
  final String text;
  final String? prevFp;
  final String? nextFp;
  final String? mask;
  final List<TagRow> tags;
  /// Distinct media kinds attached to this sentence — subset of
  /// {'image','audio','video','link'}. Populated by
  /// [CupitorDb.sentencesForPage] so the JS rehydration engine can
  /// paint a small leading icon on tagged sentences that own media.
  final Set<String> mediaKinds;
  SentenceWithTags({
    required this.id,
    required this.text,
    required this.prevFp,
    required this.nextFp,
    required this.mask,
    required this.tags,
    this.mediaKinds = const {},
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'prevFp': prevFp,
        'nextFp': nextFp,
        'mask': mask,
        'tagIds': tags.map((t) => t.id).toList(),
        'tagColors': tags.map((t) => t.color).toList(),
        'tagNames': tags.map((t) => t.name).toList(),
        'mediaKinds': mediaKinds.toList(),
      };

  SentenceWithTags withMediaKinds(Set<String> kinds) => SentenceWithTags(
        id: id,
        text: text,
        prevFp: prevFp,
        nextFp: nextFp,
        mask: mask,
        tags: tags,
        mediaKinds: kinds,
      );
}

/// One media attachment on a tagged sentence.
///
/// Two storage modes share this row:
///   • Local content-addressed file — [url] is null, [sha1] is the file's
///     SHA-1, resolved via [MediaStore] under `<docs>/sentence_media/…`.
///   • External URL — [url] is non-empty, [sha1] is an empty string; the
///     file bytes never touch disk and the OS handles playback.
class MediaRow {
  final int id;
  final int sentenceId;
  final String kind; // 'image' | 'audio' | 'video' | 'link'
  final String sha1;
  final String? url;
  final String? mimeType;
  final String filename;
  final int? sizeBytes;
  final int createdAt;
  const MediaRow({
    required this.id,
    required this.sentenceId,
    required this.kind,
    required this.sha1,
    required this.url,
    required this.mimeType,
    required this.filename,
    required this.sizeBytes,
    required this.createdAt,
  });

  bool get isUrl => (url ?? '').isNotEmpty;

  static MediaRow fromMap(Map<String, Object?> m) => MediaRow(
        id: m['id'] as int,
        sentenceId: m['sentence_id'] as int,
        kind: m['kind'] as String,
        sha1: (m['sha1'] as String?) ?? '',
        url: m['url'] as String?,
        mimeType: m['mime_type'] as String?,
        filename: m['filename'] as String,
        sizeBytes: (m['size_bytes'] as num?)?.toInt(),
        createdAt: m['created_at'] as int,
      );
}

/// A media row plus the sentence + page it belongs to. Returned by
/// [CupitorDb.listAllMediaForProfile] so the media manager can render
/// each attachment with its surrounding context without a second query.
class MediaWithSentenceRow {
  final MediaRow media;
  final String sentenceText;
  final String? sentenceMask;
  final String pageSurface;
  final String pageLocator;
  final String? pageTitle;
  const MediaWithSentenceRow({
    required this.media,
    required this.sentenceText,
    required this.sentenceMask,
    required this.pageSurface,
    required this.pageLocator,
    required this.pageTitle,
  });

  static MediaWithSentenceRow fromMap(Map<String, Object?> m) => MediaWithSentenceRow(
        media: MediaRow.fromMap(m),
        sentenceText: (m['sentence_text'] as String?) ?? '',
        sentenceMask: m['sentence_mask'] as String?,
        pageSurface: (m['page_surface'] as String?) ?? '',
        pageLocator: (m['page_locator'] as String?) ?? '',
        pageTitle: m['page_title'] as String?,
      );
}

// ---------- Identity helpers (must match assets/js/sentence_tag.js) ----------

/// Canonical URL: lowercase scheme+host, drop fragment, drop utm_*
/// params, alphabetize remaining params. Path preserved verbatim.
/// Used as the locator for surface='web'.
String canonUrl(String url) {
  Uri u;
  try {
    u = Uri.parse(url);
  } catch (_) {
    return url;
  }
  final scheme = u.scheme.toLowerCase();
  final host = u.host.toLowerCase();
  // Strip a single trailing slash (but keep root '/'). SPA routers
  // sometimes emit '/path/' on back-nav and '/path' on initial load —
  // we want both to canonicalize to the same locator.
  var path = u.path;
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final kept = <String, String>{};
  u.queryParameters.forEach((k, v) {
    if (!k.toLowerCase().startsWith('utm_')) kept[k] = v;
  });
  final keys = kept.keys.toList()..sort();
  final query = keys.map((k) => '$k=${Uri.encodeQueryComponent(kept[k]!)}').join('&');
  final port = u.hasPort ? ':${u.port}' : '';
  final origin = scheme.isEmpty ? '' : '$scheme://$host$port';
  return query.isEmpty ? '$origin$path' : '$origin$path?$query';
}

/// EPUB locator: 'epub:<book_sha>:<chapter_idx>'.
String epubLocator(String bookSha, int chapterIdx) =>
    'epub:$bookSha:$chapterIdx';

/// 8-char sha1 prefix of normalised text. Normalisation: lowercase →
/// collapse whitespace runs → strip ASCII punctuation. The JS-side
/// implementation in assets/js/sentence_tag.js MUST produce byte-for-byte
/// the same output (validated by [fpSelfTest] at startup in debug builds).
String fp(String s) {
  final norm = _normalize(s);
  if (norm.isEmpty) return '';
  final hash = sha1.convert(utf8.encode(norm)).toString();
  return hash.substring(0, 8);
}

String _normalize(String s) {
  var out = s.toLowerCase();
  // Strip the punctuation set the JS implementation also strips.
  // RegExp-safe character class: . , ! ? ; : ' " ( ) [ ] { } - — – …
  out = out.replaceAll(RegExp(r'''[.,!?;:'"()\[\]{}\-—–…]'''), '');
  // Collapse runs of whitespace to a single space, then trim.
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  return out;
}

/// Debug-build self-test for [fp] / canonical URL. Returns a map from
/// test name to "pass"/"fail:<expected>!=<got>". Cupitor calls this once
/// on launch in debug mode and pipes the result to SnippetLogChannel;
/// the JS side runs the same corpus and the two outputs are compared.
Map<String, String> fpSelfTest() {
  final cases = <String, String>{
    'empty': '',
    'single': 'Hello',
    'with_punct': 'Hello, World!',
    'whitespace_run': '  multiple   spaces\there',
    'mixed_case': 'CamelCase WORDS',
    'em_dash': 'one — two',
    'en_dash': 'one – two',
    'ellipsis': 'so…',
    'quotes': '"quoted" and \'single\'',
    'numbers': 'Page 42 of 100',
  };
  final out = <String, String>{};
  cases.forEach((k, v) {
    out[k] = fp(v);
  });
  return out;
}

Map<String, String> canonSelfTest() {
  final cases = <String, String>{
    'host_case': 'HTTPS://Example.COM/Path',
    'fragment': 'https://example.com/p#frag',
    'utm': 'https://example.com/p?utm_source=x&q=1',
    'sort': 'https://example.com/p?b=2&a=1',
  };
  final out = <String, String>{};
  cases.forEach((k, v) {
    out[k] = canonUrl(v);
  });
  return out;
}

/// Pretty toolbar/platform check: are we on a platform sqflite supports?
/// Android is fine; macOS host needs sqflite_common_ffi which we
/// deliberately did not include. Used to hide toolbar buttons on host.
bool get isSqlitePlatform => Platform.isAndroid || Platform.isIOS;
