/// Browsing history for the main WebView.
///
/// Kept in its own SQLite file rather than the tagging database. The tagging
/// database is study material — profiles, sentences, tags — that the user
/// exports and moves between devices; a record of every page visited is
/// neither, and mixing the two would carry it along on every export.
///
/// One row per address, not one per visit: the same page read ten times is
/// still one thing to offer in the URL bar, and a visit count is a better
/// ranking signal than ten identical rows.
///
/// The whole table is also held in memory. It is small (capped at
/// [maxEntries] rows of short strings) and the URL bar needs suggestions
/// while the user types, where an await per keystroke shows up as lag.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// One visited address.
@immutable
class HistoryEntry {
  final String url;
  final String title;
  final int visitCount;

  /// Milliseconds since epoch.
  final int lastVisited;

  const HistoryEntry({
    required this.url,
    required this.title,
    required this.visitCount,
    required this.lastVisited,
  });

  /// What the URL bar shows under the address.
  String get label => title.trim().isEmpty ? url : title.trim();

  HistoryEntry copyWith({String? title, int? visitCount, int? lastVisited}) =>
      HistoryEntry(
        url: url,
        title: title ?? this.title,
        visitCount: visitCount ?? this.visitCount,
        lastVisited: lastVisited ?? this.lastVisited,
      );

  @override
  String toString() => 'HistoryEntry($url, visits=$visitCount)';
}

/// True when [url] is worth remembering.
///
/// Only http(s). Everything else the WebView reports is either an internal
/// page the user cannot navigate back to by typing (`about:blank`, the app's
/// own generated HTML) or a local file whose path means nothing in a URL bar.
bool isRecordableHistoryUrl(String url) {
  final u = url.trim();
  if (u.isEmpty) return false;
  final uri = Uri.tryParse(u);
  if (uri == null || !uri.hasAuthority) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  // A blank host passes hasAuthority on some malformed inputs.
  return uri.host.trim().isNotEmpty;
}

/// How well [entry] answers [query], lower being better, or null for no match.
///
/// The ranks encode what someone typing into a URL bar means. Typing `svt`
/// almost always means "the site called svt", so a host that *starts* with
/// the query beats a host that merely contains it, which beats a match buried
/// in the path, which beats a match only in the page's title.
int? historyMatchRank(HistoryEntry entry, String query) {
  final q = _bareAddress(query.trim().toLowerCase());
  if (q.isEmpty) return 0;
  final uri = Uri.tryParse(entry.url);
  var host = (uri?.host ?? '').toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);

  if (host.startsWith(q)) return 0;
  if (host.contains(q)) return 1;
  if (_bareAddress(entry.url.toLowerCase()).contains(q)) return 2;
  if (entry.title.toLowerCase().contains(q)) return 3;
  return null;
}

/// An address stripped of the parts nobody types to identify a page: the
/// scheme and a leading `www.`.
///
/// Both sides are stripped. Without it every entry in history matches the
/// first few characters of a typed-out URL — `h`, `ht`, `htt`, `http` — and
/// the suggestions are whatever ranks highest, unrelated to what was typed.
String _bareAddress(String s) {
  var out = s;
  final i = out.indexOf('://');
  if (i >= 0) out = out.substring(i + 3);
  if (out.startsWith('www.')) out = out.substring(4);
  return out;
}

/// Ranked suggestions for [query] out of [all].
///
/// Pure so the ordering can be pinned by tests without a database. An empty
/// query is the "just opened the bar" case and yields the most recent pages.
List<HistoryEntry> rankHistorySuggestions(
  Iterable<HistoryEntry> all,
  String query, {
  int limit = 8,
}) {
  final q = query.trim();
  // Nothing to score against. [all] already arrives newest-first, and that IS
  // the answer here — ranking by visit count would bury this morning's page
  // under a site visited all year.
  if (q.isEmpty) return all.take(limit).toList(growable: false);
  final scored = <(int, HistoryEntry)>[];
  for (final e in all) {
    final rank = historyMatchRank(e, q);
    if (rank == null) continue;
    scored.add((rank, e));
  }
  scored.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    // Within the same kind of match: somewhere you go often beats somewhere
    // you went once, and a tie breaks on which you saw more recently.
    final byVisits = b.$2.visitCount.compareTo(a.$2.visitCount);
    if (byVisits != 0) return byVisits;
    return b.$2.lastVisited.compareTo(a.$2.lastVisited);
  });
  return [for (final s in scored.take(limit)) s.$2];
}

class HistoryStore {
  HistoryStore._();

  static const String _fileName = 'history.db';

  /// Rows kept. Trimming happens in batches (see [_trimSlack]) so a busy
  /// session doesn't run a delete after every single page load.
  static const int maxEntries = 5000;
  static const int _trimSlack = 200;

  static Database? _db;

  /// Every entry, newest first. Read directly by the URL bar.
  static final ValueNotifier<List<HistoryEntry>> entries =
      ValueNotifier<List<HistoryEntry>>(const []);

  static bool _initialized = false;

