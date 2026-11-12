const epubDefaultTtsReplacements = '->=could be\n→=could be';
const epubDefaultTtsNewlinePauseMs = 700;
const epubDefaultTtsParagraphPauseMs = 1200;
const epubMaxTtsPauseMs = 10000;

final _languageTag = RegExp(
  r'^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$',
  caseSensitive: false,
);
final _chapterLanguageElement = RegExp(
  r'<(html|body)(?=\s|>)[^>]*>',
  caseSensitive: false,
);
final _chapterLanguageAttribute = RegExp(
  r'''\s(xml:lang|lang)\s*=\s*(["'])([^"']*)\2''',
  caseSensitive: false,
);

String? epubLanguageTag(String? value) {
  final tag = value?.trim().replaceAll('_', '-');
  if (tag == null || !_languageTag.hasMatch(tag)) return null;
  final primary = tag.split('-').first.toLowerCase();
  return const {'und', 'mul', 'zxx'}.contains(primary) ? null : tag;
}

// The chapter wrapper discards the original html/body elements.
String? epubChapterLanguage(String html) {
  String? language;
  for (final element in _chapterLanguageElement.allMatches(html)) {
    String? htmlLang;
    String? xmlLang;
    for (final attribute in _chapterLanguageAttribute.allMatches(element[0]!)) {
      final tag = epubLanguageTag(attribute[3]);
      if (attribute[1]!.toLowerCase() == 'xml:lang') {
        xmlLang = tag;
      } else {
        htmlLang = tag;
      }
    }
    language = xmlLang ?? htmlLang ?? language;
    if (element[1]!.toLowerCase() == 'body') break;
  }
  return language;
}

// Some engines need a full locale even when the EPUB declares a bare
// language. Prefer an exact installed locale, then a voice in that language.
String epubSpeechEngineLocale(String requested, Iterable<String> available) {
  final tag = requested.toLowerCase();
  final primary = tag.split('-').first;
  String? sameLanguage;
  for (final locale in available) {
    final candidate = epubLanguageTag(locale)?.toLowerCase();
    if (candidate == tag) return locale;
    if (candidate?.split('-').first == primary) sameLanguage ??= locale;
  }
  return sameLanguage ?? requested;
}

List<(String, String)> parseEpubTtsReplacements(String input) {
  final rules = <(String, String)>[];
  for (final line in input.split('\n')) {
    if (line.trim().isEmpty) continue;
    final separator = line.indexOf('=');
    if (separator < 1 || line.substring(0, separator).trim().isEmpty) {
      throw const FormatException(
        'Enter one replacement per line, like ->=could be.',
      );
    }
    rules.add((
      line.substring(0, separator).trim(),
      line.substring(separator + 1).trim(),
    ));
  }
  return rules;
}

