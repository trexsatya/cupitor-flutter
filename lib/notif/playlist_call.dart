/// Validated playlist-level settings and per-item questions shared by bridge
/// validation and delivery. Questions stay separate from truncated shade text.
Map<String, Object?> parseCallConfig(Object? raw) {
  if (raw is! Map) throw const FormatException('bad_call');
  final language = raw['language'] ?? 'sv-SE';
  final retries = raw['max_retries'] ?? 3;
  final threshold = raw['match_threshold'] ?? 0.8;
  final voice = raw['voice_response'] ?? true;
  if (language is! String ||
      !RegExp(r'^[a-zA-Z]{2,3}(-[a-zA-Z]{2,4})?$').hasMatch(language) ||
      retries is! int || retries < 0 || retries > 10 ||
      threshold is! num || !threshold.isFinite || threshold < 0.7 || threshold > 1 ||
      voice is! bool) throw const FormatException('bad_call');
  return {'language': language, 'max_retries': retries,
    'match_threshold': threshold, 'voice_response': voice};
}

bool validPlaylistQuestion(Object? raw) {
  if (raw is! Map) return false;
  final question = raw['question'];
  if (question is! String || question.trim().isEmpty || question.length > 4000) return false;
  final type = raw['response_type'];
  bool labels(Object? value, int min, int max, int length) => value is List &&
      value.length >= min && value.length <= max && value.every((s) =>
        s is String && s.trim().isNotEmpty && s.length <= length &&
        s.replaceAll(RegExp(r'[.!?\s]'), '').isNotEmpty);
  if (type == 'text') return labels(raw['accepted_answers'], 1, 20, 500);
  if (type != 'choice' || !labels(raw['choices'], 2, 9, 200)) return false;
  final correct = raw['correct_choice_index'];
  return correct is int && correct >= 0 && correct < (raw['choices'] as List).length;
}
