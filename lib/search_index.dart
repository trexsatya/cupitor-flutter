import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// On-disk full-text index for the EPUB library.
///
/// Backed by SQLite FTS5 (`unicode61` tokenizer with diacritics
/// removed). One virtual table for the tokenized chapter text, one
/// companion table for per-book bookkeeping (title, size, last touch).
///
/// - **Persistent**: survives app restarts. First search after a fresh
///   install populates the index for every library book; subsequent
///   searches skip parsing and hit the index directly.
/// - **Byte-capped, LRU-evicted**: when adding a book would exceed
///   [capacityBytes], the least-recently-touched book is dropped
///   until the new one fits. Cap changes are persisted and enforced.
/// - **Query grammar** (translated to FTS5 MATCH):
///     `phrase`         → `"phrase"*` (word / prefix match on the
///                        last token; multi-word phrases match the
///                        exact adjacent-token sequence)
///     `foo|bar`        → `"foo"* OR "bar"*`
///     Case + diacritics are folded by the tokenizer.
///   NOTE: FTS5 is word-based, so this is **not** the old substring
///   match — searching `cat` no longer matches "concatenate". This is
///   a deliberate trade for scalable full-text search; a prefix wildcard
///   is added so "cat" still finds "cats" / "cathedral".
class SearchIndex {
  SearchIndex._();

  static const String _kPrefKey = 'searchIndexCapacityBytes';
  static const String _fileName = 'search_index.db';

  /// Default index size — generous because it's on disk, not RAM.
  static const int defaultCapacityBytes = 128 * 1024 * 1024;

  /// Presets surfaced in the settings UI. `0` == index disabled →
  /// searches fall back to linear XHTML strip on every run.
  static const List<int> capacityPresets = [
    0,
    32 * 1024 * 1024,
    128 * 1024 * 1024,
    512 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
  ];

  static final ValueNotifier<int> capacityBytes =
      ValueNotifier<int>(defaultCapacityBytes);

  /// Live tick every time indexed bytes/count change — the settings
  /// and memory-manager UI listen for redraws.
  static final ValueNotifier<int> statsRevision = ValueNotifier<int>(0);

  static Database? _db;
  static bool _initialized = false;
  static bool _available = false;

