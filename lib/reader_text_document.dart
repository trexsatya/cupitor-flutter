import 'dart:convert';
import 'dart:typed_data';

const readerBookExtensions = ['epub', 'docx', 'txt', 'rtf', 'pdf'];

String? readerBookExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot == -1) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return readerBookExtensions.contains(extension) ? extension : null;
}

String decodeReaderText(Uint8List bytes) {
  if (bytes.length >= 2) {
    final marker = ByteData.sublistView(bytes).getUint16(0);
    if (marker == 0xfeff || marker == 0xfffe) {
      if (bytes.length.isOdd) {
        throw const FormatException('Incomplete UTF-16 text');
      }
      final endian = marker == 0xfeff ? Endian.big : Endian.little;
      final data = ByteData.sublistView(bytes);
      return String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2) data.getUint16(i, endian),
      ]);
    }
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return String.fromCharCodes(bytes.map(_windows1252CodeUnit));
  }
}

int _windows1252CodeUnit(int byte) {
  const extensions = [
    0x20ac,
    0x0081,
    0x201a,
    0x0192,
    0x201e,
    0x2026,
    0x2020,
    0x2021,
    0x02c6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    0x008d,
    0x017d,
    0x008f,
    0x0090,
    0x2018,
    0x2019,
    0x201c,
    0x201d,
    0x2022,
    0x2013,
    0x2014,
    0x02dc,
    0x2122,
    0x0161,
    0x203a,
    0x0153,
    0x009d,
    0x017e,
    0x0178,
  ];
  return byte >= 0x80 && byte <= 0x9f ? extensions[byte - 0x80] : byte;
}

bool hasReaderRtfHeader(String source) =>
    _rtfHeader(source).startsWith(r'{\rtf');

String _rtfHeader(String source) => source.startsWith('ï»¿')
    ? source.substring(3).trimLeft()
    : source.trimLeft();

final _rtfControl = RegExp(
  r"\\(?:'([0-9a-fA-F]{2})|([a-z]+)(-?\d+)? ?|([^\r\n]))",
);
const _rtfDestinations = {
  'fonttbl',
  'colortbl',
  'stylesheet',
  'info',
  'pict',
  'object',
  'objdata',
  'header',
  'headerl',
  'headerr',
  'headerf',
  'footer',
  'footerl',
  'footerr',
  'footerf',
  'footnote',
  'annotation',
  'listtable',
  'listoverridetable',
  'xmlnstbl',
  'datastore',
  'themedata',
  'colorschememapping',
};
const _rtfTextControls = {
  'par': '\n',
  'line': '\n',
  'page': '\n\n',
  'tab': '\t',
  'cell': '\t',
  'row': '\n',
  'bullet': '•',
  'emdash': '—',
  'endash': '–',
  'lquote': '‘',
  'rquote': '’',
  'ldblquote': '“',
  'rdblquote': '”',
  'enspace': '\u2002',
  'emspace': '\u2003',
};

/// Extract readable text from RTF, including Unicode and Windows-1252
/// escapes. RTF destinations such as images and metadata are omitted.
String decodeReaderRtf(Uint8List bytes) {
  // Latin-1 preserves the original byte offsets for RTF's binary payloads.
  final source = _rtfHeader(latin1.decode(bytes));
  if (!hasReaderRtfHeader(source)) {
    throw const FormatException('Invalid RTF header');
  }

  final output = StringBuffer();
  final groups = <({bool hidden, int unicodeFallbackLength})>[];
  var hidden = false;
  var unicodeFallbackLength = 1;
  var fallbackRemaining = 0;

  void write(String value) {
    if (fallbackRemaining > 0) {
      fallbackRemaining--;
    } else if (!hidden) {
      output.write(value);
    }
  }

  for (var i = 0; i < source.length;) {
    final char = source[i];
    if (char == '{') {
      fallbackRemaining = 0;
      groups.add((
        hidden: hidden,
        unicodeFallbackLength: unicodeFallbackLength,
      ));
    } else if (char == '}') {
      fallbackRemaining = 0;
      final parent = groups.removeLast();
      hidden = parent.hidden;
      unicodeFallbackLength = parent.unicodeFallbackLength;
      if (groups.isEmpty) return output.toString();
    } else if (char == r'\') {
      final control = _rtfControl.matchAsPrefix(source, i);
      if (control == null) {
        throw const FormatException('Incomplete RTF control');
      }
      i = control.end;
      final hex = control[1];
      final name = control[2];
      final number = int.tryParse(control[3] ?? '');
      final symbol = control[4];
      if (name == 'bin') {
        if (number == null || number < 0 || number > source.length - i) {
          throw const FormatException('Invalid RTF binary data length');
        }
        i += number;
      } else if (symbol == '*' || _rtfDestinations.contains(name)) {
        hidden = true;
      } else if (name == 'uc' && number != null && number >= 0) {
        unicodeFallbackLength = number;
      } else if (name == 'u' && number != null && !hidden) {
        output.writeCharCode(number & 0xffff);
        fallbackRemaining = unicodeFallbackLength;
      } else if (hex != null) {
        write(
          String.fromCharCode(_windows1252CodeUnit(int.parse(hex, radix: 16))),
        );
      } else if (_rtfTextControls.containsKey(name)) {
        write(_rtfTextControls[name]!);
      } else if (symbol == '~') {
        write('\u00a0');
      } else if (symbol == '_') {
        write('\u2011');
      } else if (symbol == '-' ||
          symbol == '{' ||
          symbol == '}' ||
          symbol == r'\') {
        write(symbol == '-' ? '\u00ad' : symbol!);
      }
      continue;
    } else if (char != '\r' && char != '\n') {
      write(String.fromCharCode(_windows1252CodeUnit(char.codeUnitAt(0))));
    }
    i++;
  }
  throw const FormatException('Unclosed RTF document');
}

/// Split long text into reader sections at line or word boundaries.
Iterable<String> readerTextSections(String text) sync* {
  const sectionSize = 16000;
  final breaks = RegExp(r'\s');
  var start = 0;
  while (start + sectionSize < text.length) {
    final target = start + sectionSize;
    final lineBreak = text.lastIndexOf('\n', target);
    var end = lineBreak > start ? lineBreak + 1 : target;
    if (lineBreak <= start) {
      final separator = text.indexOf(breaks, target);
      end = separator == -1 ? text.length : separator + 1;
    }
    yield text.substring(start, end);
    start = end;
  }
  if (start < text.length) yield text.substring(start);
}

String readerTextHtml(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return normalized.split(RegExp(r'\n[ \t]*\n+')).map((paragraph) {
    final escaped = const HtmlEscape().convert(paragraph);
    return '<p>${escaped.replaceAll('\n', '<br/>')}</p>';
  }).join();
}
