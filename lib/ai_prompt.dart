/// The prompt handed to whichever AI app the share sheet lands on, and the
/// substitution that fills it in.
///
/// Editable from Tools so the wording can be tuned — a different target
/// language, a shorter answer, a focus on idiom — without a release. Kept free
/// of Flutter so the substitution rules can be tested directly.
library;

/// Placeholders a template may use. Anything else in braces is left alone, so
/// a prompt that legitimately contains `{}` is not mangled.
const String kAiPromptWord = '{word}';
const String kAiPromptSource = '{source}';
const String kAiPromptTarget = '{target}';

/// The shipped wording. Also what an empty or blank template falls back to —
/// saving an empty box should restore the default, not send a bare word.
const String kDefaultAiPromptTemplate =
    'Give me translation of "$kAiPromptWord" from $kAiPromptSource to '
    '$kAiPromptTarget with some usage examples/patterns and nuances including '
    'everyday, literary, oldfashioned versions in both languages.';

/// Fills [template] in. A placeholder may appear any number of times, or not
/// at all — a template that never mentions `{word}` is a deliberate choice
/// (say, "list ten Swedish idioms"), not an error to correct.
String renderAiPrompt(
  String template, {
  required String word,
  required String source,
  required String target,
}) {
  final t = template.trim().isEmpty ? kDefaultAiPromptTemplate : template;
  return t
      .replaceAll(kAiPromptWord, word)
      .replaceAll(kAiPromptSource, source)
      .replaceAll(kAiPromptTarget, target);
}
