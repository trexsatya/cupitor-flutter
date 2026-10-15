import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Reflowable DOCX content for the book reader. Conversion is entirely local;
/// Word's fixed page layout, floating objects and revision history are omitted.
class DocxDocument {
  DocxDocument({required this.title, this.author, required this.chapters});

  final String title;
  final String? author;
  final List<DocxChapter> chapters;

  static const css = '''
    .docx-table { border-collapse: collapse; width: 100%; }
    .docx-table td { border: 1px solid currentColor; padding: .4em; }
    .docx-list { margin-top: .3em; margin-bottom: .3em; }
    .docx-notes { border-top: 1px solid currentColor; margin-top: 2em; }
    .docx-tab { white-space: pre-wrap; }
  ''';

  /// Inspect the package contents rather than trusting a filename or MIME type.
  static bool isDocx(Archive archive) =>
      archive.findFile('word/document.xml') != null;

  static DocxDocument fromArchive(
    Archive archive, {
    String title = 'Untitled',
  }) => _DocxParser(archive).parse(title);
}

class DocxChapter {
  DocxChapter({required this.title, required this.html});

  final String title;
  final String html;
}

class _Relationship {
  _Relationship(this.target, this.external);

  final String target;
  final bool external;
}

class _DocxParser {
  _DocxParser(this.archive);

  final Archive archive;
  final _styles = <String, XmlElement>{};
  final _numbering = <String, XmlElement>{};
  final _abstractNumbering = <String, XmlElement>{};
  final _counters = <String, Map<int, int>>{};
  final _notes = <String, XmlElement>{};
  final _noteRels = <String, Map<String, _Relationship>>{};
  final _usedNotes = <String>{};
  final _chapterNotes = <String>[];
  bool _renderingNotes = false;
  Map<String, _Relationship> _rels = {};

  XmlDocument? _read(String path) {
    final file = archive.findFile(path);
    if (file == null || !file.isFile) return null;
    return XmlDocument.parse(utf8.decode(file.content as List<int>));
  }

