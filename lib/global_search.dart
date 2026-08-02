import 'dart:async';
import 'dart:io';

import 'epub_reader.dart' show EpubBook, EpubLibrary, EpubLibraryEntry;
import 'search_index.dart';

/// Query grammar (deliberately small):
///   `phrase`             → word / prefix match on the last token
///   `phrase1|phrase2`    → OR — chapter matches if it contains any
///   `foo bar|baz qux`    → spaces are literal; only `|` splits phrases
///
/// Case + diacritics are folded by the FTS5 tokenizer when the index
/// is enabled. When disabled (fallback linear scan) the matcher is
/// case-insensitive substring — subtly different but a strict superset
/// of what the index reports, so hits from the fallback are still
/// correct.
///
/// **Single-word phrases shorter than [minTokenChars] are dropped.**
/// A 1- or 2-char search word ("a", "of") would either time out the
/// scan or return an unusable flood of hits; dropping them keeps
/// searches fast and results meaningful. Multi-word phrases pass
/// through unchanged — `"of" is fine as part of `is of course`.
class GlobalSearchQuery {
  /// Minimum length for a single-word search phrase to be kept.
  /// Multi-word phrases are exempt (they carry meaning through the
  /// combination even when individual words are short).
  static const int minTokenChars = 3;

  final String raw;
  final List<String> phrases;

  const GlobalSearchQuery._(this.raw, this.phrases);

  factory GlobalSearchQuery.parse(String input) {
    final trimmed = input.trim();
    final parts = trimmed
        .split('|')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .map((p) => p.toLowerCase())
        .where((p) => p.contains(' ') || p.length >= minTokenChars)
        .toList();
    return GlobalSearchQuery._(input, parts);
  }

  bool get isEmpty => phrases.isEmpty;

  /// True if [text] contains at least one phrase as a substring.
  /// Used only by the linear-scan fallback.
  bool matchesLower(String textLower) {
    for (final p in phrases) {
      if (textLower.contains(p)) return true;
    }
    return false;
  }
}

/// One match location inside a chapter.
class GlobalSearchSnippet {
  final String phrase;
  final int offset;
  final String before;
  final String match;
  final String after;

  const GlobalSearchSnippet({
    required this.phrase,
    required this.offset,
    required this.before,
    required this.match,
    required this.after,
  });

  Map<String, Object?> toJson() => {
        'phrase': phrase,
        'offset': offset,
        'before': before,
        'match': match,
        'after': after,
      };
}

/// A book+chapter hit with up to N snippets.
class GlobalSearchHit {
  final String bookKey;
  final String bookTitle;
  final int chapterIdx;
  final String chapterTitle;
  final List<GlobalSearchSnippet> snippets;

  const GlobalSearchHit({
    required this.bookKey,
    required this.bookTitle,
    required this.chapterIdx,
    required this.chapterTitle,
    required this.snippets,
  });

  Map<String, Object?> toJson() => {
        'book_key': bookKey,
        'book_title': bookTitle,
        'chapter_idx': chapterIdx,
        'chapter_title': chapterTitle,
        'snippets': [for (final s in snippets) s.toJson()],
      };
}

/// Progress signal for the UI.
class GlobalSearchProgress {
  final int booksScanned;
  final int booksTotal;
  final int hitsSoFar;
  const GlobalSearchProgress({
    required this.booksScanned,
    required this.booksTotal,
    required this.hitsSoFar,
  });
}

/// Streaming full-text search across the library.
///
/// **When the index is enabled AND available** ([SearchIndex.isAvailable]
/// + `capacityBytes > 0`): unindexed books get parsed + inserted into
/// the FTI on first pass, then queried via SQLite FTS5. Repeat searches
/// skip the parse.
///
/// **When disabled or unavailable**: linear scan — each book is parsed
/// on demand, HTML stripped, and grep'd. Same semantics as before the
/// index landed.
///
/// Cancellation: caller cancels the returned [StreamSubscription]; the
/// loop cooperates on each chapter / book boundary.
class GlobalSearch {
  GlobalSearch._();

  static const int _maxSnippetsPerChapter = 3;
  static const int _snippetContext = 48;

