/// Turns a block posted by the page into the `cupitorCaptionCapture` detail
/// the language webapp listens for.
///
/// Two sources share this path. `caption` carries timed lines harvested from a
/// video's subtitle track; `page` carries sentences the user selected on a web
/// page, which have no media time. One shaping function means one validated
/// host path and one webapp listener.
///
/// See `docs/superpowers/specs/2026-09-06-caption-capture-design.md`. Kept free
/// of Flutter so the shaping rules can be tested directly.
///
/// The page is not trusted to send well-formed input: it is scraped from a
/// third-party player whose markup changes without notice, so every field is
/// coerced and anything unusable is dropped rather than thrown.
library;

/// Builds the event detail, or returns null when there is nothing worth
/// sending. A null result means "say nothing" — never an error dialog.
Map<String, dynamic>? buildCaptionCaptureDetail(
  Object? raw, {
  required String fallbackLang,
}) {
  if (raw is! Map) return null;

  final lines = <Map<String, dynamic>>[];
  final rawLines = raw['lines'];
  if (rawLines is! List) return null;

  for (final entry in rawLines) {
    if (entry is! Map) continue;
    final text = _str(entry['text']).trim();
    // A cue with no words carries nothing; the DOM observer can briefly see
    // an empty container between cues.
    if (text.isEmpty) continue;
    final start = _num(entry['start']);
    final end = _num(entry['end']);
    lines.add(<String, dynamic>{
      'start': start,
      // An end before its start is meaningless; fall back to the start so the
      // webapp never has to defend against a negative duration.
      'end': end >= start ? end : start,
      'text': text,
      if (_str(entry['translation']).trim().isNotEmpty)
        'translation': _str(entry['translation']).trim(),
    });
  }
  if (lines.isEmpty) return null;

  // Order by media time so the webapp can rely on array order regardless of
  // how the page collected them. Ties break on arrival index because Dart's
  // sort is NOT stable: page captures have no timestamps, so every start is
  // 0, and without the tiebreak a selection could come back reordered.
  final indexed = <(int, Map<String, dynamic>)>[
    for (var i = 0; i < lines.length; i++) (i, lines[i]),
  ];
  indexed.sort((a, b) {
    final byStart = (a.$2['start'] as double).compareTo(b.$2['start'] as double);
    return byStart != 0 ? byStart : a.$1.compareTo(b.$1);
  });
  final ordered = [for (final e in indexed) e.$2];

  final pageLang = _str(raw['lang']).trim();
  // Anything unrecognised is treated as a caption: that was the only source
  // before, so an older page script that sends no source keeps working.
  final rawSource = _str(raw['source']).trim();
  final source = rawSource == 'page' ? 'page' : 'caption';
  return <String, dynamic>{
    // Tells the webapp what this block is, so it can decide how to turn it
    // into manual playlist item(s) — never a book-derived item.
    'source': source,
    'title': _str(raw['title']).trim(),
    // The page itself. This is the block's identity — the webapp matches it to
    // recognise lines it has already filed — so it stays the same for every
    // send from one video.
    'url': _str(raw['url']).trim(),
    // What this player calls a start offset, so the webapp can address one
    // moment of it. Only the page can name it, and only the webapp knows
    // which lines reach the card and therefore which moment to point at.
    // Empty for a player that cannot be deep-linked.
    //
    // It is sent even where no link is wanted, because the name is also what
    // lets the webapp take an offset off an address stored with an older
    // card and recognise it as the same page.
    'timeParam': _str(raw['timeParam']).trim(),
    // Whether that link is worth making on this page — false for a live
    // channel, whose timeline is anchored to nothing an hour later. Only an
    // explicit no counts, so a page that says nothing keeps its link.
    'timeLink': raw['timeLink'] != false,
    // The page knows the caption track's language; the app's own setting is
    // the fallback when it doesn't.
    'lang': pageLang.isNotEmpty ? pageLang : fallbackLang,
    'lines': ordered,
  };
}

/// Shapes ONE hand-picked sentence into the raw block
/// [buildCaptionCaptureDetail] accepts, so a sentence sent from the tagging
/// sheet travels the same validated path as a basket of page selections.
///
/// [url] may be empty. A sentence out of an EPUB has no address worth
/// linking to, and the webapp treats an empty url as "no media link, no
/// de-duplication" rather than as an error.
/// [timeParam] is what the page's player calls a start offset, when the page
/// could be asked. It carries no link here — one sentence has no media time —
/// but it is what lets the webapp recognise the address as the same page as
/// one filed by the subtitle sidebar, whatever the player had written into the
/// address bar at the time.
Map<String, dynamic> sentenceCaptureBlock({
  required String text,
  required String title,
  required String url,
  String timeParam = '',
}) {
  return <String, dynamic>{
    'source': 'page',
    'title': title.trim(),
    'url': url.trim(),
    'timeParam': timeParam.trim(),
    // A hand-picked sentence has no media time, which is what every 'page'
    // block looks like.
    'lines': <Map<String, dynamic>>[
      {'start': 0, 'end': 0, 'text': text},
    ],
  };
}

String _str(Object? v) => v == null ? '' : v.toString();

double _num(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(_str(v)) ?? 0.0;
}
