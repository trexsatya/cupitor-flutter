/// Reads the dictionary data Google's `translate_a/single` already returns
/// alongside a translation, so a word lookup can show every sense instead of
/// silently picking one.
///
/// One word rarely has one translation. Swedish `ta` is take, get, catch and
/// grab; `sjö` is both lake and sea. Asking for `dt=bd` (dictionary) and
/// `dt=at` (alternates) costs nothing — same endpoint, same request — and the
/// app was already discarding the answer.
///
/// Google returns the dictionary block only for single words and short
/// phrases, so "is this a sentence?" is answered by the response rather than
/// by a heuristic here. Nothing depends on that: a missing block simply means
/// no senses.
///
/// The response is an undocumented, positional JSON array that can change
/// shape without notice, so nothing here trusts its input. Every field is
/// coerced, anything unusable is dropped, and the primary translation is
/// salvaged whatever else goes wrong — a dictionary extra must never break
/// plain translation. Kept free of Flutter so the shaping rules can be tested
/// directly.
library;

/// One translation of the looked-up word.
class TranslateTerm {
  const TranslateTerm({required this.term, required this.reverse, this.score});

  /// The translation itself, e.g. `lake`.
  final String term;

  /// Source-language words that translate back to [term], e.g. `sjö`, `insjö`.
  /// These are what disambiguate two senses that look alike in the target
  /// language. Empty when Google offers none.
  final List<String> reverse;

  /// Google's relative frequency for this sense, roughly 0..1. Null when the
  /// response carried something that wasn't a number.
  final double? score;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'term': term,
        'reverse': reverse,
        if (score != null) 'score': score,
      };
}

/// The terms sharing one part of speech.
class TranslateSense {
  const TranslateSense({required this.pos, required this.terms});

  /// `noun`, `verb`, `adjective`, … as Google labels it. May be empty if the
  /// response omitted it; the terms are still worth showing.
  final String pos;

  final List<TranslateTerm> terms;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pos': pos,
        'terms': terms.map((t) => t.toJson()).toList(),
      };
}

/// A parsed translation: the primary string plus whatever dictionary data came
/// with it.
class TranslateDetail {
  const TranslateDetail({
    required this.primary,
    required this.senses,
    required this.alternates,
  });

  const TranslateDetail.empty()
      : primary = '',
        senses = const <TranslateSense>[],
        alternates = const <String>[];

  /// What the existing bridge has always returned.
  final String primary;

  /// Empty for sentences, for languages without a dictionary, and whenever the
  /// response didn't carry one.
  final List<TranslateSense> senses;

  /// Other whole-input translations Google considered. Distinct from [senses]:
  /// these aren't grouped or explained, they're just other candidates.
  final List<String> alternates;

  /// The `detail` payload handed to `window.__cupTranslated`.
  ///
  /// [provider] tells the page whether senses are absent because the word has
  /// one, or because we answered offline and never had any. Without it the two
  /// are indistinguishable and the UI would have to guess.
  Map<String, dynamic> toJson({required String provider}) => <String, dynamic>{
        'provider': provider,
        'senses': senses.map((s) => s.toJson()).toList(),
        'alternates': alternates,
      };
}

/// Parses a decoded `translate_a/single` response.
///
/// [raw] is whatever `jsonDecode` produced — including null or the wrong type,
/// both of which yield an empty result rather than an exception.
TranslateDetail parseTranslateResponse(Object? raw) {
  if (raw is! List) return const TranslateDetail.empty();
  return TranslateDetail(
    primary: _primary(raw),
    senses: _senses(_at(raw, 1)),
    alternates: _alternates(_at(raw, 5)),
  );
}

Object? _at(List<Object?> list, int i) => i < list.length ? list[i] : null;

/// `body[0]` — the translated segments, rejoined.
String _primary(List<Object?> body) {
  final segments = _at(body, 0);
  if (segments is! List) return '';
  final out = StringBuffer();
  for (final seg in segments) {
    if (seg is List && seg.isNotEmpty && seg[0] != null) {
      out.write(seg[0].toString());
    }
  }
  return out.toString();
}

/// `body[1]` — dictionary entries, each
/// `[pos, [terms…], [[term, [reverse…], score, …], …], …]`.
List<TranslateSense> _senses(Object? block) {
  if (block is! List) return const <TranslateSense>[];
  final out = <TranslateSense>[];
  for (final entry in block) {
    if (entry is! List) continue;
    final terms = _terms(_at(entry, 2));
    // A part of speech with nothing usable under it is noise on screen.
    if (terms.isEmpty) continue;
    out.add(TranslateSense(pos: _str(_at(entry, 0)), terms: terms));
  }
  return out;
}

List<TranslateTerm> _terms(Object? block) {
  if (block is! List) return const <TranslateTerm>[];
  final out = <TranslateTerm>[];
  for (final entry in block) {
    if (entry is! List) continue;
    final term = _str(_at(entry, 0)).trim();
    // Without the word itself the row says nothing.
    if (term.isEmpty) continue;
    out.add(TranslateTerm(
      term: term,
      reverse: _strings(_at(entry, 1)),
      score: _firstNum(entry, const [3, 2]),
    ));
  }
  return out;
}

/// `body[5]` — alternate translations, buried a few levels down:
/// `[[source, …, [[alt, …], …], …], …]`.
List<String> _alternates(Object? block) {
  if (block is! List) return const <String>[];
  final out = <String>[];
  for (final group in block) {
    if (group is! List) continue;
    final candidates = _at(group, 2);
    if (candidates is! List) continue;
    for (final cand in candidates) {
      if (cand is! List || cand.isEmpty) continue;
      final alt = _str(cand[0]).trim();
      // Google repeats candidates across groups for multi-part input.
      if (alt.isNotEmpty && !out.contains(alt)) out.add(alt);
    }
  }
  return out;
}

List<String> _strings(Object? raw) {
  if (raw is! List) return const <String>[];
  final out = <String>[];
  for (final v in raw) {
    final s = _str(v).trim();
    if (s.isNotEmpty) out.add(s);
  }
  return out;
}

String _str(Object? v) => v == null ? '' : v.toString();

/// The frequency score, wherever in the row it happens to sit.
///
/// Observed responses put it at index 3 with index 2 null
/// (`["lake",["sjö","insjö"],null,0.4798]`), but the row is positional and
/// undocumented, so this takes the first number among [indices] rather than
/// pinning one. Most terms carry no score at all — only the leading senses do
/// — which is why callers must fall back to response order rather than
/// assuming they can sort.
///
/// Null rather than 0 for a missing score: "unknown" and "never used" are
/// different claims, and 0 would sort a scoreless sense to the bottom.
double? _firstNum(List<Object?> entry, List<int> indices) {
  for (final i in indices) {
    final v = _at(entry, i);
    if (v is num) return v.toDouble();
  }
  return null;
}