String applyEpubTtsReplacements(String text, List<(String, String)> rules) {
  for (final (source, spoken) in rules) {
    // Arrows are often written without spaces between the words they join.
    final replacement = source == '->' || source == '→' ? ' $spoken ' : spoken;
    text = text.replaceAll(source, replacement);
  }
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

// Android TTS limits utterances to 4000 UTF-16 code units. Keep a long
// paragraph readable by splitting at a nearby word or Unicode boundary.
Iterable<String> epubTtsUtterances(String text) sync* {
  const limit = 4000;
  while (text.length > limit) {
    var end = text.lastIndexOf(' ', limit);
    if (end < limit ~/ 2) {
      end = limit;
      if ((text.codeUnitAt(end) & 0xFC00) == 0xDC00) end--;
    }
    yield text.substring(0, end);
    text = text.substring(end).trimLeft();
  }
  if (text.isNotEmpty) yield text;
}

// Keep the chapter snapshot, including a first line truncated at a
// selection, while the playback loop is stopped or paused.
class EpubSpeechPosition {
  Future<List<Map<String, dynamic>>>? lines;
  int nextLine = 0;
  int speechOffset = 0;
  String? _spokenText;

  int resumeOffset(String text) {
    if (_spokenText != text) {
      _spokenText = text;
      speechOffset = 0;
    }
    return speechOffset;
  }

  void advanceLine() {
    nextLine++;
    speechOffset = 0;
    _spokenText = null;
  }

  void advanceChapter() {
    advanceLine();
    nextLine = 0;
    lines = null;
  }
}

// Collect the chapter's authored lines before sending text to the native
// speech engine. DOM line boundaries are independent of the viewport width.
const epubSpeechLinesJs = r'''
  window.__cupEpubSpeechLines = function(fromSelection) {
    var range = null;
    if (fromSelection) {
      var selection = window.getSelection();
      var selected = selection && !selection.isCollapsed && selection.rangeCount
        ? selection.getRangeAt(0) : window.__cupEpubSpeechSelection;
      if (!selected) return 'null';
      range = selected.cloneRange();
      range.collapse(true);
    }
    var lines = [];
    var parts = [];
    var start = -1, end = -1, breaks = 0;
    var paragraphBreak = false;
    var paragraphTags = /^(P|DIV|LI|DT|DD|BLOCKQUOTE|PRE|H[1-6])$/;
    var skip = /^(SCRIPT|X-SCRIPT|STYLE|NOSCRIPT|TEMPLATE|LINK|META|TEXTAREA|RT|RP)$/;

    function finishLine(breakAfter) {
      lines.push({
        text: parts.join('').replace(/\s+/g, ' ').trim(),
        start: start, end: end, breakAfter: breakAfter
      });
      parts = [];
      start = end = -1;
    }

    function addText(text, sentence) {
      if (!/\S/.test(text)) {
        if (parts.length && !breaks) parts.push(text);
        return;
      }
      if (parts.length && breaks) {
        for (var i = 1; i <= breaks; i++) {
          finishLine(i === breaks && paragraphBreak ? 'paragraph' : 'newline');
        }
      }
      breaks = 0;
      paragraphBreak = false;
      parts.push(text);
      if (sentence >= 0) {
        if (start < 0) start = sentence;
        end = sentence;
      }
    }

    function markBlockBoundary(paragraph) {
      breaks = Math.max(breaks, 1);
      paragraphBreak = paragraphBreak || paragraph;
    }

    function walk(el, sentence) {
      if (skip.test(el.tagName)) return;
      var style = window.getComputedStyle(el);
      if (style.display === 'none' || style.contentVisibility === 'hidden') return;
      if (el.tagName === 'BR') {
        if (style.visibility === 'visible') breaks++;
        return;
      }
      var block = el !== document.body && window.__cupEpubStartsOwnLine(el, style);
      var paragraph = block && (paragraphTags.test(el.tagName) ||
        el.getAttribute('role') === 'paragraph');
      if (block) markBlockBoundary(paragraph);
      if (el.classList.contains('cup-sent')) sentence = Number(el.dataset.sent);
      var preserve = /^(pre|pre-wrap|pre-line|break-spaces)$/.test(style.whiteSpace) ||
        /^(preserve|preserve-breaks|break-spaces)$/.test(style.whiteSpaceCollapse);
      for (var child = el.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === 1) {
          walk(child, sentence);
        } else if (child.nodeType === 3 && style.visibility === 'visible') {
          var text = child.data;
          if (range) {
            if (child === range.startContainer) text = text.slice(range.startOffset);
            else if (range.comparePoint(child, 0) < 0) continue;
            range = null;
          }
          if (preserve) {
            text.split(/\r\n?|\n/).forEach(function(part, i) {
              if (i) breaks++;
              addText(part, sentence);
            });
          } else {
            addText(text.replace(/[\t\n\r\f]+/g, ' '), sentence);
          }
        }
      }
      if (block) markBlockBoundary(paragraph);
    }

    walk(document.body, -1);
    if (parts.length) finishLine(null);
    return JSON.stringify(lines);
  };
''';