  /// Opens the file and loads the table into memory. Idempotent; a failure
  /// leaves history disabled rather than taking the app down with it.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _db = await _openDb();
      await _reload();
    } catch (_) {
      _db = null;
    }
  }

  static Future<Database> _openDb() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      '${dir.path}/$_fileName',
      version: 1,
      onCreate: (db, v) => createSchema(db),
    );
  }

  /// The table, as one statement set shared by the real file and any test
  /// database, so a test can never drift from what ships.
  @visibleForTesting
  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE history (
        url TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        visit_count INTEGER NOT NULL DEFAULT 1,
        last_visited INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_history_last_visited ON history(last_visited)',
    );
  }

  /// Test seam: run against [db] instead of a file in the app's documents
  /// directory, which only exists on a device. Resets everything, so each
  /// test starts from nothing.
  @visibleForTesting
  static Future<void> initWithDatabase(Database db) async {
    _initialized = true;
    _db = db;
    _writes = Future<void>.value();
    entries.value = const [];
    await _reload();
  }

  static Future<void> _reload() async {
    final db = _db;
    if (db == null) return;
    final rows = await db.query('history', orderBy: 'last_visited DESC');
    entries.value = [
      for (final r in rows)
        HistoryEntry(
          url: r['url'] as String,
          title: (r['title'] as String?) ?? '',
          visitCount: (r['visit_count'] as int?) ?? 1,
          lastVisited: (r['last_visited'] as int?) ?? 0,
        ),
    ];
  }

  /// Serialises writes.
  ///
  /// Two visits can be in flight at once — a single-page site fires both a
  /// page-load and an in-page navigation, and each waits on the page title
  /// first. Interleaved, the second would resume holding a view of the list
  /// from before the first reordered it. One at a time removes the whole
  /// class of problem, and a write is microseconds against a page load.
  static Future<void> _writes = Future<void>.value();

  /// Records a visit to [url].
  ///
  /// A page is normally loaded before its title is known, so a later call with
  /// the same address and a real title fills it in. An empty [title] never
  /// overwrites one we already have.
  static Future<void> record(String url, {String title = ''}) {
    final next = _writes.then((_) => _record(url, title: title));
    // A failed write must not poison the queue for every visit after it.
    _writes = next.catchError((_) {});
    return next;
  }

  static Future<void> _record(String url, {String title = ''}) async {
    final db = _db;
    if (db == null) return;
    if (!isRecordableHistoryUrl(url)) return;
    final u = url.trim();
    final t = title.trim();
    final now = DateTime.now().millisecondsSinceEpoch;

    final prev = _entryFor(u);
    try {
      if (prev != null) {
        // Same page reported again within a moment (a redirect settling, the
        // title arriving after the load) is one visit, not two.
        final sameVisit = now - prev.lastVisited < 2000;
        final visits = sameVisit ? prev.visitCount : prev.visitCount + 1;
        final newTitle = t.isNotEmpty ? t : prev.title;
        await db.update(
          'history',
          {'title': newTitle, 'visit_count': visits, 'last_visited': now},
          where: 'url = ?',
          whereArgs: [u],
        );
        _promote(prev.copyWith(
          title: newTitle,
          visitCount: visits,
          lastVisited: now,
        ));
      } else {
        await db.insert(
          'history',
          {'url': u, 'title': t, 'visit_count': 1, 'last_visited': now},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _promote(
          HistoryEntry(url: u, title: t, visitCount: 1, lastVisited: now),
        );
        if (entries.value.length > maxEntries + _trimSlack) await _trim();
      }
    } catch (_) {
      // A write that fails costs one suggestion, not the page load.
    }
  }

  /// Puts [entry] at the head of the list, removing any older copy.
  ///
  /// Keyed on the address rather than on an index captured earlier: an index
  /// read before an await describes a list that may no longer exist, and
  /// acting on it removes the wrong page.
  static void _promote(HistoryEntry entry) {
    final next = <HistoryEntry>[entry];
    for (final e in entries.value) {
      if (e.url != entry.url) next.add(e);
    }
    entries.value = next;
  }

  static HistoryEntry? _entryFor(String url) {
    for (final e in entries.value) {
      if (e.url == url) return e;
    }
    return null;
  }

  static Future<void> _trim() async {
    final db = _db;
    if (db == null) return;
    await db.execute(
      'DELETE FROM history WHERE url NOT IN ('
      'SELECT url FROM history ORDER BY last_visited DESC LIMIT ?)',
      [maxEntries],
    );
    await _reload();
  }

  /// Suggestions for what the user has typed so far.
  static List<HistoryEntry> suggest(String query, {int limit = 8}) =>
      rankHistorySuggestions(entries.value, query, limit: limit);

  static Future<void> remove(String url) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.delete('history', where: 'url = ?', whereArgs: [url]);
      entries.value =
          entries.value.where((e) => e.url != url).toList(growable: false);
    } catch (_) {}
  }

  static Future<void> clear() async {
    final db = _db;
    if (db == null) return;
    try {
      await db.delete('history');
      entries.value = const [];
    } catch (_) {}
  }

  /// Test seam — lets a widget test populate the list without a database.
  @visibleForTesting
  static void debugSetEntries(List<HistoryEntry> list) {
    entries.value = List<HistoryEntry>.unmodifiable(list);
  }
}