  /// True iff the underlying SQLite supports FTS5 and the index tables
  /// were created successfully. When false, callers should fall back
  /// to linear scan.
  static bool get isAvailable => _available;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(_kPrefKey);
      if (stored != null && stored >= 0) capacityBytes.value = stored;
    } catch (_) { /* best effort */ }
    try {
      _db = await _openDb();
      _available = true;
      // Enforce cap on startup — a lower cap set in a prior run may
      // have left the DB oversized (if we crashed mid-index).
      await _evictToCapacity();
      statsRevision.value++;
    } catch (_) {
      _db = null;
      _available = false;
    }
    capacityBytes.addListener(() async {
      await _evictToCapacity();
      statsRevision.value++;
    });
  }

  static Future<Database> _openDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$_fileName';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        // Companion table: per-book metadata + LRU accounting.
        await db.execute('''
          CREATE TABLE search_index_books (
            book_key TEXT PRIMARY KEY,
            book_title TEXT NOT NULL,
            chapter_count INTEGER NOT NULL,
            size_bytes INTEGER NOT NULL,
            last_touched_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_search_index_books_touch '
          'ON search_index_books(last_touched_at)',
        );
        // FTS5 virtual table. `text` is the only indexed column;
        // book_key/chapter_idx/chapter_title are UNINDEXED — retrieved
        // via SELECT but not tokenized.
        await db.execute('''
          CREATE VIRTUAL TABLE search_index_docs USING fts5(
            text,
            book_key UNINDEXED,
            chapter_idx UNINDEXED,
            chapter_title UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
          )
        ''');
      },
    );
  }

  /// True if [bookKey] has already been indexed.
  static Future<bool> hasBook(String bookKey) async {
    final db = _db;
    if (db == null) return false;
    final rows = await db.query(
      'search_index_books',
      columns: const ['book_key'],
      where: 'book_key = ?',
      whereArgs: [bookKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Insert chapter rows for a book. Rejects a single book larger than
  /// the current cap (returns false) so the eviction loop can't loop
  /// forever trying to make room.
  static Future<bool> indexBook({
    required String bookKey,
    required String bookTitle,
    required List<IndexChapter> chapters,
  }) async {
    final db = _db;
    if (db == null) return false;
    // Approximate byte footprint (UTF-16 code units × 2). Consistent
    // with the byte accounting the memory manager displays elsewhere.
    var bookBytes = bookTitle.length * 2;
    for (final c in chapters) {
      bookBytes += (c.title.length + c.text.length) * 2;
    }
    final capacity = capacityBytes.value;
    if (capacity <= 0) return false;
    if (bookBytes > capacity) return false; // won't fit alone

    // Evict oldest books until this one fits. Snapshot the running
    // total so we don't have to re-query on every eviction iteration.
    var used = await _computeUsedBytes();
    while (used + bookBytes > capacity) {
      final victim = await _pickLruBook(exclude: bookKey);
      if (victim == null) break; // nothing left to evict
      used -= victim.sizeBytes;
      await _deleteBook(victim.bookKey);
    }
    if (used + bookBytes > capacity) return false; // still doesn't fit

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((tx) async {
      // Replace any stale rows for this book (idempotent re-index).
      await tx.delete('search_index_books', where: 'book_key = ?', whereArgs: [bookKey]);
      await tx.delete('search_index_docs', where: 'book_key = ?', whereArgs: [bookKey]);
      await tx.insert('search_index_books', {
        'book_key': bookKey,
        'book_title': bookTitle,
        'chapter_count': chapters.length,
        'size_bytes': bookBytes,
        'last_touched_at': now,
      });
      for (var i = 0; i < chapters.length; i++) {
        final c = chapters[i];
        if (c.text.isEmpty) continue;
        await tx.insert('search_index_docs', {
          'text': c.text,
          'book_key': bookKey,
          'chapter_idx': i,
          'chapter_title': c.title,
        });
      }
    });
    statsRevision.value++;
    return true;
  }

  /// Query the index for one book. Returns matching chapters and the
  /// raw text for the caller to run its snippet extractor on. Bumps
  /// the book's `last_touched_at` on any hit so LRU eviction picks
  /// the truly-cold books.
  ///
  /// [fts5Query] is a raw FTS5 MATCH expression — build via
  /// [buildFts5MatchQuery] from a user query.
  static Future<List<IndexMatch>> queryBook({
    required String fts5Query,
    required String bookKey,
    int limit = 32,
  }) async {
    final db = _db;
    if (db == null || fts5Query.isEmpty) return const [];
    List<Map<String, Object?>> rows;
    try {
      rows = await db.rawQuery('''
        SELECT text, chapter_idx, chapter_title
        FROM search_index_docs
        WHERE search_index_docs MATCH ? AND book_key = ?
        ORDER BY rank
        LIMIT ?
      ''', [fts5Query, bookKey, limit]);
    } catch (_) {
      // Malformed FTS5 expression (rare — buildFts5MatchQuery
      // sanitises the common cases). Treat as no hits.
      return const [];
    }
    if (rows.isEmpty) return const [];
    // Touch the book so it moves to the end of the LRU order.
    await db.update(
      'search_index_books',
      {'last_touched_at': DateTime.now().millisecondsSinceEpoch},
      where: 'book_key = ?',
      whereArgs: [bookKey],
    );
    return [
      for (final r in rows)
        IndexMatch(
          bookKey: bookKey,
          text: (r['text'] as String?) ?? '',
          chapterIdx: (r['chapter_idx'] as int?) ?? 0,
          chapterTitle: (r['chapter_title'] as String?) ?? '',
        ),
    ];
  }

  /// Look up cached book title for a book_key. Returns null if the
  /// book hasn't been indexed.
  static Future<String?> bookTitleFor(String bookKey) async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query(
      'search_index_books',
      columns: const ['book_title'],
      where: 'book_key = ?',
      whereArgs: [bookKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['book_title'] as String?;
  }

  static Future<void> setCapacity(int bytes) async {
    final v = bytes < 0 ? 0 : bytes;
    capacityBytes.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefKey, v);
    } catch (_) { /* best effort */ }
  }

  /// Snapshot of the index size for the settings + memory-manager UI.
  /// The [statsRevision] notifier ticks whenever these numbers change.
  static Future<({int usedBytes, int bookCount, int capacityBytes, bool available})>
      stats() async {
    final db = _db;
    if (db == null) {
      return (
        usedBytes: 0,
        bookCount: 0,
        capacityBytes: capacityBytes.value,
        available: _available,
      );
    }
    final row = (await db.rawQuery(
      'SELECT COALESCE(SUM(size_bytes), 0) AS used, COUNT(*) AS n FROM search_index_books',
    )).first;
    return (
      usedBytes: (row['used'] as int?) ?? 0,
      bookCount: (row['n'] as int?) ?? 0,
      capacityBytes: capacityBytes.value,
      available: _available,
    );
  }

  static Future<void> clear() async {
    final db = _db;
    if (db == null) return;
    await db.transaction((tx) async {
      await tx.delete('search_index_docs');
      await tx.delete('search_index_books');
    });
    statsRevision.value++;
  }

  /// Delete the on-disk index file entirely. Used by tests and the
  /// "reset" path; the DB re-opens empty on next [init] cycle.
  static Future<void> destroy() async {
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _initialized = false;
    _available = false;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ── internals ───────────────────────────────────────────────

  static Future<int> _computeUsedBytes() async {
    final db = _db;
    if (db == null) return 0;
    final row = (await db.rawQuery(
      'SELECT COALESCE(SUM(size_bytes), 0) AS used FROM search_index_books',
    )).first;
    return (row['used'] as int?) ?? 0;
  }

  static Future<_LruVictim?> _pickLruBook({String? exclude}) async {
    final db = _db;
    if (db == null) return null;
    final where = exclude == null ? '' : 'WHERE book_key <> ?';
    final args = exclude == null ? <Object?>[] : <Object?>[exclude];
    final rows = await db.rawQuery(
      'SELECT book_key, size_bytes FROM search_index_books '
      '$where ORDER BY last_touched_at ASC LIMIT 1',
      args,
    );
    if (rows.isEmpty) return null;
    return _LruVictim(
      bookKey: rows.first['book_key'] as String,
      sizeBytes: (rows.first['size_bytes'] as int?) ?? 0,
    );
  }

  static Future<void> _deleteBook(String bookKey) async {
    final db = _db;
    if (db == null) return;
    await db.transaction((tx) async {
      await tx.delete('search_index_books', where: 'book_key = ?', whereArgs: [bookKey]);
      await tx.delete('search_index_docs', where: 'book_key = ?', whereArgs: [bookKey]);
    });
  }

  static Future<void> _evictToCapacity() async {
    final db = _db;
    if (db == null) return;
    final capacity = capacityBytes.value;
    var used = await _computeUsedBytes();
    while (used > capacity) {
      final victim = await _pickLruBook();
      if (victim == null) break;
      used -= victim.sizeBytes;
      await _deleteBook(victim.bookKey);
    }
  }
}

class _LruVictim {
  final String bookKey;
  final int sizeBytes;
  const _LruVictim({required this.bookKey, required this.sizeBytes});
}

/// One chapter's worth of extracted-and-normalised text, handed to
/// [SearchIndex.indexBook] at populate time.
class IndexChapter {
  final String title;
  final String text;
  const IndexChapter({required this.title, required this.text});
}

/// One row returned by [SearchIndex.queryBook]. The caller runs its
/// own snippet extractor over [text] so snippet rendering stays
/// identical whether we came from the index or a linear scan.
class IndexMatch {
  final String bookKey;
  final String text;
  final int chapterIdx;
  final String chapterTitle;
  const IndexMatch({
    required this.bookKey,
    required this.text,
    required this.chapterIdx,
    required this.chapterTitle,
  });
}

/// Build a valid FTS5 MATCH expression from the parsed user phrases.
/// Each phrase is wrapped in double quotes (any `"` escaped as `""`)
/// and given a trailing `*` for prefix match on the last token. `|`
/// between user phrases becomes ` OR ` in the MATCH expression.
///
/// Returns an empty string if [phrases] is empty (caller should
/// skip querying entirely — an empty MATCH is a syntax error).
String buildFts5MatchQuery(List<String> phrases) {
  final parts = <String>[];
  for (final p in phrases) {
    final t = p.trim();
    if (t.isEmpty) continue;
    final escaped = t.replaceAll('"', '""');
    parts.add('"$escaped"*');
  }
  return parts.join(' OR ');
}
