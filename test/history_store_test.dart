import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/history_store.dart';

/// The URL bar shows at most a handful of rows, so the ordering IS the
/// feature — a correct match ranked eighth is a miss.
void main() {
  HistoryEntry e(
    String url, {
    String title = '',
    int visits = 1,
    int at = 0,
  }) =>
      HistoryEntry(url: url, title: title, visitCount: visits, lastVisited: at);

  group('what gets remembered', () {
    test('ordinary web pages do', () {
      expect(isRecordableHistoryUrl('https://svtplay.se/video/1'), isTrue);
      expect(isRecordableHistoryUrl('http://example.test/'), isTrue);
    });

    test('internal and local pages do not', () {
      expect(isRecordableHistoryUrl('about:blank'), isFalse);
      expect(isRecordableHistoryUrl('data:text/html,<p>hi</p>'), isFalse);
      // The app renders extracted PDF text from a file:// document; that
      // address means nothing typed back into the bar.
      expect(isRecordableHistoryUrl('file:///storage/book.html'), isFalse);
      expect(isRecordableHistoryUrl(''), isFalse);
      expect(isRecordableHistoryUrl('   '), isFalse);
      expect(isRecordableHistoryUrl('not a url'), isFalse);
    });

    test('an http URL with no host does not', () {
      expect(isRecordableHistoryUrl('http://'), isFalse);
    });
  });

  group('Spotify search history', () {
    const results = 'https://open.spotify.com/search/results/';

    testWidgets('typing a search records only the settled route', (
      tester,
    ) async {
      final visits = <(String, String)>[];
      final recorder = LiveSearchHistoryRecorder((url, {title = ''}) async {
        visits.add((url, title));
      });

      expect(recorder.onNavigation('${results}B'), isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      expect(recorder.onNavigation('${results}Befria'), isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      expect(recorder.onNavigation('${results}Befria%20oss'), isTrue);
      await tester.pump(const Duration(milliseconds: 1999));
      expect(visits, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(visits, [
        ('${results}Befria%20oss', 'Search for Befria oss | Spotify'),
      ]);
    });

    testWidgets('keeps separate searches and saves the last one on exit', (
      tester,
    ) async {
      final visits = <String>[];
      final recorder = LiveSearchHistoryRecorder((url, {title = ''}) async {
        visits.add(url);
      });

      recorder.onNavigation('${results}Befria');
      recorder.onNavigation('https://open.spotify.com/search/Jazz');
      expect(visits, ['${results}Befria']);
      expect(
        recorder.onNavigation('https://open.spotify.com/episode/123'),
        isFalse,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(visits, [
        '${results}Befria',
        'https://open.spotify.com/search/Jazz',
      ]);
    });

    test('hides old typing bursts while keeping independent visits', () {
      final all = [
        e('${results}Befria%20oss', visits: 2, at: 9000),
        e('${results}Befria', at: 8500),
        e('${results}Bef', at: 8000),
        e('${results}Be', visits: 2, at: 7500),
        e('${results}B', at: 7000),
        e('${results}Jazz', at: 6000),
        e('${results}Jaz', at: 2500),
        e('${results}Ja', at: 2000),
      ];
      expect(collapseHistorySearchDrafts(all), [
        all[0],
        all[3],
        all[4],
        all[5],
        all[6],
        all[7],
      ]);
      expect(all, hasLength(8));
    });
  });

  group('matching', () {
    test('a host that starts with the query beats one that contains it', () {
      final starts = e('https://svtplay.se/');
      final contains = e('https://news.svt.se/');
      expect(historyMatchRank(starts, 'svt'), lessThan(historyMatchRank(contains, 'svt')!));
    });

    test('www. is ignored when deciding what the host starts with', () {
      expect(historyMatchRank(e('https://www.svtplay.se/'), 'svt'), 0);
    });

    test('a match in the path ranks below any host match', () {
      final path = e('https://example.test/svt/clip');
      expect(historyMatchRank(path, 'svt'), 2);
    });

    test('a match only in the title ranks last but still counts', () {
      final titled = e('https://example.test/a', title: 'SVT Play — Live');
      expect(historyMatchRank(titled, 'svt'), 3);
    });

    test('case and surrounding spaces do not matter', () {
      expect(historyMatchRank(e('https://svtplay.se/'), '  SVT  '), 0);
    });

    // Typing a URL out in full starts with characters every stored address
    // shares. If the scheme counted, the first five keystrokes would each
    // match the whole of history and the suggestions would be noise.
    test('the scheme is not part of what a query matches against', () {
      final entry = e('https://svtplay.se/');
      expect(historyMatchRank(entry, 'h'), isNull);
      expect(historyMatchRank(entry, 'http'), isNull);
      expect(historyMatchRank(entry, 'https'), isNull);
    });

    test('a query that includes the scheme still matches the host', () {
      expect(historyMatchRank(e('https://svtplay.se/'), 'https://svt'), 0);
      expect(historyMatchRank(e('https://www.svtplay.se/'), 'https://www.svt'), 0);
    });

    test('a whole address pasted in still finds its own entry', () {
      // Rank 2 rather than 0: the query is longer than the host, so it can
      // only be found in the address as a whole.
      expect(
        historyMatchRank(e('https://svtplay.se/a'), 'https://svtplay.se/a'),
        2,
      );
    });

    test('typing www matches nothing by itself', () {
      expect(historyMatchRank(e('https://www.svtplay.se/'), 'www'), isNull);
    });

    test('no match anywhere returns null', () {
      expect(historyMatchRank(e('https://example.test/', title: 'Example'), 'svt'), isNull);
    });
  });

  group('ranking the list', () {
    test('an empty query offers the most recent pages', () {
      // Newest-first, as the store hands them over, with visit counts running
      // the other way on purpose: ranking by those instead of keeping the
      // order would put the old favourite first. That is the bug this pins.
      final list = [
        e('https://just-now.test/', visits: 1, at: 300),
        e('https://old-favourite.test/', visits: 40, at: 200),
        e('https://yesterday.test/', visits: 5, at: 100),
      ];
      final out = rankHistorySuggestions(list, '');
      expect(out.map((x) => x.url), [
        'https://just-now.test/',
        'https://old-favourite.test/',
        'https://yesterday.test/',
      ]);
    });

    test('a query of only whitespace counts as empty', () {
      final list = [
        e('https://newest.test/', visits: 1, at: 2),
        e('https://popular.test/', visits: 9, at: 1),
      ];
      expect(rankHistorySuggestions(list, '   ').first.url,
          'https://newest.test/');
    });

    test('kind of match wins over how often you went there', () {
      final list = [
        e('https://news.example/svt-report', visits: 99, at: 999),
        e('https://svtplay.se/', visits: 1, at: 1),
      ];
      expect(rankHistorySuggestions(list, 'svt').first.url, 'https://svtplay.se/');
    });

    test('within the same kind of match, the place you go often wins', () {
      final list = [
        e('https://svtplay.se/rare', visits: 1, at: 999),
        e('https://svtplay.se/daily', visits: 40, at: 1),
      ];
      expect(rankHistorySuggestions(list, 'svtplay').first.url,
          'https://svtplay.se/daily');
    });

    test('equally visited pages fall back to whichever was seen last', () {
      final list = [
        e('https://svtplay.se/old', visits: 3, at: 10),
        e('https://svtplay.se/new', visits: 3, at: 20),
      ];
      expect(rankHistorySuggestions(list, 'svtplay').first.url,
          'https://svtplay.se/new');
    });

    test('non-matching entries are left out entirely', () {
      final list = [
        e('https://svtplay.se/'),
        e('https://example.test/'),
      ];
      final out = rankHistorySuggestions(list, 'svt');
      expect(out, hasLength(1));
      expect(out.single.url, 'https://svtplay.se/');
    });

    test('the list is capped at the limit', () {
      final list = [for (var i = 0; i < 50; i++) e('https://svt$i.test/', at: i)];
      expect(rankHistorySuggestions(list, 'svt', limit: 5), hasLength(5));
      expect(rankHistorySuggestions(list, '', limit: 3), hasLength(3));
    });

    test('an empty store suggests nothing rather than throwing', () {
      expect(rankHistorySuggestions(const [], 'svt'), isEmpty);
      expect(rankHistorySuggestions(const [], ''), isEmpty);
    });
  });

  group('what the row says', () {
    test('the title when there is one', () {
      expect(e('https://a.test/', title: 'Hello').label, 'Hello');
    });

    test('the address when the page never reported a title', () {
      expect(e('https://a.test/').label, 'https://a.test/');
      expect(e('https://a.test/', title: '   ').label, 'https://a.test/');
    });
  });
}