  Map<String, _Relationship> _relationships(String part) {
    final slash = part.lastIndexOf('/');
    final dir = part.substring(0, slash + 1);
    final name = part.substring(slash + 1);
    final doc = _read('${dir}_rels/$name.rels');
    final result = <String, _Relationship>{};
    if (doc == null) return result;
    for (final rel in _descendants(doc, 'Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id == null || target == null) continue;
      final external = rel.getAttribute('TargetMode') == 'External';
      // Package-relative paths are normalized without extracting anything.
      final path = external
          ? target
          : Uri(
              path: part,
            ).resolve(target).path.replaceFirst(RegExp(r'^/'), '');
      result[id] = _Relationship(path, external);
    }
    return result;
  }

  DocxDocument parse(String fallbackTitle) {
    final doc = _read('word/document.xml');
    final body = doc == null ? null : _descendants(doc, 'body').firstOrNull;
    if (body == null) {
      throw const FormatException('Not a valid DOCX: missing document body');
    }
    final core = _read('docProps/core.xml');
    final title = core == null
        ? ''
        : _descendants(core, 'title').firstOrNull?.innerText.trim() ?? '';
    final author = core == null
        ? null
        : _descendants(core, 'creator').firstOrNull?.innerText.trim();
    final bookTitle = title.isEmpty ? fallbackTitle : title;
    final styles = _read('word/styles.xml');
    if (styles != null) {
      for (final style in _descendants(styles, 'style')) {
        final id = _attr(style, 'styleId');
        if (id != null) _styles[id] = style;
      }
    }
    final numbering = _read('word/numbering.xml');
    if (numbering != null) {
      for (final num in _descendants(numbering, 'num')) {
        final id = _attr(num, 'numId');
        if (id != null) _numbering[id] = num;
      }
      for (final num in _descendants(numbering, 'abstractNum')) {
        final id = _attr(num, 'abstractNumId');
        if (id != null) _abstractNumbering[id] = num;
      }
    }
    for (final kind in ['footnote', 'endnote']) {
      final part = 'word/${kind}s.xml';
      final notes = _read(part);
      if (notes == null) continue;
      _noteRels[kind] = _relationships(part);
      for (final note in _descendants(notes, kind)) {
        final id = int.tryParse(_attr(note, 'id') ?? '');
        if (id != null &&
            id >= 0 &&
            (_attr(note, 'type') ?? 'normal') == 'normal') {
          _notes['$kind-$id'] = note;
        }
      }
    }
    _rels = _relationships('word/document.xml');
    final chapters = <DocxChapter>[];
    var chapterTitle = bookTitle;
    var content = StringBuffer();
    void finish() {
      if (content.isEmpty) return;
      if (_chapterNotes.isNotEmpty) {
        _renderingNotes = true;
        content.write('<section class="docx-notes" role="doc-endnotes">');
        // Notes stay in the referencing chapter so links need no cross-page IO.
        for (final key in _chapterNotes) {
          final note = _notes[key];
          if (note == null) continue;
          final previous = _rels;
          _rels =
              _noteRels[key.startsWith('footnote') ? 'footnote' : 'endnote'] ??
              {};
          content.write(
            '<aside id="$key" role="doc-footnote">'
            '${_blocks(note.childElements)}'
            '<a href="#ref-$key" aria-label="Back to text">↩</a></aside>',
          );
          _rels = previous;
        }
        content.write('</section>');
        _renderingNotes = false;
      }
      chapters.add(DocxChapter(title: chapterTitle, html: content.toString()));
      content = StringBuffer();
      _chapterNotes.clear();
      _usedNotes.clear();
    }

    for (final block in body.childElements) {
      if (block.name.local == 'p' && _headingLevel(block) != null) {
        final headingText = _descendants(
          block,
          't',
        ).map((t) => t.innerText).join().trim();
        if (headingText.isNotEmpty) {
          finish();
          chapterTitle = headingText;
        }
      }
      content.write(_block(block));
    }
    finish();
    // Even an empty Word document must have a page (reader chrome assumes one).
    if (chapters.isEmpty) {
      chapters.add(DocxChapter(title: bookTitle, html: '<p></p>'));
    }
    return DocxDocument(
      title: bookTitle,
      author: author == null || author.isEmpty ? null : author,
      chapters: chapters,
    );
  }

  Iterable<XmlElement> _styleChain(XmlElement paragraph) sync* {
    var id = _attr(_child(_child(paragraph, 'pPr'), 'pStyle'), 'val');
    final seen = <String>{};
    while (id != null && seen.add(id)) {
      final style = _styles[id];
      if (style == null) break;
      yield style;
      id = _attr(_child(style, 'basedOn'), 'val');
    }
  }

  XmlElement? _paragraphProperty(XmlElement p, String name) {
    final own = _child(_child(p, 'pPr'), name);
    if (own != null) return own;
    for (final style in _styleChain(p)) {
      final inherited = _child(_child(style, 'pPr'), name);
      if (inherited != null) return inherited;
    }
    return null;
  }

  int? _headingLevel(XmlElement p) {
    final outline = int.tryParse(
      _attr(_paragraphProperty(p, 'outlineLvl'), 'val') ?? '',
    );
    if (outline != null) {
      return outline >= 0 && outline < 6 ? outline + 1 : null;
    }
    final id = _attr(_child(_child(p, 'pPr'), 'pStyle'), 'val') ?? '';
    for (final name in [
      id,
      ..._styleChain(p).map((s) => _attr(_child(s, 'name'), 'val') ?? ''),
    ]) {
      final match = RegExp(
        r'^heading\s*([1-6])$',
        caseSensitive: false,
      ).firstMatch(name);
      if (match != null) return int.parse(match.group(1)!);
    }
    return null;
  }

  String _blocks(Iterable<XmlElement> elements) => elements.map(_block).join();

  String _block(XmlElement el) {
    switch (el.name.local) {
      case 'p':
        return _paragraph(el);
      case 'tbl':
        final rows = _children(el, 'tr').map((row) {
          final cells = _children(row, 'tc').map((cell) {
            final span =
                int.tryParse(
                  _attr(_child(_child(cell, 'tcPr'), 'gridSpan'), 'val') ?? '',
                ) ??
                1;
            return '<td${span > 1 ? ' colspan="$span"' : ''}>'
                '${_blocks(cell.childElements)}</td>';
          }).join();
          return '<tr>$cells</tr>';
        }).join();
        return '<table class="docx-table"><tbody>$rows</tbody></table>';
      case 'sdt':
        return _blocks(_child(el, 'sdtContent')?.childElements ?? []);
      case 'ins':
      case 'customXml':
        return _blocks(el.childElements);
      default:
        return '';
    }
  }

  String _paragraph(XmlElement p) {
    var text = _inline(p);
    final level = _headingLevel(p);
    final alignment = _attr(_paragraphProperty(p, 'jc'), 'val');
    final cssAlign = alignment == 'both' ? 'justify' : alignment;
    final style = ['left', 'right', 'center', 'justify'].contains(cssAlign)
        ? ' style="text-align:$cssAlign"'
        : '';
    final numPr = _paragraphProperty(p, 'numPr');
    final numId = _attr(_child(numPr, 'numId'), 'val');
    if (numId != null && numId != '0') {
      final depth =
          (int.tryParse(_attr(_child(numPr, 'ilvl'), 'val') ?? '') ?? 0).clamp(
            0,
            8,
          );
      final num = _numbering[numId];
      final absId = _attr(_child(num, 'abstractNumId'), 'val');
      final abs = _abstractNumbering[absId];
      final override = num == null
          ? null
          : _children(
              num,
              'lvlOverride',
            ).where((e) => _attr(e, 'ilvl') == '$depth').firstOrNull;
      final lvl =
          _child(override, 'lvl') ??
          (abs == null
              ? null
              : _children(
                  abs,
                  'lvl',
                ).where((e) => _attr(e, 'ilvl') == '$depth').firstOrNull);
      final format = _attr(_child(lvl, 'numFmt'), 'val') ?? 'bullet';
      final start =
          int.tryParse(
            _attr(_child(override, 'startOverride'), 'val') ??
                _attr(_child(lvl, 'start'), 'val') ??
                '',
          ) ??
          1;
      final counters = _counters.putIfAbsent(numId, () => {});
      final count = counters[depth] = (counters[depth] ?? start - 1) + 1;
      counters.removeWhere((k, _) => k > depth);
      final ordered = format != 'bullet' && format != 'none';
      final tag = ordered ? 'ol' : 'ul';
      final type = {
        'lowerLetter': 'a',
        'upperLetter': 'A',
        'lowerRoman': 'i',
        'upperRoman': 'I',
      }[format];
      return '<$tag class="docx-list" style="margin-left:${depth * 1.5}em'
          '${format == 'none' ? ';list-style:none' : ''}"'
          '${ordered ? ' start="$count"' : ''}${type == null ? '' : ' type="$type"'}>'
          '<li$style>$text</li></$tag>';
    }
    final tag = level == null ? 'p' : 'h$level';
    // Empty paragraphs carry intentional spacing without putting NBSP in search.
    if (text.isEmpty) text = '<br/>';
    return '<$tag$style>$text</$tag>';
  }

  String _inline(XmlElement parent) {
    final out = StringBuffer();
    for (final el in parent.childElements) {
      switch (el.name.local) {
        case 'r':
          final props = _child(el, 'rPr');
          if (_on(_child(props, 'vanish'))) break;
          var value = _inline(el);
          if (_on(_child(props, 'b'))) value = '<strong>$value</strong>';
          if (_on(_child(props, 'i'))) value = '<em>$value</em>';
          final underline = _child(props, 'u');
          if (underline != null &&
              _attr(underline, 'val') != 'none' &&
              _on(underline)) {
            value = '<u>$value</u>';
          }
          if (_on(_child(props, 'strike'))) value = '<s>$value</s>';
          final vert = _attr(_child(props, 'vertAlign'), 'val');
          if (vert == 'superscript') value = '<sup>$value</sup>';
          if (vert == 'subscript') value = '<sub>$value</sub>';
          out.write(value);
          break;
        case 't':
          out.write(_escape(el.innerText));
          break;
        case 'tab':
          out.write('<span class="docx-tab">\t</span>');
          break;
        case 'br':
        case 'cr':
          out.write('<br/>');
          break;
        case 'noBreakHyphen':
          out.write('‑');
          break;
        case 'softHyphen':
          out.write('\u00ad');
          break;
        case 'hyperlink':
          final rel = _rels[_attr(el, 'id')];
          final anchor = _attr(el, 'anchor');
          final href = rel != null && rel.external && _safeLink(rel.target)
              ? rel.target
              : anchor == null
              ? null
              : '#${Uri.encodeComponent(anchor)}';
          final value = _inline(el);
          out.write(
            href == null ? value : '<a href="${_escape(href)}">$value</a>',
          );
          break;
        case 'bookmarkStart':
          final name = _attr(el, 'name');
          if (name != null) out.write('<span id="${_escape(name)}"></span>');
          break;
        case 'drawing':
        case 'pict':
          out.write(_image(el));
          break;
        case 'footnoteReference':
        case 'endnoteReference':
          if (_renderingNotes) break;
          final kind = el.name.local == 'footnoteReference'
              ? 'footnote'
              : 'endnote';
          final id = int.tryParse(_attr(el, 'id') ?? '');
          final key = '$kind-$id';
          if (!_notes.containsKey(key)) break;
          if (_usedNotes.add(key)) _chapterNotes.add(key);
          out.write(
            '<sup id="ref-$key"><a href="#$key" role="doc-noteref">'
            '$id</a></sup>',
          );
          break;
        case 'sdt':
          final content = _child(el, 'sdtContent');
          if (content != null) out.write(_inline(content));
          break;
        case 'ins':
        case 'smartTag':
        case 'customXml':
        case 'fldSimple':
          out.write(_inline(el));
          break;
        // Field instructions, deleted text and unsupported embedded objects
        // are deliberately not interpreted as HTML or executable content.
      }
    }
    return out.toString();
  }

  String _image(XmlElement el) {
    final out = StringBuffer();
    for (final image in [
      ..._descendants(el, 'blip'),
      ..._descendants(el, 'imagedata'),
    ]) {
      final id = _attr(image, 'embed') ?? _attr(image, 'id');
      final rel = _rels[id];
      if (rel == null || rel.external) continue;
      final file = archive.findFile(Uri.decodeFull(rel.target));
      if (file == null || !file.isFile) continue;
      final ext = rel.target.split('.').last.toLowerCase();
      final mime = {
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'bmp': 'image/bmp',
      }[ext];
      if (mime == null) continue;
      final props = _descendants(el, 'docPr').firstOrNull;
      final alt =
          props?.getAttribute('descr') ?? props?.getAttribute('name') ?? '';
      out.write(
        '<img src="data:$mime;base64,${base64Encode(file.content as List<int>)}"'
        ' alt="${_escape(alt)}"/>',
      );
    }
    return out.toString();
  }
}

Iterable<XmlElement> _descendants(XmlNode node, String name) =>
    node.descendants.whereType<XmlElement>().where((e) => e.name.local == name);

Iterable<XmlElement> _children(XmlElement node, String name) =>
    node.childElements.where((e) => e.name.local == name);

XmlElement? _child(XmlElement? node, String name) =>
    node == null ? null : _children(node, name).firstOrNull;

String? _attr(XmlElement? el, String name) =>
    el?.attributes.where((a) => a.name.local == name).firstOrNull?.value;

bool _on(XmlElement? el) =>
    el != null &&
    !['0', 'false', 'off'].contains((_attr(el, 'val') ?? '').toLowerCase());

bool _safeLink(String target) => [
  'http',
  'https',
  'mailto',
  'tel',
].contains(Uri.tryParse(target)?.scheme.toLowerCase());

String _escape(String text) => const HtmlEscape().convert(text);