  static Stream<GlobalSearchEvent> search(
    String rawQuery, {
    int maxTotalHits = 200,
  }) async* {
    final q = GlobalSearchQuery.parse(rawQuery);
    if (q.isEmpty) return;

    final library = await EpubLibrary.load();
    final entries = library.entries;
    if (entries.isEmpty) {
      yield GlobalSearchDone(query: q, hitsEmitted: 0, booksScanned: 0);
      return;
    }

    var hitsEmitted = 0;
    var booksScanned = 0;

    yield GlobalSearchProgressEvent(GlobalSearchProgress(
      booksScanned: 0,
      booksTotal: entries.length,
      hitsSoFar: 0,
    ));

    final indexOn = SearchIndex.isAvailable && SearchIndex.capacityBytes.value > 0;
    final ftsQuery = indexOn ? buildFts5MatchQuery(q.phrases) : '';

    for (final entry in entries) {
      if (hitsEmitted >= maxTotalHits) break;

      List<GlobalSearchHit> bookHits = const [];
      var handled = false;

      if (indexOn && ftsQuery.isNotEmpty) {
        handled = await _searchViaIndex(
          entry: entry,
          query: q,
          ftsQuery: ftsQuery,
          maxTotal: maxTotalHits,
          alreadyEmitted: hitsEmitted,
          into: (hit) {
            bookHits = [...bookHits, hit];
          },
        );
      }

      if (!handled) {
        // Fallback: linear parse + strip + substring match. Used when
        // the index is disabled, unavailable, or when indexing this
        // book failed (e.g. the file moved on disk).
        final book = await _tryOpen(entry);
        if (book != null) {
          for (var i = 0; i < book.chapters.length; i++) {
            if (hitsEmitted + bookHits.length >= maxTotalHits) break;
            final ch = book.chapters[i];
            final text = _extractText(ch.html);
            if (text.isEmpty) continue;
            final lower = text.toLowerCase();
            if (!q.matchesLower(lower)) continue;
            final snippets = _collectSnippets(text, lower, q.phrases);
            if (snippets.isEmpty) continue;
            bookHits = [
              ...bookHits,
              GlobalSearchHit(
                bookKey: book.key,
                bookTitle: book.title,
                chapterIdx: i,
                chapterTitle: ch.title,
                snippets: snippets,
              ),
            ];
          }
        }
      }

      for (final hit in bookHits) {
        if (hitsEmitted >= maxTotalHits) break;
        yield GlobalSearchHitEvent(hit);
        hitsEmitted++;
        await Future<void>.delayed(Duration.zero);
      }

      booksScanned++;
      yield GlobalSearchProgressEvent(GlobalSearchProgress(
        booksScanned: booksScanned,
        booksTotal: entries.length,
        hitsSoFar: hitsEmitted,
      ));
    }

    yield GlobalSearchDone(
      query: q,
      hitsEmitted: hitsEmitted,
      booksScanned: booksScanned,
    );
  }

  /// Ensure [entry] is in the index, then query. Returns true iff the
  /// index path handled the book (regardless of hit count). Returns
  /// false if we couldn't index it, so the caller falls back to a
  /// linear scan.
  static Future<bool> _searchViaIndex({
    required EpubLibraryEntry entry,
    required GlobalSearchQuery query,
    required String ftsQuery,
    required int maxTotal,
    required int alreadyEmitted,
    required void Function(GlobalSearchHit) into,
  }) async {
    final bookKey = entry.key;
    var bookTitle = await SearchIndex.bookTitleFor(bookKey);
    if (bookTitle == null) {
      // Not yet indexed — extract chapters from disk and insert.
      final book = await _tryOpen(entry);
      if (book == null) return false;
      final chapters = <IndexChapter>[
        for (final ch in book.chapters)
          IndexChapter(title: ch.title, text: _extractText(ch.html)),
      ];
      final ok = await SearchIndex.indexBook(
        bookKey: bookKey,
        bookTitle: book.title,
        chapters: chapters,
      );
      if (!ok) return false; // book too big for the cap → linear fallback
      bookTitle = book.title;
    }

    final remaining = maxTotal - alreadyEmitted;
    if (remaining <= 0) return true;
    final matches = await SearchIndex.queryBook(
      fts5Query: ftsQuery,
      bookKey: bookKey,
      limit: remaining,
    );
    for (final m in matches) {
      final lower = m.text.toLowerCase();
      final snippets = _collectSnippets(m.text, lower, query.phrases);
      if (snippets.isEmpty) {
        // FTS5 matched at the tokenizer level (e.g. adjacent tokens
        // with punctuation between them) but our substring extractor
        // didn't find the phrase. Fall back to a leading excerpt so
        // the row still renders something meaningful.
        final head = m.text.length > _snippetContext * 2
            ? m.text.substring(0, _snippetContext * 2)
            : m.text;
        into(GlobalSearchHit(
          bookKey: m.bookKey,
          bookTitle: bookTitle,
          chapterIdx: m.chapterIdx,
          chapterTitle: m.chapterTitle,
          snippets: [
            GlobalSearchSnippet(
              phrase: query.phrases.first,
              offset: 0,
              before: '',
              match: '',
              after: head,
            ),
          ],
        ));
        continue;
      }
      into(GlobalSearchHit(
        bookKey: m.bookKey,
        bookTitle: bookTitle,
        chapterIdx: m.chapterIdx,
        chapterTitle: m.chapterTitle,
        snippets: snippets,
      ));
    }
    return true;
  }

