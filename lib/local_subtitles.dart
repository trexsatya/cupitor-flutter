import 'dart:convert';

const maxLocalSubtitleBytes = 10 * 1024 * 1024;

/// SRT files commonly come from Windows editors as UTF-16 or Latin-1.
String decodeLocalSubtitles(List<int> bytes) {
  if (bytes.length > maxLocalSubtitleBytes) {
    throw const FormatException('The SRT file is larger than 10 MB.');
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('The UTF-16 SRT file is incomplete.');
    }
    final littleEndian = bytes[0] == 0xff;
    return String.fromCharCodes([
      for (var i = 2; i < bytes.length; i += 2)
        littleEndian
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Reads standard numbered or unnumbered SRT blocks, retaining multiline text.
/// Invalid blocks are skipped; an unusable file never replaces a transcript.
List<Map<String, dynamic>> parseLocalSrt(String text) {
  const stamp = r'(\d+):([0-5]\d):([0-5]\d)[,.](\d{1,3})';
  final timing = RegExp('^$stamp\\s+-->\\s+$stamp(?:\\s+.*)?\$');
  double seconds(RegExpMatch match, int offset) =>
      int.parse(match[offset + 1]!) * 3600 +
      int.parse(match[offset + 2]!) * 60 +
      int.parse(match[offset + 3]!) +
      int.parse(match[offset + 4]!.padRight(3, '0')) / 1000;
  final cues = <Map<String, dynamic>>[];
  final seen = <String>{};
  final normalized = text
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  for (final block in normalized.split(RegExp(r'\n[ \t]*\n'))) {
    final lines = block.trim().split('\n');
    final index =
        lines.isNotEmpty && RegExp(r'^\d+$').hasMatch(lines.first.trim())
        ? 1
        : 0;
    if (index >= lines.length) continue;
    final match = timing.firstMatch(lines[index].trim());
    if (match == null) continue;
    final start = seconds(match, 0), end = seconds(match, 4);
    final words = lines
        .skip(index + 1)
        .join('\n')
        .replaceAll(
          RegExp(r'</?(?:b|i|u|s|font)(?:\s[^>]*)?>', caseSensitive: false),
          '',
        )
        .trim();
    if (!start.isFinite || !end.isFinite || end <= start || words.isEmpty) {
      continue;
    }
    if (!seen.add(jsonEncode([start, end, words]))) continue;
    cues.add({'start': start, 'end': end, 'text': words});
  }
  cues.sort((a, b) {
    final start = (a['start'] as double).compareTo(b['start'] as double);
    return start != 0
        ? start
        : (a['end'] as double).compareTo(b['end'] as double);
  });
  return cues;
}

/// The page checks the request id AND the media identity captured before the
/// picker opened. All file content crosses the bridge as JSON data.
String localSubtitleResultJs(Map<String, dynamic> payload) =>
    'Boolean(window.__cupLocalSubtitlesResult && '
    'window.__cupLocalSubtitlesResult(${jsonEncode(payload)}))';
