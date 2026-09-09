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
    'url': _str(raw['url']).trim(),
    // The page knows the caption track's language; the app's own setting is
    // the fallback when it doesn't.
    'lang': pageLang.isNotEmpty ? pageLang : fallbackLang,
    'lines': ordered,
  };
}

String _str(Object? v) => v == null ? '' : v.toString();

double _num(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(_str(v)) ?? 0.0;
}