  static List<GlobalSearchSnippet> _collectSnippets(
    String text,
    String textLower,
    List<String> phrases,
  ) {
    final positions = <_Match>[];
    for (final p in phrases) {
      var from = 0;
      while (positions.length < _maxSnippetsPerChapter * phrases.length) {
        final at = textLower.indexOf(p, from);
        if (at < 0) break;
        positions.add(_Match(offset: at, phrase: p, length: p.length));
        from = at + p.length;
      }
    }
    positions.sort((a, b) => a.offset.compareTo(b.offset));
    final out = <GlobalSearchSnippet>[];
    var minNext = 0;
    for (final m in positions) {
      if (out.length >= _maxSnippetsPerChapter) break;
      if (m.offset < minNext) continue;
      final start = (m.offset - _snippetContext).clamp(0, text.length);
      final end = (m.offset + m.length + _snippetContext).clamp(0, text.length);
      out.add(GlobalSearchSnippet(
        phrase: m.phrase,
        offset: m.offset,
        before: text.substring(start, m.offset),
        match: text.substring(m.offset, m.offset + m.length),
        after: text.substring(m.offset + m.length, end),
      ));
      minNext = m.offset + m.length + _snippetContext;
    }
    return out;
  }

  static Future<EpubBook?> _tryOpen(EpubLibraryEntry entry) async {
    try {
      final f = File(entry.path);
      if (!await f.exists()) return null;
      return await EpubBook.openFile(f);
    } catch (_) {
      return null;
    }
  }

  /// Strip XHTML tags, decode a small set of common entities, collapse
  /// whitespace. Not a full HTML parser — search doesn't need one, and
  /// dragging in a proper parser would double this file's weight.
  static String _extractText(String html) {
    var s = html;
    s = s.replaceAll(_reScript, ' ');
    s = s.replaceAll(_reStyle, ' ');
    s = s.replaceAll(_reTag, ' ');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    s = s.replaceAll(_reWs, ' ');
    return s.trim();
  }

  static final RegExp _reScript = RegExp(r'<script[\s\S]*?</script>', caseSensitive: false);
  static final RegExp _reStyle = RegExp(r'<style[\s\S]*?</style>', caseSensitive: false);
  static final RegExp _reTag = RegExp(r'<[^>]+>');
  static final RegExp _reWs = RegExp(r'\s+');
}

class _Match {
  final int offset;
  final String phrase;
  final int length;
  const _Match({required this.offset, required this.phrase, required this.length});
}

abstract class GlobalSearchEvent {
  const GlobalSearchEvent();
}

class GlobalSearchHitEvent extends GlobalSearchEvent {
  final GlobalSearchHit hit;
  const GlobalSearchHitEvent(this.hit);
}

class GlobalSearchProgressEvent extends GlobalSearchEvent {
  final GlobalSearchProgress progress;
  const GlobalSearchProgressEvent(this.progress);
}

class GlobalSearchDone extends GlobalSearchEvent {
  final GlobalSearchQuery query;
  final int hitsEmitted;
  final int booksScanned;
  const GlobalSearchDone({
    required this.query,
    required this.hitsEmitted,
    required this.booksScanned,
  });
}

/// Collect the whole search into a list — used by the JS bridge
/// (fire-and-dispatch), since we can't stream through a CustomEvent
/// without a lot of extra plumbing.
Future<List<GlobalSearchHit>> collectAllHits(
  String query, {
  int maxTotalHits = 200,
}) async {
  final out = <GlobalSearchHit>[];
  await for (final ev in GlobalSearch.search(query, maxTotalHits: maxTotalHits)) {
    if (ev is GlobalSearchHitEvent) out.add(ev.hit);
    if (ev is GlobalSearchDone) break;
  }
  return out;
}
