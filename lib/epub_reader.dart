// EPUB reader for Cupitor.
//
// Why this file exists separately from main.dart: main.dart is already huge
// and the reader is a self-contained feature with its own parser, model, and
// UI. Public surface is small:
//
//   await openEpubReader(context, source: <File|Uri>, onLookup: (word, ctx) {...});
//
// The host (main.dart) provides `onLookup` so the same dialog1-based
// dictionary flow used everywhere else handles tap-word and selection
// lookups from inside an EPUB chapter. No assumption about how the host
// shows the lookup — it just receives (word, surroundingContext) and does
// whatever it normally does for a selected word.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:xml/xml.dart' as xml;

// ─── Library: previously-opened EPUBs ────────────────────────────────────
// Persisted in SharedPreferences under `epub_library` as a JSON list. We
// keep the list bounded so a user who's opened many books doesn't grow the
// prefs blob unbounded — the least-recently-touched entries fall off when
// we exceed `_libraryMax`. Each entry remembers where the file sits on
// disk plus enough metadata to render a library row without re-parsing.
const String _libraryKey = 'epub_library';
const int _libraryMax = 64;

class EpubLibraryEntry {
  EpubLibraryEntry({
    required this.key,
    required this.path,
    required this.title,
    this.author,
    this.coverPath,
    DateTime? lastOpened,
  }) : lastOpened = lastOpened ?? DateTime.now();

  /// SHA-1 hex of the file's bytes — survives renames/moves and used to
  /// key reading state (so resume position follows the book, not the path).
  final String key;
  String path;
  String title;
  String? author;
  String? coverPath;
  DateTime lastOpened;

  Map<String, dynamic> toJson() => {
        'key': key,
        'path': path,
        'title': title,
        if (author != null) 'author': author,
        if (coverPath != null) 'coverPath': coverPath,
        'lastOpened': lastOpened.toIso8601String(),
      };

  static EpubLibraryEntry fromJson(Map<String, dynamic> j) => EpubLibraryEntry(
        key: j['key'] as String,
        path: j['path'] as String,
        title: j['title'] as String? ?? 'Untitled',
        author: j['author'] as String?,
        coverPath: j['coverPath'] as String?,
        lastOpened: DateTime.tryParse(j['lastOpened'] as String? ?? '') ?? DateTime.now(),
      );
}

class EpubLibrary {
  EpubLibrary._(this._prefs, this.entries);

  final SharedPreferences _prefs;
  final List<EpubLibraryEntry> entries;

  static Future<EpubLibrary> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_libraryKey);
    final list = <EpubLibraryEntry>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final it in decoded) {
            if (it is Map<String, dynamic>) list.add(EpubLibraryEntry.fromJson(it));
          }
        }
      } catch (_) { /* corrupt prefs blob — start fresh */ }
    }
    list.sort((a, b) => b.lastOpened.compareTo(a.lastOpened));
    return EpubLibrary._(prefs, list);
  }

  Future<void> touch(EpubLibraryEntry e) async {
    entries.removeWhere((x) => x.key == e.key);
    e.lastOpened = DateTime.now();
    entries.insert(0, e);
    while (entries.length > _libraryMax) {
      entries.removeLast();
    }
    await _persist();
  }

  Future<void> remove(String key) async {
    entries.removeWhere((x) => x.key == key);
    await _persist();
  }

  Future<void> _persist() =>
      _prefs.setString(_libraryKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
}

// ─── Highlight model ─────────────────────────────────────────────────────
// We avoid storing DOM paths (those break the moment the chapter HTML
// changes for any reason). Instead each highlight remembers its chapter
// index plus the matched text bracketed by ~32 chars of prefix/suffix —
// enough to locate the exact occurrence on restore even when the same
// phrase appears multiple times in the chapter. `color` is one of:
// 'yellow' (default), 'green', 'pink', 'blue'.
class EpubHighlight {
  EpubHighlight({
    required this.chapterIdx,
    required this.text,
    required this.prefix,
    required this.suffix,
    this.color = 'yellow',
    this.note,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int chapterIdx;
  final String text;
  final String prefix;
  final String suffix;
  String color;
  String? note;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'chapterIdx': chapterIdx,
        'text': text,
        'prefix': prefix,
        'suffix': suffix,
        'color': color,
        if (note != null) 'note': note,
        'createdAt': createdAt.toIso8601String(),
      };

  static EpubHighlight fromJson(Map<String, dynamic> j) => EpubHighlight(
        chapterIdx: (j['chapterIdx'] as num?)?.toInt() ?? 0,
        text: j['text'] as String? ?? '',
        prefix: j['prefix'] as String? ?? '',
        suffix: j['suffix'] as String? ?? '',
        color: j['color'] as String? ?? 'yellow',
        note: j['note'] as String?,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      );

  /// Identity key for delete operations — `text+prefix+suffix` is unique
  /// within a chapter (that's how we located the span in the first place).
  String get id => '$chapterIdx::$prefix::$text::$suffix';
}

// ─── Reading state: per-book settings & resume position ─────────────────
// Stored under `epub_state_<sha1>` so renaming the file doesn't lose
// position. Saved every chapter change + throttled while scrolling.
class EpubReadingState {
  EpubReadingState({
    this.chapterIdx = 0,
    this.scrollPct = 0.0,
    this.bookmarks = const <int>[],
    this.fontScale = 1.0,
    this.fontFamily = 'serif',
    this.theme = 'light',
    this.lineHeight = 1.6,
    this.paginated = false,
    this.ttsRate = 0.5,
    this.highlights = const <EpubHighlight>[],
  });

  int chapterIdx;
  double scrollPct;            // 0..1 within the current chapter
  List<int> bookmarks;         // chapter indices (one-tap return points)
  double fontScale;            // 0.7..2.5 — multiplier on base 18px
  String fontFamily;           // 'serif' | 'sans' | 'monospace'
  String theme;                // 'light' | 'sepia' | 'dark'
  double lineHeight;           // 1.2..2.2
  bool paginated;              // false = scroll, true = column pagination
  double ttsRate;              // 0.2..1.0 — flutter_tts speech rate
  List<EpubHighlight> highlights;

  Map<String, dynamic> toJson() => {
        'chapterIdx': chapterIdx,
        'scrollPct': scrollPct,
        'bookmarks': bookmarks,
        'fontScale': fontScale,
        'fontFamily': fontFamily,
        'theme': theme,
        'lineHeight': lineHeight,
        'paginated': paginated,
        'ttsRate': ttsRate,
        'highlights': highlights.map((h) => h.toJson()).toList(),
      };

  static EpubReadingState fromJson(Map<String, dynamic> j) => EpubReadingState(
        chapterIdx: (j['chapterIdx'] as num?)?.toInt() ?? 0,
        scrollPct: (j['scrollPct'] as num?)?.toDouble() ?? 0.0,
        bookmarks: ((j['bookmarks'] as List?) ?? const [])
            .whereType<num>().map((n) => n.toInt()).toList(),
        fontScale: (j['fontScale'] as num?)?.toDouble() ?? 1.0,
        fontFamily: j['fontFamily'] as String? ?? 'serif',
        theme: j['theme'] as String? ?? 'light',
        lineHeight: (j['lineHeight'] as num?)?.toDouble() ?? 1.6,
        paginated: j['paginated'] as bool? ?? false,
        ttsRate: (j['ttsRate'] as num?)?.toDouble() ?? 0.5,
        highlights: ((j['highlights'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => EpubHighlight.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  static String _prefsKey(String bookKey) => 'epub_state_$bookKey';

  static Future<EpubReadingState> load(String bookKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey(bookKey));
    if (raw == null || raw.isEmpty) return EpubReadingState();
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic>) return EpubReadingState.fromJson(j);
    } catch (_) {}
    return EpubReadingState();
  }

  Future<void> save(String bookKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey(bookKey), jsonEncode(toJson()));
  }
}

// ─── EPUB parser ─────────────────────────────────────────────────────────
// EPUB = zip with:
//   META-INF/container.xml → tells us where the OPF lives.
//   <book>.opf             → manifest (id → href + media-type) + spine
//                            (reading order, ids into the manifest) +
//                            metadata (title, creator).
//   *.xhtml / *.html       → chapter content.
//   toc.ncx or nav.xhtml   → table of contents.
//   <resources>            → images, CSS, fonts — kept in-memory and
//                            inlined into chapter HTML at render time so
//                            the WebView doesn't need any external HTTP.
//
// We hand-roll this instead of pulling `epubx` because EPUB is small and
// `epubx` has historically been a pain on newer Dart SDKs.

class EpubChapter {
  EpubChapter({
    required this.id,
    required this.href,
    required this.title,
    required this.html,
  });

  final String id;
  final String href;     // path inside the zip (POSIX-style)
  final String title;    // from TOC; falls back to "Chapter N"
  final String html;     // raw XHTML body content
}

class EpubTocEntry {
  EpubTocEntry({required this.title, required this.chapterIdx, this.children = const []});

  final String title;
  final int chapterIdx;             // -1 = section header with no own page
  final List<EpubTocEntry> children;
}

class EpubBook {
  EpubBook({
    required this.title,
    required this.author,
    required this.chapters,
    required this.toc,
    required this.resources,
    required this.cssText,
    required this.basePathInZip,
    required this.key,
    required this.filePath,
    this.coverBytes,
    this.coverMime,
  });

  final String title;
  final String? author;
  final List<EpubChapter> chapters;
  final List<EpubTocEntry> toc;
  /// Resource path (inside zip) → data: URL we inline into chapter HTML.
  final Map<String, String> resources;
  /// Concatenated CSS the book brought along — pre-stripped of @import
  /// (those would fail since we don't serve external files).
  final String cssText;
  /// Where in the zip the OPF lived — needed to resolve relative hrefs.
  final String basePathInZip;
  /// SHA-1 of the file's bytes; used as the resume-state key.
  final String key;
  /// Path on disk we opened. Stored back into the library entry.
  final String filePath;
  /// Raw bytes of the cover image (JPEG/PNG/SVG) if the book had one.
  final Uint8List? coverBytes;
  final String? coverMime;

  static Future<EpubBook> openFile(File file) async {
    final bytes = await file.readAsBytes();
    final key = sha1.convert(bytes).toString();
    return _parse(bytes, key, file.path);
  }

  static Future<EpubBook> _parse(Uint8List bytes, String key, String filePath) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, ArchiveFile>{};
    for (final f in archive) {
      if (f.isFile) files[f.name] = f;
    }

    // 1) container.xml → OPF path.
    final container = files['META-INF/container.xml'];
    if (container == null) {
      throw const FormatException('Not a valid EPUB: missing META-INF/container.xml');
    }
    final containerDoc = xml.XmlDocument.parse(utf8.decode(container.content as List<int>));
    final rootfile = containerDoc.findAllElements('rootfile').firstOrNull;
    final opfPath = rootfile?.getAttribute('full-path');
    if (opfPath == null) {
      throw const FormatException('Not a valid EPUB: container.xml has no rootfile');
    }
    final opfFile = files[opfPath];
    if (opfFile == null) {
      throw FormatException('Not a valid EPUB: missing $opfPath');
    }
    final opfDoc = xml.XmlDocument.parse(utf8.decode(opfFile.content as List<int>));
    final basePath = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';

    // 2) Metadata: title, author.
    String title = 'Untitled';
    String? author;
    final metaEls = opfDoc.findAllElements('metadata').firstOrNull;
    if (metaEls != null) {
      // dc:title can appear multiple times; pick the first non-empty.
      for (final el in metaEls.findElements('dc:title')) {
        final t = el.innerText.trim();
        if (t.isNotEmpty) { title = t; break; }
      }
      if (title == 'Untitled') {
        for (final el in metaEls.findAllElements('title')) {
          final t = el.innerText.trim();
          if (t.isNotEmpty) { title = t; break; }
        }
      }
      for (final el in metaEls.findElements('dc:creator')) {
        final a = el.innerText.trim();
        if (a.isNotEmpty) { author = a; break; }
      }
      if (author == null) {
        for (final el in metaEls.findAllElements('creator')) {
          final a = el.innerText.trim();
          if (a.isNotEmpty) { author = a; break; }
        }
      }
    }

    // 3) Manifest: id → {href, mediaType, properties}.
    // `properties` matters for EPUB3 — the nav document is the manifest
    // item whose properties attribute *contains* the word "nav" (space-
    // separated list).
    final manifest = <String, _ManifestItem>{};
    for (final item in opfDoc.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      final mt = item.getAttribute('media-type') ?? '';
      final props = item.getAttribute('properties') ?? '';
      if (id != null && href != null) {
        manifest[id] = _ManifestItem(href: href, mediaType: mt, properties: props);
      }
    }

    // 4) Spine: ordered list of idrefs → reading order.
    final spineIds = <String>[];
    for (final itemref in opfDoc.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      if (idref == null) continue;
      // `linear="no"` items are aux content (footnotes, copyright pages).
      // We still include them so navigation isn't surprising — but they
      // sort to the end of the spine in some books which is fine.
      spineIds.add(idref);
    }

    // 5) Resources: images / CSS / fonts → data: URLs we'll inline. Also
    //    collect the CSS text up front so we can ship it with each chapter
    //    (mixed in with our reader theme CSS).
    final resources = <String, String>{};
    final cssBuf = StringBuffer();
    for (final entry in manifest.entries) {
      final href = entry.value.href;
      final mt = entry.value.mediaType.toLowerCase();
      final fullPath = _joinPath(basePath, href);
      final file = files[fullPath];
      if (file == null) continue;
      if (mt.startsWith('image/')) {
        resources[href] = 'data:$mt;base64,${base64Encode(file.content as List<int>)}';
      } else if (mt == 'text/css') {
        // Strip @import — those reference other CSS files which we don't
        // serve. Everything else (selectors, font-face data: URLs) is OK.
        final cssText = utf8.decode(file.content as List<int>, allowMalformed: true);
        final cleaned = cssText.replaceAll(RegExp(r'@import[^;]*;'), '');
        cssBuf.writeln(cleaned);
      } else if (mt.startsWith('font/') || mt == 'application/vnd.ms-opentype'
          || mt == 'application/x-font-ttf' || mt == 'application/font-woff'
          || mt == 'application/font-woff2') {
        resources[href] = 'data:$mt;base64,${base64Encode(file.content as List<int>)}';
      }
    }

    // 6) Chapters: spine in order, with hrefs resolved against basePath.
    final chapters = <EpubChapter>[];
    final hrefToChapterIdx = <String, int>{};
    for (var i = 0; i < spineIds.length; i++) {
      final m = manifest[spineIds[i]];
      if (m == null) continue;
      final fullPath = _joinPath(basePath, m.href);
      final file = files[fullPath];
      if (file == null) continue;
      final rawHtml = utf8.decode(file.content as List<int>, allowMalformed: true);
      final bodyHtml = _extractBody(rawHtml);
      // Resource paths inside chapter HTML are relative to the chapter's
      // own folder, not the OPF basePath; rewrite them to data: URLs.
      final chapterDir = m.href.contains('/')
          ? m.href.substring(0, m.href.lastIndexOf('/') + 1)
          : '';
      final rewritten = _rewriteHrefs(bodyHtml, resources, chapterDir);
      chapters.add(EpubChapter(
        id: spineIds[i],
        href: m.href,
        title: 'Chapter ${i + 1}',
        html: rewritten,
      ));
      // Used by TOC resolution: an href like "ch3.xhtml#sec2" maps to the
      // chapter whose href starts with "ch3.xhtml".
      hrefToChapterIdx[m.href.split('#').first] = chapters.length - 1;
    }

    // 7) Cover image: tried three ways in order of reliability.
    //    a) <item properties="cover-image"> (EPUB3).
    //    b) <meta name="cover" content="..."> + manifest id (EPUB2).
    //    c) First image in the manifest with "cover" in its href as a
    //       last resort — many older books name it that way.
    Uint8List? coverBytes;
    String? coverMime;
    String? coverId;
    for (final entry in manifest.entries) {
      if (entry.value.properties.contains('cover-image')) {
        coverId = entry.key; break;
      }
    }
    if (coverId == null && metaEls != null) {
      for (final m in metaEls.findAllElements('meta')) {
        if ((m.getAttribute('name') ?? '').toLowerCase() == 'cover') {
          coverId = m.getAttribute('content');
          break;
        }
      }
    }
    if (coverId != null && manifest[coverId] != null) {
      final m = manifest[coverId]!;
      final fullPath = _joinPath(basePath, m.href);
      final f = files[fullPath];
      if (f != null && m.mediaType.startsWith('image/')) {
        coverBytes = Uint8List.fromList(f.content as List<int>);
        coverMime = m.mediaType;
      }
    }
    if (coverBytes == null) {
      for (final entry in manifest.entries) {
        final mt = entry.value.mediaType.toLowerCase();
        if (!mt.startsWith('image/')) continue;
        if (!entry.value.href.toLowerCase().contains('cover')) continue;
        final fullPath = _joinPath(basePath, entry.value.href);
        final f = files[fullPath];
        if (f != null) {
          coverBytes = Uint8List.fromList(f.content as List<int>);
          coverMime = entry.value.mediaType;
          break;
        }
      }
    }

    // 8) TOC: prefer EPUB3 nav.xhtml, fall back to EPUB2 toc.ncx.
    final toc = _parseToc(files, manifest, basePath, hrefToChapterIdx);
    // Promote TOC titles into chapter titles where possible.
    void applyTocTitles(List<EpubTocEntry> entries) {
      for (final e in entries) {
        if (e.chapterIdx >= 0 && e.chapterIdx < chapters.length) {
          final c = chapters[e.chapterIdx];
          chapters[e.chapterIdx] = EpubChapter(
            id: c.id, href: c.href, title: e.title.isNotEmpty ? e.title : c.title, html: c.html);
        }
        applyTocTitles(e.children);
      }
    }
    applyTocTitles(toc);

    return EpubBook(
      title: title,
      author: author,
      chapters: chapters,
      toc: toc,
      resources: resources,
      cssText: cssBuf.toString(),
      basePathInZip: basePath,
      key: key,
      filePath: filePath,
      coverBytes: coverBytes,
      coverMime: coverMime,
    );
  }

  /// Where covers live on disk — keyed by the book's SHA-1 so the file
  /// name is collision-free.
  static Future<File> _coverFileFor(String bookKey, String ext) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/epubs/covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$bookKey.$ext');
  }

  /// Persist the cover to disk so the library row can show it without
  /// re-parsing the book. Returns the file path or null when the book
  /// shipped no cover.
  Future<String?> saveCover() async {
    if (coverBytes == null) return null;
    final mime = (coverMime ?? '').toLowerCase();
    final ext = mime.contains('png') ? 'png'
              : mime.contains('gif') ? 'gif'
              : mime.contains('svg') ? 'svg'
              : mime.contains('webp') ? 'webp'
              : 'jpg';
    final f = await _coverFileFor(key, ext);
    if (!await f.exists()) await f.writeAsBytes(coverBytes!, flush: true);
    return f.path;
  }

  static String _joinPath(String base, String rel) {
    // POSIX-style join — zip entries use forward slashes regardless of OS.
    if (rel.startsWith('/')) return rel.substring(1);
    if (base.isEmpty) return rel;
    final segs = (base + rel).split('/');
    final out = <String>[];
    for (final s in segs) {
      if (s == '.' || s.isEmpty) continue;
      if (s == '..') { if (out.isNotEmpty) out.removeLast(); continue; }
      out.add(s);
    }
    return out.join('/');
  }

  static String _extractBody(String html) {
    // Strip XML prolog / DOCTYPE / outer <html>/<head>/<body> tags so we
    // can embed the chapter inside our own document. A regex is good
    // enough here — we don't need full HTML parsing for the body grab,
    // and pulling in `html` would double our dep weight.
    final m = RegExp(r'<body[^>]*>([\s\S]*?)<\/body>', caseSensitive: false).firstMatch(html);
    if (m != null) return m.group(1)!;
    return html; // best-effort fallback
  }

  static String _rewriteHrefs(String html, Map<String, String> resources, String chapterDir) {
    // src= and href= → data: URLs for resources we have in the zip. We
    // resolve chapter-relative paths against the chapter's directory.
    // External http(s) URLs are left alone — those still work in the
    // WebView and aren't security-sensitive.
    return html.replaceAllMapped(
      RegExp(r'''(src|href)\s*=\s*(["'])([^"']+)(["'])''', caseSensitive: false),
      (m) {
        final attr = m.group(1)!;
        final q = m.group(2)!;
        final url = m.group(3)!;
        final endQ = m.group(4)!;
        if (url.startsWith('data:') || url.startsWith('http://') || url.startsWith('https://')
            || url.startsWith('#') || url.startsWith('mailto:')) {
          return m.group(0)!;
        }
        // Strip fragment for lookup; fragments inside chapter files
        // navigate within the same chapter and we don't need a different
        // resource for them.
        final clean = url.split('#').first;
        final resolved = _joinPath(chapterDir, clean);
        final dataUrl = resources[resolved] ?? resources[clean] ?? resources[url];
        if (dataUrl != null) return '$attr=$q$dataUrl$endQ';
        return m.group(0)!;
      },
    );
  }

  static List<EpubTocEntry> _parseToc(
    Map<String, ArchiveFile> files,
    Map<String, _ManifestItem> manifest,
    String basePath,
    Map<String, int> hrefToChapterIdx,
  ) {
    // EPUB3 nav.xhtml: item with properties="nav"
    for (final m in manifest.values) {
      if ((m.properties).contains('nav')) {
        final f = files[_joinPath(basePath, m.href)];
        if (f != null) {
          try {
            return _parseNavXhtml(utf8.decode(f.content as List<int>, allowMalformed: true), hrefToChapterIdx);
          } catch (_) {}
        }
      }
    }
    // EPUB2 NCX: item with media-type=application/x-dtbncx+xml
    for (final m in manifest.values) {
      if (m.mediaType == 'application/x-dtbncx+xml') {
        final f = files[_joinPath(basePath, m.href)];
        if (f != null) {
          try {
            return _parseNcx(utf8.decode(f.content as List<int>, allowMalformed: true), hrefToChapterIdx);
          } catch (_) {}
        }
      }
    }
    // Last resort: 1 TOC entry per chapter using the chapter's title.
    return [];
  }

  static List<EpubTocEntry> _parseNavXhtml(String text, Map<String, int> hrefToIdx) {
    final doc = xml.XmlDocument.parse(text);
    // Pick the first <nav epub:type="toc"> or just any <nav>.
    xml.XmlElement? nav;
    for (final el in doc.findAllElements('nav')) {
      final t = el.getAttribute('epub:type') ?? el.getAttribute('type') ?? '';
      if (t.contains('toc')) { nav = el; break; }
    }
    nav ??= doc.findAllElements('nav').firstOrNull;
    if (nav == null) return [];
    final firstOl = nav.findElements('ol').firstOrNull
        ?? nav.findAllElements('ol').firstOrNull;
    if (firstOl == null) return [];
    return _readNavOl(firstOl, hrefToIdx);
  }

  static List<EpubTocEntry> _readNavOl(xml.XmlElement ol, Map<String, int> hrefToIdx) {
    final out = <EpubTocEntry>[];
    for (final li in ol.findElements('li')) {
      String title = '';
      String? href;
      final a = li.findElements('a').firstOrNull;
      if (a != null) {
        title = a.innerText.trim();
        href = a.getAttribute('href');
      } else {
        final span = li.findElements('span').firstOrNull;
        if (span != null) title = span.innerText.trim();
      }
      final children = li.findElements('ol').firstOrNull;
      final kids = children != null ? _readNavOl(children, hrefToIdx) : const <EpubTocEntry>[];
      int idx = -1;
      if (href != null) {
        idx = hrefToIdx[href.split('#').first] ?? -1;
      }
      out.add(EpubTocEntry(title: title, chapterIdx: idx, children: kids));
    }
    return out;
  }

  static List<EpubTocEntry> _parseNcx(String text, Map<String, int> hrefToIdx) {
    final doc = xml.XmlDocument.parse(text);
    final navMap = doc.findAllElements('navMap').firstOrNull;
    if (navMap == null) return [];
    return _readNcxNavPoints(navMap.findElements('navPoint'), hrefToIdx);
  }

  static List<EpubTocEntry> _readNcxNavPoints(
      Iterable<xml.XmlElement> points, Map<String, int> hrefToIdx) {
    final out = <EpubTocEntry>[];
    for (final p in points) {
      final label = p.findElements('navLabel').firstOrNull
          ?.findElements('text').firstOrNull
          ?.innerText.trim() ?? '';
      final content = p.findElements('content').firstOrNull;
      final src = content?.getAttribute('src') ?? '';
      final idx = hrefToIdx[src.split('#').first] ?? -1;
      final kids = _readNcxNavPoints(p.findElements('navPoint'), hrefToIdx);
      out.add(EpubTocEntry(title: label, chapterIdx: idx, children: kids));
    }
    return out;
  }
}

class _ManifestItem {
  _ManifestItem({required this.href, required this.mediaType, this.properties = ''});
  final String href;
  final String mediaType;
  final String properties;
}

// ─── EPUB acquisition: device storage, URL download ──────────────────────
// All paths funnel through `cacheEpubFromBytes` so the file lives in a
// known directory we can prune later if needed.

Future<Directory> _epubCacheDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/epubs');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<File> cacheEpubFromBytes(Uint8List bytes, {String? suggestedName}) async {
  final hash = sha1.convert(bytes).toString();
  final name = (suggestedName == null || suggestedName.isEmpty)
      ? '$hash.epub'
      : _safeFileName(suggestedName);
  final dir = await _epubCacheDir();
  final f = File('${dir.path}/$name');
  // If the file with this name exists but contents differ, append the hash.
  if (await f.exists()) {
    final existing = await f.readAsBytes();
    final existingHash = sha1.convert(existing).toString();
    if (existingHash != hash) {
      final stem = name.endsWith('.epub') ? name.substring(0, name.length - 5) : name;
      final f2 = File('${dir.path}/${stem}_${hash.substring(0, 8)}.epub');
      await f2.writeAsBytes(bytes, flush: true);
      return f2;
    }
    return f;
  }
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

String _safeFileName(String name) {
  // Strip directory separators and anything weird. Keep the extension if
  // it's already .epub, otherwise append.
  var n = name.replaceAll(RegExp(r'[\\/]+'), '_').replaceAll(RegExp(r'[^A-Za-z0-9._\- ]'), '_');
  if (!n.toLowerCase().endsWith('.epub')) n = '$n.epub';
  if (n.length > 80) n = n.substring(n.length - 80);
  return n;
}

/// Public sourcing helpers — called from main.dart's Tools sheet entries
/// and from the .epub URL interceptor.

Future<File?> pickEpubFromDevice() async {
  final res = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['epub'],
    withData: true,
  );
  if (res == null || res.files.isEmpty) return null;
  final f = res.files.first;
  final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
  if (bytes == null) return null;
  return cacheEpubFromBytes(Uint8List.fromList(bytes), suggestedName: f.name);
}

Future<File?> downloadEpubFromUrl(String url, {void Function(double)? onProgress}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) throw FormatException('Bad URL: $url');
  final req = http.Request('GET', uri);
  final res = await http.Client().send(req);
  if (res.statusCode >= 400) {
    throw HttpException('HTTP ${res.statusCode}', uri: uri);
  }
  final total = res.contentLength ?? 0;
  final builder = BytesBuilder(copy: false);
  var got = 0;
  await for (final chunk in res.stream) {
    builder.add(chunk);
    got += chunk.length;
    if (total > 0) onProgress?.call(got / total);
  }
  final bytes = builder.toBytes();
  // Suggested name from last path segment.
  final segs = uri.pathSegments;
  final name = segs.isNotEmpty ? Uri.decodeComponent(segs.last) : 'remote.epub';
  return cacheEpubFromBytes(bytes, suggestedName: name);
}

// ─── Public entry point: opens the reader screen ─────────────────────────

/// Open the EPUB reader. The caller supplies an `onLookup` callback that
/// receives a tapped/selected word plus a short surrounding context — the
/// host wires this into its existing dictionary-lookup flow (typically
/// opening dialog1).
Future<void> openEpubReader(
  BuildContext context, {
  required File file,
  required EpubLibrary library,
  required void Function(String word, String context) onLookup,
}) async {
  // Parse the EPUB on a microtask so the caller isn't blocked while the
  // library entry is recorded and the screen is pushed.
  EpubBook book;
  try {
    book = await EpubBook.openFile(file);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open EPUB: $e')));
    return;
  }
  final coverPath = await book.saveCover();
  await library.touch(EpubLibraryEntry(
    key: book.key,
    path: book.filePath,
    title: book.title,
    author: book.author,
    coverPath: coverPath,
  ));
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => EpubReaderScreen(book: book, onLookup: onLookup),
    fullscreenDialog: true,
  ));
}

// ─── The reader screen ───────────────────────────────────────────────────

class EpubReaderScreen extends StatefulWidget {
  const EpubReaderScreen({super.key, required this.book, required this.onLookup});

  final EpubBook book;
  final void Function(String word, String context) onLookup;

  @override
  State<EpubReaderScreen> createState() => _EpubReaderScreenState();
}

class _EpubReaderScreenState extends State<EpubReaderScreen> {
  late EpubReadingState _state;
  WebViewController? _controller;
  bool _ready = false;
  bool _chromeVisible = true;
  Timer? _saveDebounce;
  int _findCount = 0;
  bool _findBarVisible = false;
  final _findController = TextEditingController();

  // Cross-chapter full-text search results. The user types in the search
  // bar, we scan all chapters (regex-free, lower-cased substring), and
  // display "chapter title — snippet" rows; tapping one jumps to the hit.
  bool _bookSearchVisible = false;
  String _bookSearchQuery = '';
  List<_BookSearchHit> _bookSearchHits = const [];

  // ─── Text-to-speech ─────────────────────────────────────────────────
  // We use a dedicated FlutterTts instance for the reader. Sentences are
  // wrapped in <span data-sent="N"> by JS at chapter render — we then
  // (a) ask JS for the text of sentence N, (b) speak it, (c) on
  // completion advance N by 1 and repeat, (d) at end-of-chapter, flip
  // to the next chapter and continue if `_ttsActive` is still true.
  FlutterTts? _tts;
  bool _ttsActive = false;
  int _ttsIdx = 0;
  int _ttsCount = 0;

  // ─── Selection menu / highlights ────────────────────────────────────
  // Anchor for the floating selection menu — set by the JS selection
  // listener when the user finishes a drag-select; cleared on dismiss.
  Offset? _selectionAnchor;
  String _selectionText = '';
  String _selectionPrefix = '';
  String _selectionSuffix = '';

  EpubBook get book => widget.book;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _state = await EpubReadingState.load(book.key);
    if (_state.chapterIdx >= book.chapters.length) _state.chapterIdx = 0;
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_themeBg(_state.theme))
      ..addJavaScriptChannel('CupEpub', onMessageReceived: _onJsMessage);
    if (Platform.isAndroid) {
      final p = ctrl.platform;
      if (p is AndroidWebViewController) {
        p.setMediaPlaybackRequiresUserGesture(false);
      }
    }
    _controller = ctrl;
    setState(() => _ready = true);
    await _loadChapter(_state.chapterIdx, restoreScroll: true);
  }

  // ─── Chapter loading ───────────────────────────────────────────────────

  Future<void> _loadChapter(int idx, {bool restoreScroll = false}) async {
    if (idx < 0 || idx >= book.chapters.length) return;
    final ch = book.chapters[idx];
    final html = _wrapChapter(ch);
    _state.chapterIdx = idx;
    await _controller?.loadHtmlString(html, baseUrl: 'cupitor-epub://chapter/$idx');
    // Wait for the page to lay out, then scroll to remembered position.
    if (restoreScroll && _state.scrollPct > 0) {
      Future<void>.delayed(const Duration(milliseconds: 350), () async {
        await _controller?.runJavaScript(
          'window.__cupEpubRestoreScroll && window.__cupEpubRestoreScroll(${_state.scrollPct});',
        );
      });
    }
    _scheduleSave();
    if (mounted) setState(() {});
  }

  // Restart chapter rendering when theme/font/etc changed. Restores the
  // current scroll position instead of dropping to the top.
  Future<void> _rerenderForSettings() async {
    final ch = book.chapters[_state.chapterIdx];
    final html = _wrapChapter(ch);
    // Capture current scroll first so we can restore it after reload.
    try {
      final js = 'JSON.stringify({h: document.documentElement.scrollHeight, y: window.scrollY})';
      final v = await _controller?.runJavaScriptReturningResult(js);
      if (v is String) {
        final m = jsonDecode(v) as Map<String, dynamic>;
        final h = (m['h'] as num).toDouble();
        final y = (m['y'] as num).toDouble();
        if (h > 0) _state.scrollPct = (y / h).clamp(0.0, 1.0);
      }
    } catch (_) {}
    await _controller?.loadHtmlString(html, baseUrl: 'cupitor-epub://chapter/${_state.chapterIdx}');
    Future<void>.delayed(const Duration(milliseconds: 250), () async {
      await _controller?.runJavaScript(
        'window.__cupEpubRestoreScroll && window.__cupEpubRestoreScroll(${_state.scrollPct});',
      );
    });
  }

  // ─── Reading-state persistence ─────────────────────────────────────────

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      _state.save(book.key);
    });
  }

  // ─── JS channel: word taps, selections, scroll-progress ────────────────

  void _onJsMessage(JavaScriptMessage msg) {
    try {
      final env = jsonDecode(msg.message);
      if (env is! Map) return;
      final type = env['type'];
      switch (type) {
        case 'tap':
          final word = (env['word'] as String?)?.trim() ?? '';
          final ctx = (env['context'] as String?) ?? '';
          if (word.isNotEmpty) widget.onLookup(word, ctx);
          break;
        case 'select':
          final text = (env['text'] as String?)?.trim() ?? '';
          final prefix = (env['prefix'] as String?) ?? '';
          final suffix = (env['suffix'] as String?) ?? '';
          final x = (env['x'] as num?)?.toDouble() ?? 0.0;
          final y = (env['y'] as num?)?.toDouble() ?? 0.0;
          if (text.isEmpty) break;
          if (mounted) {
            setState(() {
              _selectionText = text;
              _selectionPrefix = prefix;
              _selectionSuffix = suffix;
              _selectionAnchor = Offset(x, y);
            });
          }
          break;
        case 'scroll':
          // Throttled in JS — we still debounce the prefs write.
          final pct = (env['pct'] as num?)?.toDouble() ?? 0.0;
          _state.scrollPct = pct.clamp(0.0, 1.0);
          _scheduleSave();
          break;
        case 'navStart':
          if (_state.chapterIdx > 0) {
            _state.scrollPct = 1.0;
            _loadChapter(_state.chapterIdx - 1, restoreScroll: true);
          }
          break;
        case 'navEnd':
          if (_state.chapterIdx < book.chapters.length - 1) {
            _state.scrollPct = 0.0;
            _loadChapter(_state.chapterIdx + 1);
          }
          break;
        case 'tapEdge':
          final edge = env['edge'];
          if (edge == 'left') {
            _goPrev();
          } else if (edge == 'right') {
            _goNext();
          } else {
            setState(() => _chromeVisible = !_chromeVisible);
          }
          break;
        case 'findCount':
          if (mounted) setState(() => _findCount = (env['count'] as num?)?.toInt() ?? 0);
          break;
        case 'chapterReady':
          _ttsCount = (env['sentenceCount'] as num?)?.toInt() ?? 0;
          _applySavedHighlightsForCurrentChapter();
          if (_state.paginated) {
            _controller?.runJavaScript('window.__cupEpubSetPaginated && window.__cupEpubSetPaginated(true);');
          }
          break;
        case 'highlightTap':
          final id = (env['id'] as String?) ?? '';
          if (id.isNotEmpty) _showHighlightActions(id);
          break;
        case 'anchor':
          break;
      }
    } catch (_) {}
  }

  // ─── Highlight management ──────────────────────────────────────────────

  void _applySavedHighlightsForCurrentChapter() {
    final list = _state.highlights
        .where((h) => h.chapterIdx == _state.chapterIdx)
        .map((h) => {
              'id': h.id,
              'color': h.color,
              'text': h.text,
              'prefix': h.prefix,
              'suffix': h.suffix,
              if (h.note != null) 'note': h.note,
            })
        .toList();
    if (list.isEmpty) return;
    final payload = jsonEncode(jsonEncode(list));  // double-encode → JSON string literal
    _controller?.runJavaScript('window.__cupEpubApplyHighlights && window.__cupEpubApplyHighlights($payload);');
  }

  void _addHighlightFromSelection({String color = 'yellow', String? note}) {
    if (_selectionText.isEmpty) return;
    final hl = EpubHighlight(
      chapterIdx: _state.chapterIdx,
      text: _selectionText,
      prefix: _selectionPrefix,
      suffix: _selectionSuffix,
      color: color,
      note: note,
    );
    final list = List<EpubHighlight>.from(_state.highlights)..add(hl);
    _state.highlights = list;
    _scheduleSave();
    _applySavedHighlightsForCurrentChapter();
    _clearSelection();
  }

  void _removeHighlight(String id) {
    final list = _state.highlights.where((h) => h.id != id).toList();
    _state.highlights = list;
    _scheduleSave();
    // Reload chapter so the wrap is removed cleanly (no DOM surgery here).
    _loadChapter(_state.chapterIdx, restoreScroll: true);
  }

  void _showHighlightActions(String id) {
    final hl = _state.highlights.firstWhere(
      (h) => h.id == id,
      orElse: () => EpubHighlight(chapterIdx: -1, text: '', prefix: '', suffix: ''),
    );
    if (hl.chapterIdx < 0) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('"${hl.text}"',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontStyle: FontStyle.italic)),
            ),
            if (hl.note != null && hl.note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(hl.note!, style: const TextStyle(color: Colors.grey)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  for (final c in const ['yellow', 'green', 'pink', 'blue'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () {
                          hl.color = c;
                          _scheduleSave();
                          Navigator.of(ctx).pop();
                          _loadChapter(_state.chapterIdx, restoreScroll: true);
                        },
                        child: Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(
                            color: _highlightColor(c),
                            border: Border.all(color: hl.color == c ? Colors.black : Colors.transparent, width: 2),
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text(hl.note == null ? 'Add note' : 'Edit note'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final note = await _promptForNote(initial: hl.note ?? '');
                if (note == null) return;
                hl.note = note.isEmpty ? null : note;
                _scheduleSave();
                _loadChapter(_state.chapterIdx, restoreScroll: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Remove highlight'),
              onTap: () {
                Navigator.of(ctx).pop();
                _removeHighlight(id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptForNote({String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Note'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Color _highlightColor(String c) {
    switch (c) {
      case 'green': return const Color(0xFF78DC78);
      case 'pink':  return const Color(0xFFFF82B4);
      case 'blue':  return const Color(0xFF78AAFF);
      default:      return const Color(0xFFFFD700);
    }
  }

  void _clearSelection() {
    _selectionAnchor = null;
    _selectionText = '';
    _selectionPrefix = '';
    _selectionSuffix = '';
    if (mounted) setState(() {});
    _controller?.runJavaScript('window.getSelection && window.getSelection().removeAllRanges();');
  }

  // ─── TTS ───────────────────────────────────────────────────────────────

  Future<void> _initTts() async {
    if (_tts != null) return;
    final t = FlutterTts();
    try {
      await t.awaitSpeakCompletion(true);
    } catch (_) {}
    try { await t.setSpeechRate(_state.ttsRate); } catch (_) {}
    try { await t.setVolume(1.0); } catch (_) {}
    try { await t.setPitch(1.0); } catch (_) {}
    _tts = t;
  }

  Future<void> _startTts() async {
    await _initTts();
    if (_ttsCount == 0) return;
    _ttsActive = true;
    _ttsIdx = 0;
    if (mounted) setState(() {});
    await _speakNext();
  }

  Future<void> _speakNext() async {
    if (!_ttsActive) return;
    if (_ttsIdx >= _ttsCount) {
      // End-of-chapter → advance and continue if there are more chapters.
      if (_state.chapterIdx < book.chapters.length - 1) {
        await _loadChapter(_state.chapterIdx + 1);
        // chapterReady arrives async; wait a tick and resume.
        Future<void>.delayed(const Duration(milliseconds: 350), () {
          if (!_ttsActive) return;
          _ttsIdx = 0;
          _speakNext();
        });
      } else {
        _ttsActive = false;
        if (mounted) setState(() {});
      }
      return;
    }
    final escaped = _ttsIdx.toString();
    await _controller?.runJavaScript('window.__cupEpubSpeakHighlight && window.__cupEpubSpeakHighlight($escaped);');
    final raw = await _controller?.runJavaScriptReturningResult(
      'window.__cupEpubSentenceText && window.__cupEpubSentenceText($escaped)',
    );
    String text;
    if (raw is String) {
      // Android wraps the result in JSON quotes; iOS often doesn't.
      text = raw.startsWith('"') && raw.endsWith('"')
          ? jsonDecode(raw) as String
          : raw;
    } else {
      text = raw?.toString() ?? '';
    }
    final clean = text.trim();
    if (clean.isEmpty) {
      _ttsIdx++;
      _speakNext();
      return;
    }
    try {
      await _tts!.speak(clean);
    } catch (_) {}
    if (!_ttsActive) return;
    _ttsIdx++;
    _speakNext();
  }

  void _pauseTts() {
    _ttsActive = false;
    _tts?.stop();
    _controller?.runJavaScript('window.__cupEpubSpeakHighlight && window.__cupEpubSpeakHighlight(-1);');
    if (mounted) setState(() {});
  }

  Future<void> _setTtsRate(double r) async {
    _state.ttsRate = r.clamp(0.2, 1.0);
    _scheduleSave();
    try { await _tts?.setSpeechRate(_state.ttsRate); } catch (_) {}
  }

  // ─── Navigation ────────────────────────────────────────────────────────

  void _goNext() {
    if (_state.chapterIdx < book.chapters.length - 1) {
      _state.scrollPct = 0.0;
      _loadChapter(_state.chapterIdx + 1);
    }
  }

  void _goPrev() {
    if (_state.chapterIdx > 0) {
      _state.scrollPct = 0.0;
      _loadChapter(_state.chapterIdx - 1);
    }
  }

  Future<void> _jumpTo(int idx) async {
    _state.scrollPct = 0.0;
    await _loadChapter(idx);
  }

  // ─── Bookmarks ─────────────────────────────────────────────────────────

  void _toggleBookmark() {
    final i = _state.chapterIdx;
    final list = List<int>.from(_state.bookmarks);
    if (list.contains(i)) {
      list.remove(i);
    } else {
      list.add(i);
      list.sort();
    }
    _state.bookmarks = list;
    _scheduleSave();
    if (mounted) setState(() {});
  }

  bool _currentChapterBookmarked() => _state.bookmarks.contains(_state.chapterIdx);

  // ─── Find in chapter ───────────────────────────────────────────────────

  Future<void> _findInChapter(String q) async {
    final escaped = jsonEncode(q);
    await _controller?.runJavaScript('window.__cupEpubFind && window.__cupEpubFind($escaped);');
  }

  Future<void> _findStep(int dir) async {
    await _controller?.runJavaScript('window.__cupEpubFindStep && window.__cupEpubFindStep($dir);');
  }

  // ─── Cross-chapter search ──────────────────────────────────────────────

  void _runBookSearch(String q) {
    final query = q.trim().toLowerCase();
    _bookSearchQuery = q;
    if (query.isEmpty) {
      setState(() => _bookSearchHits = const []);
      return;
    }
    final hits = <_BookSearchHit>[];
    for (var i = 0; i < book.chapters.length; i++) {
      final c = book.chapters[i];
      // Strip tags for the haystack so "<em>foo</em>" still matches "foo".
      final plain = c.html.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ');
      final lower = plain.toLowerCase();
      var start = 0;
      while (true) {
        final at = lower.indexOf(query, start);
        if (at < 0) break;
        final snippetStart = (at - 40).clamp(0, plain.length).toInt();
        final snippetEnd = (at + query.length + 40).clamp(0, plain.length).toInt();
        hits.add(_BookSearchHit(
          chapterIdx: i,
          chapterTitle: c.title,
          snippet: plain.substring(snippetStart, snippetEnd),
        ));
        start = at + query.length;
        if (hits.length >= 200) break;
      }
      if (hits.length >= 200) break;
    }
    setState(() => _bookSearchHits = hits);
  }

  // ─── HTML/CSS wrapper for each chapter ─────────────────────────────────

  String _wrapChapter(EpubChapter ch) {
    final theme = _themeColors(_state.theme);
    final bookCss = book.cssText
        // EPUB CSS often hard-codes `body { margin: ... }` that fights our
        // padding. Drop body margins; we control padding ourselves.
        .replaceAll(RegExp(r'body\s*\{[^}]*\}'), '');
    final fontFamily = switch (_state.fontFamily) {
      'sans' => '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
      'monospace' => 'ui-monospace, Menlo, "Roboto Mono", monospace',
      _ => 'Georgia, "Iowan Old Style", "Palatino Linotype", serif',
    };
    final fontPx = (18 * _state.fontScale).clamp(11, 48).toStringAsFixed(1);
    final html = '''
<!DOCTYPE html>
<html><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no"/>
<style>
  :root { color-scheme: ${_state.theme == 'dark' ? 'dark' : 'light'}; }
  html, body {
    margin: 0; padding: 0;
    background: ${theme.bg};
    color: ${theme.fg};
    font-family: $fontFamily;
    font-size: ${fontPx}px;
    line-height: ${_state.lineHeight};
    -webkit-text-size-adjust: 100%;
  }
  body { padding: 18px 22px 96px 22px; }
  p { margin: 0 0 0.95em 0; text-align: justify; hyphens: auto; }
  h1, h2, h3, h4 { line-height: 1.25; color: ${theme.fg}; }
  a { color: ${theme.link}; }
  img, svg, video { max-width: 100% !important; height: auto !important; }
  blockquote { margin: 1em 0; padding-left: 12px; border-left: 3px solid ${theme.border}; color: ${theme.fgMuted}; }
  pre, code { font-family: ui-monospace, Menlo, monospace; background: ${theme.codeBg}; }
  pre { padding: 8px; overflow-x: auto; }
  /* Find-in-chapter highlight. */
  .cup-find-hit { background: rgba(255, 215, 0, .45); border-radius: 2px; }
  .cup-find-current { background: rgba(255, 140, 0, .8); color: #000; }
  /* Tap-flash so users see the word that was looked up. */
  .cup-flash { background: rgba(70, 130, 240, .35); border-radius: 2px; transition: background .6s; }
  /* User-saved highlights. Four palette colors; mid-opacity so theme
     foreground stays readable on dark backgrounds. */
  .cup-hl { border-radius: 2px; padding: 0 1px; cursor: pointer; }
  .cup-hl-yellow { background: rgba(255, 215, 0, .42); }
  .cup-hl-green  { background: rgba(120, 220, 120, .38); }
  .cup-hl-pink   { background: rgba(255, 130, 180, .42); }
  .cup-hl-blue   { background: rgba(120, 170, 255, .42); }
  .cup-hl.has-note { box-shadow: inset 0 -2px 0 currentColor; }
  /* Read-aloud sentence highlight (current speaking sentence). */
  .cup-sent-current { background: rgba(80, 160, 255, .35); border-radius: 2px; }
  /* Edge zones: invisible click targets at left/right edges that the
     reader treats as page-flip taps. Bottom 60% of the viewport only so
     the top isn't capture (you might be tapping a link). */
  .cup-edge { position: fixed; top: 30%; bottom: 0; width: 14%; z-index: 9999; }
  .cup-edge-left { left: 0; }
  .cup-edge-right { right: 0; }
  /* Paginated mode: turn the body into a horizontally-scrolling column
     stream. Each column is one "page"; scroll-snap makes swipes feel
     natural. We override y-overflow so internal scrolling within the
     chapter is taken over by the page system instead. */
  body.cup-paginated {
    column-width: 100vw;
    column-gap: 0;
    column-fill: auto;
    height: 100vh;
    width: 100vw;
    overflow-x: scroll;
    overflow-y: hidden;
    padding: 18px 22px;
    box-sizing: border-box;
    scroll-snap-type: x mandatory;
    -webkit-overflow-scrolling: touch;
  }
  body.cup-paginated > * { break-inside: avoid; }
$bookCss
</style>
</head><body>
${ch.html}
<script>
(function() {
  var bridge = window.CupEpub;
  function post(o) { if (bridge) bridge.postMessage(JSON.stringify(o)); }

  // ── Scroll progress (throttled) ──
  var lastSent = 0;
  window.addEventListener('scroll', function() {
    var now = Date.now();
    if (now - lastSent < 400) return;
    lastSent = now;
    var h = document.documentElement.scrollHeight - window.innerHeight;
    var pct = h > 0 ? (window.scrollY / h) : 0;
    post({ type: 'scroll', pct: pct });
    // Bottom of the chapter → host can advance.
    if (h > 0 && (h - window.scrollY) < 4) post({ type: 'navEnd' });
  }, { passive: true });

  // ── Restore scroll on chapter load ──
  window.__cupEpubRestoreScroll = function(pct) {
    var h = document.documentElement.scrollHeight - window.innerHeight;
    if (h > 0) window.scrollTo(0, Math.max(0, Math.floor(h * pct)));
  };

  // ── Edge-tap page nav ──
  ['left', 'right'].forEach(function(side) {
    var el = document.createElement('div');
    el.className = 'cup-edge cup-edge-' + side;
    el.addEventListener('click', function(e) {
      // Only treat as edge nav if nothing was selected and the touch was
      // brief — selection drags shouldn't be hijacked.
      var sel = window.getSelection();
      if (sel && sel.toString().length > 0) return;
      e.preventDefault();
      e.stopPropagation();
      post({ type: 'tapEdge', edge: side });
    });
    document.body.appendChild(el);
  });

  // ── Word tap → lookup ──
  // We use caretRangeFromPoint to find the word the user actually tapped.
  // Tap-and-drag is treated as a selection (handled below). Plain text
  // inside <a>, <img>, <button> is left alone — the original anchor still
  // wins. The flash class gives visual feedback that the tap was caught.
  function isWordChar(c) { return /[\\p{L}\\p{M}\\p{N}'’-]/u.test(c); }
  function wordAt(node, off) {
    if (!node || node.nodeType !== 3) return null;
    var t = node.data || '';
    var s = off, e = off;
    while (s > 0 && isWordChar(t[s - 1])) s--;
    while (e < t.length && isWordChar(t[e])) e++;
    if (e === s) return null;
    return { word: t.substring(s, e), start: s, end: e, node: node };
  }

  // Line-wrap hyphenation: when the EPUB has "trans-\nlation" or "well- known"
  // (space-separated halves), tapping either half should look up the joined
  // word ("translation" / "wellknown"). Strategy: take the closest block
  // parent's flattened textContent (skips display:none, soft hyphens), find
  // the tapped word in it, and look across whitespace for a "-" connector.
  // The connecting dash is dropped on the assumption it's a typographic
  // line-break — real compound words like "self-aware" come through wordAt
  // as a single token already (no whitespace between halves).
  function joinHyphenatedWord(w) {
    var p = w.node.parentNode;
    while (p && p.tagName
           && !/^(P|LI|BLOCKQUOTE|DIV|H[1-6]|SECTION|ARTICLE|TD|TH|MAIN|ASIDE|HEADER|FOOTER|BODY)\$/i.test(p.tagName)) {
      p = p.parentNode;
    }
    if (!p) return w.word;
    // Strip soft hyphens (U+00AD) — they're invisible glyphs whose only
    // job is to suggest line-break points, and shouldn't end up in a lookup.
    var paraText = (p.textContent || '').replace(/\\u00AD/g, '');
    var word = w.word;
    var idx = paraText.indexOf(word);
    if (idx < 0) return word;
    var endIdx = idx + word.length;
    var WORD_RE = /[\\p{L}\\p{M}\\p{N}'’-]/u;
    // Recognise every common dash codepoint as a line-break-hyphenation
    // marker: U+002D, U+2010, U+2011, U+2012, U+2013, U+2014, U+2212.
    // The "no whitespace before the dash" guard in Case B keeps em/en
    // dashes used as parenthetical separators ("foo — bar") from being
    // collapsed into "foobar".
    function isDash(c) {
      return c === '-' || c === '\\u2010' || c === '\\u2011' || c === '\\u2012'
          || c === '\\u2013' || c === '\\u2014' || c === '\\u2212';
    }
    // Case A: tapped word itself ends with a dash → swallow the next token.
    if (word.length > 0 && isDash(word[word.length - 1])) {
      var i = endIdx;
      while (i < paraText.length && /\\s/.test(paraText[i])) i++;
      var startNext = i;
      while (i < paraText.length && WORD_RE.test(paraText[i])) i++;
      if (i > startNext) return word.slice(0, -1) + paraText.substring(startNext, i);
      return word.slice(0, -1);
    }
    // Case B: a dash sits IMMEDIATELY after our word (no whitespace before
    // the dash), then optional whitespace, then a continuation word.
    if (endIdx < paraText.length && isDash(paraText[endIdx])) {
      var bj = endIdx + 1;
      while (bj < paraText.length && /\\s/.test(paraText[bj])) bj++;
      var bStart = bj;
      while (bj < paraText.length && WORD_RE.test(paraText[bj])) bj++;
      if (bj > bStart) return word + paraText.substring(bStart, bj);
    }
    // Case C: previous token ended with a dash → we are the continuation.
    var j = idx;
    while (j > 0 && /\\s/.test(paraText[j - 1])) j--;
    if (j > 0 && isDash(paraText[j - 1])) {
      var endPrev = j - 1;
      var startPrev = endPrev;
      while (startPrev > 0 && WORD_RE.test(paraText[startPrev - 1])) startPrev--;
      if (endPrev > startPrev) {
        return paraText.substring(startPrev, endPrev) + word;
      }
    }
    return word;
  }

  var lastTouchX = 0, lastTouchY = 0;
  document.addEventListener('touchstart', function(ev) {
    if (ev.touches && ev.touches[0]) {
      lastTouchX = ev.touches[0].clientX;
      lastTouchY = ev.touches[0].clientY;
    }
  }, { passive: true });
  document.addEventListener('click', function(ev) {
    // Ignore taps that hit links/buttons/images.
    var tgt = ev.target;
    if (tgt && tgt.closest && tgt.closest('a, button, img, input, textarea, select, .cup-edge')) return;
    // Ignore if the user selected text — that goes through the selection
    // hook instead.
    var sel = window.getSelection();
    if (sel && sel.toString().trim().length > 0) return;
    var x = ev.clientX || lastTouchX;
    var y = ev.clientY || lastTouchY;
    var range;
    if (document.caretRangeFromPoint) {
      range = document.caretRangeFromPoint(x, y);
    } else if (document.caretPositionFromPoint) {
      var p = document.caretPositionFromPoint(x, y);
      if (p) { range = document.createRange(); range.setStart(p.offsetNode, p.offset); range.collapse(true); }
    }
    if (!range) return;
    var w = wordAt(range.startContainer, range.startOffset);
    if (!w) return;
    // Compute a context excerpt: ~100 chars on each side, joined from the
    // node and its siblings up to a sentence break.
    var ctx = '';
    try {
      var p = range.startContainer.parentNode;
      while (p && p.tagName && !/^(P|LI|BLOCKQUOTE|DIV|H[1-6])\$/i.test(p.tagName)) p = p.parentNode;
      if (p && p.innerText) ctx = p.innerText.replace(/\\s+/g, ' ').trim();
    } catch (e) {}
    // Flash the word so the user can see what was captured.
    try {
      var r = document.createRange();
      r.setStart(w.node, w.start);
      r.setEnd(w.node, w.end);
      var s = document.createElement('span');
      s.className = 'cup-flash';
      r.surroundContents(s);
      setTimeout(function() {
        var parent = s.parentNode;
        if (parent) {
          while (s.firstChild) parent.insertBefore(s.firstChild, s);
          parent.removeChild(s);
          parent.normalize && parent.normalize();
        }
      }, 700);
    } catch (e) {}
    // Resolve line-wrap hyphenation BEFORE posting: if the tapped half
    // ends with '-' or the previous half does, the lookup uses the
    // joined word ("translation"), not the tapped half ("trans-").
    var lookupWord = joinHyphenatedWord(w);
    post({ type: 'tap', word: lookupWord, context: ctx });
  }, true);

  // ── Selection → host-side menu ──
  // The user dragging a selection no longer auto-fires a lookup. Instead
  // we report the selection (with ~32 chars of prefix/suffix so the host
  // can persist a robust highlight if asked) and let Dart pop a menu
  // (Translate / Highlight / Note / Copy). 'selectionchange' fires often
  // during drag — debounce so we only act on the final selection.
  function fullText() {
    // The plain text of the chapter body. Cached on the function for the
    // life of the page since the DOM doesn't mutate after sentence wrap.
    if (fullText._cache != null) return fullText._cache;
    fullText._cache = document.body.innerText.replace(/\\s+/g, ' ');
    return fullText._cache;
  }
  var lastSel = '';
  var selTimer = null;
  document.addEventListener('selectionchange', function() {
    clearTimeout(selTimer);
    selTimer = setTimeout(function() {
      var sel = window.getSelection();
      var t = sel ? sel.toString().trim() : '';
      if (!t || t === lastSel) return;
      lastSel = t;
      // Compute prefix/suffix from the chapter's plain text so highlight
      // restoration can locate this exact occurrence later, even if the
      // same phrase appears multiple times.
      var ft = fullText();
      var idx = ft.indexOf(t.replace(/\\s+/g, ' '));
      var prefix = '', suffix = '';
      if (idx >= 0) {
        prefix = ft.substring(Math.max(0, idx - 32), idx);
        suffix = ft.substring(idx + t.length, Math.min(ft.length, idx + t.length + 32));
      }
      // Anchor coords for the menu — use the first rect of the range.
      var x = 0, y = 0;
      try {
        var range = sel.getRangeAt(0);
        var rect = range.getBoundingClientRect();
        x = rect.left + rect.width / 2;
        y = rect.top;
      } catch (e) {}
      post({ type: 'select', text: t, prefix: prefix, suffix: suffix, x: x, y: y });
    }, 350);
  });

  // ── Sentence wrapping (for TTS) ──
  // Wraps each sentence in <span class="cup-sent" data-sent="N">. The
  // sentences are then addressable by index so Dart can ask for one's
  // text, speak it via flutter_tts, and scroll/highlight as it goes.
  // Skipping <script>/<style>/<pre>/<code> nodes — those aren't prose.
  // Already-wrapped spans (find-hits, flashes, highlights) are walked
  // through; their text contributes to the sentence's content.
  var sentenceCount = 0;
  function splitIntoSentences(text) {
    // Split on . ! ? (and CJK equivalents) followed by whitespace. We
    // keep trailing punctuation+whitespace attached to the sentence so
    // TTS pauses naturally.
    var out = [];
    var i = 0, n = text.length;
    while (i < n) {
      var j = i;
      while (j < n && !/[.!?。！？]/.test(text[j])) j++;
      while (j < n && /[.!?。！？]/.test(text[j])) j++;
      while (j < n && /\\s/.test(text[j])) j++;
      out.push(text.substring(i, j));
      i = j;
    }
    return out;
  }
  function wrapSentences() {
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        if (!p) return NodeFilter.FILTER_REJECT;
        var name = p.nodeName || '';
        if (/^(SCRIPT|STYLE|PRE|CODE|TEXTAREA)\$/i.test(name)) return NodeFilter.FILTER_REJECT;
        if (!n.data || !n.data.trim()) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var nodes = [];
    var n;
    while ((n = walker.nextNode())) nodes.push(n);
    nodes.forEach(function(textNode) {
      var pieces = splitIntoSentences(textNode.data);
      if (pieces.length === 0) return;
      var frag = document.createDocumentFragment();
      pieces.forEach(function(s) {
        if (!s) return;
        if (!s.trim()) { frag.appendChild(document.createTextNode(s)); return; }
        var span = document.createElement('span');
        span.className = 'cup-sent';
        span.setAttribute('data-sent', String(sentenceCount++));
        span.textContent = s;
        frag.appendChild(span);
      });
      if (textNode.parentNode) textNode.parentNode.replaceChild(frag, textNode);
    });
  }
  wrapSentences();

  window.__cupEpubSentenceCount = function() { return sentenceCount; };
  window.__cupEpubSentenceText = function(i) {
    var el = document.querySelector('.cup-sent[data-sent="' + i + '"]');
    return el ? (el.textContent || '') : '';
  };
  window.__cupEpubSpeakHighlight = function(i) {
    var prev = document.querySelector('.cup-sent.cup-sent-current');
    if (prev) prev.classList.remove('cup-sent-current');
    if (i < 0) return;
    var el = document.querySelector('.cup-sent[data-sent="' + i + '"]');
    if (el) {
      el.classList.add('cup-sent-current');
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  };

  // ── Saved highlights: locate + wrap each ──
  // The host hands us a list of {id, color, note, prefix, text, suffix}.
  // We find the first occurrence whose prefix and suffix match in the
  // chapter's plain text, then wrap the corresponding DOM range in a
  // <span class="cup-hl cup-hl-COLOR" data-hl-id="ID">.
  function plainTextWithRanges() {
    // Walk all text nodes (post-sentence-wrap), build a single string,
    // and return {text, nodes: [{node, start, end}]} so a string offset
    // can be mapped back to (node, offset-in-node).
    var nodes = [];
    var pieces = [];
    var idx = 0;
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        if (!p) return NodeFilter.FILTER_REJECT;
        if (/^(SCRIPT|STYLE)\$/i.test(p.nodeName)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var n;
    while ((n = walker.nextNode())) {
      var t = n.data || '';
      nodes.push({ node: n, start: idx, end: idx + t.length });
      pieces.push(t);
      idx += t.length;
    }
    return { text: pieces.join(''), nodes: nodes };
  }
  function nodeAt(map, offset) {
    for (var i = 0; i < map.nodes.length; i++) {
      var e = map.nodes[i];
      if (offset >= e.start && offset <= e.end) {
        return { node: e.node, offset: offset - e.start };
      }
    }
    return null;
  }
  function applyOneHighlight(map, hl) {
    // Find the offset whose prefix+text+suffix matches.
    var t = map.text;
    var combined = hl.prefix + hl.text + hl.suffix;
    var at = t.indexOf(combined);
    if (at < 0) {
      // Try without suffix (it may have been at the chapter boundary).
      at = t.indexOf(hl.prefix + hl.text);
      if (at < 0) return false;
    }
    var start = at + hl.prefix.length;
    var end = start + hl.text.length;
    var s = nodeAt(map, start);
    var e = nodeAt(map, end);
    if (!s || !e) return false;
    var range = document.createRange();
    try {
      range.setStart(s.node, s.offset);
      range.setEnd(e.node, e.offset);
    } catch (err) { return false; }
    var span = document.createElement('span');
    span.className = 'cup-hl cup-hl-' + (hl.color || 'yellow');
    if (hl.note) span.classList.add('has-note');
    span.setAttribute('data-hl-id', hl.id);
    try { range.surroundContents(span); }
    catch (err) {
      // surroundContents fails if the range crosses element boundaries.
      // Fall back to extract + insert; preserves nesting but breaks at
      // boundaries — close enough for a visual highlight.
      try {
        var contents = range.extractContents();
        span.appendChild(contents);
        range.insertNode(span);
      } catch (err2) { return false; }
    }
    return true;
  }
  window.__cupEpubApplyHighlights = function(jsonText) {
    var list;
    try { list = JSON.parse(jsonText); } catch (e) { return; }
    if (!Array.isArray(list) || list.length === 0) return;
    var map = plainTextWithRanges();
    for (var i = 0; i < list.length; i++) applyOneHighlight(map, list[i]);
    // Tapping a highlight tells the host (so it can show edit/delete).
    document.querySelectorAll('.cup-hl').forEach(function(el) {
      el.addEventListener('click', function(ev) {
        ev.preventDefault(); ev.stopPropagation();
        post({ type: 'highlightTap', id: el.getAttribute('data-hl-id') });
      });
    });
  };

  // ── Paginated mode toggle ──
  // Wraps a class on <body> so the @media-free CSS rules above kick in.
  // We can't change `column-width` without a layout flush, so toggling
  // the class IS the layout flush.
  window.__cupEpubSetPaginated = function(on) {
    if (on) document.body.classList.add('cup-paginated');
    else document.body.classList.remove('cup-paginated');
  };

  // Signal to host that the chapter is ready (sentences wrapped, all
  // CSS applied, layout settled).
  post({ type: 'chapterReady', sentenceCount: sentenceCount });

  // ── Find in chapter ──
  // Walks the DOM, wraps each match in <span class="cup-find-hit"> and
  // tracks the "current" one for ↑/↓ step. Hits don't survive a chapter
  // reload — that's fine, the find bar runs again on chapter change.
  var findHits = [];
  var findIdx = -1;
  function clearFind() {
    findHits.forEach(function(s) {
      var p = s.parentNode;
      if (!p) return;
      while (s.firstChild) p.insertBefore(s.firstChild, s);
      p.removeChild(s);
      p.normalize && p.normalize();
    });
    findHits = []; findIdx = -1;
  }
  window.__cupEpubFind = function(q) {
    clearFind();
    if (!q) { post({ type: 'findCount', count: 0 }); return; }
    var query = q.toLowerCase();
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    var nodes = [];
    var n;
    while ((n = walker.nextNode())) {
      if (!n.parentNode) continue;
      if (/^(SCRIPT|STYLE)\$/i.test(n.parentNode.nodeName)) continue;
      nodes.push(n);
    }
    nodes.forEach(function(textNode) {
      var data = textNode.data;
      var lower = data.toLowerCase();
      var pieces = [];
      var i = 0;
      while (i < data.length) {
        var at = lower.indexOf(query, i);
        if (at < 0) { pieces.push({ kind: 'text', s: data.substring(i) }); break; }
        if (at > i) pieces.push({ kind: 'text', s: data.substring(i, at) });
        pieces.push({ kind: 'hit', s: data.substring(at, at + query.length) });
        i = at + query.length;
      }
      if (pieces.length <= 1 && pieces[0] && pieces[0].kind === 'text') return;
      var frag = document.createDocumentFragment();
      pieces.forEach(function(p) {
        if (p.kind === 'text') {
          frag.appendChild(document.createTextNode(p.s));
        } else {
          var span = document.createElement('span');
          span.className = 'cup-find-hit';
          span.textContent = p.s;
          findHits.push(span);
          frag.appendChild(span);
        }
      });
      textNode.parentNode.replaceChild(frag, textNode);
    });
    post({ type: 'findCount', count: findHits.length });
    if (findHits.length > 0) {
      findIdx = 0;
      findHits[0].classList.add('cup-find-current');
      findHits[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  };
  window.__cupEpubFindStep = function(dir) {
    if (findHits.length === 0) return;
    findHits[findIdx].classList.remove('cup-find-current');
    findIdx = (findIdx + dir + findHits.length) % findHits.length;
    var el = findHits[findIdx];
    el.classList.add('cup-find-current');
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  };
})();
</script>
</body></html>
''';
    return html;
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final progress = book.chapters.isEmpty
        ? 0.0
        : ((_state.chapterIdx + _state.scrollPct) / book.chapters.length).clamp(0.0, 1.0);
    final theme = _themeColors(_state.theme);
    return Scaffold(
      backgroundColor: _themeBg(_state.theme),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: WebViewWidget(controller: _controller!)),
            if (_chromeVisible) ...[
              Positioned(top: 0, left: 0, right: 0, child: _buildTopBar(theme)),
              if (_findBarVisible)
                Positioned(top: 56, left: 0, right: 0, child: _buildFindBar(theme)),
              Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar(theme, progress)),
            ],
            if (_bookSearchVisible) Positioned.fill(child: _buildBookSearchOverlay(theme)),
            if (_selectionAnchor != null) _buildSelectionMenu(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(_ThemeColors theme) {
    return Material(
      color: theme.chromeBg.withValues(alpha: 0.96),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              color: theme.chromeFg,
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: 'Close book',
            ),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _chromeVisible = !_chromeVisible),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: theme.chromeFg, fontSize: 15, fontWeight: FontWeight.w600)),
                      if (book.author != null && book.author!.isNotEmpty)
                        Text(book.author!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: theme.chromeFg.withValues(alpha: 0.7), fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              icon: Icon(_currentChapterBookmarked() ? Icons.bookmark : Icons.bookmark_border),
              color: theme.chromeFg,
              tooltip: 'Bookmark',
              onPressed: _toggleBookmark,
            ),
            IconButton(
              icon: const Icon(Icons.search),
              color: theme.chromeFg,
              tooltip: 'Search in book',
              onPressed: () {
                setState(() => _bookSearchVisible = true);
              },
            ),
            IconButton(
              icon: const Icon(Icons.find_in_page),
              color: theme.chromeFg,
              tooltip: 'Find in chapter',
              onPressed: () {
                setState(() => _findBarVisible = !_findBarVisible);
                if (!_findBarVisible) {
                  _findController.clear();
                  _findInChapter('');
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.format_size),
              color: theme.chromeFg,
              tooltip: 'Text & theme',
              onPressed: _showSettingsSheet,
            ),
            IconButton(
              icon: const Icon(Icons.list_alt),
              color: theme.chromeFg,
              tooltip: 'Table of contents',
              onPressed: _showTocSheet,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFindBar(_ThemeColors theme) {
    return Material(
      color: theme.chromeBg.withValues(alpha: 0.98),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _findController,
                style: TextStyle(color: theme.chromeFg),
                decoration: InputDecoration(
                  hintText: 'Find in chapter',
                  hintStyle: TextStyle(color: theme.chromeFg.withValues(alpha: 0.6)),
                  isDense: true,
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.search, color: theme.chromeFg.withValues(alpha: 0.7)),
                ),
                onChanged: _findInChapter,
              ),
            ),
            Text(_findCount == 0 ? '0' : '$_findCount',
                style: TextStyle(color: theme.chromeFg.withValues(alpha: 0.7))),
            IconButton(
              icon: Icon(Icons.keyboard_arrow_up, color: theme.chromeFg),
              tooltip: 'Previous match',
              onPressed: () => _findStep(-1),
            ),
            IconButton(
              icon: Icon(Icons.keyboard_arrow_down, color: theme.chromeFg),
              tooltip: 'Next match',
              onPressed: () => _findStep(1),
            ),
            IconButton(
              icon: Icon(Icons.close, color: theme.chromeFg),
              onPressed: () {
                _findController.clear();
                _findInChapter('');
                setState(() => _findBarVisible = false);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(_ThemeColors theme, double progress) {
    return Material(
      color: theme.chromeBg.withValues(alpha: 0.96),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  color: theme.chromeFg,
                  onPressed: _state.chapterIdx > 0 ? _goPrev : null,
                  tooltip: 'Previous chapter',
                ),
                // Read-aloud toggle. Spinning icon while active.
                IconButton(
                  icon: Icon(_ttsActive ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                  color: _ttsActive ? theme.accent : theme.chromeFg,
                  tooltip: _ttsActive ? 'Stop read-aloud' : 'Read aloud',
                  onPressed: () {
                    if (_ttsActive) {
                      _pauseTts();
                    } else {
                      _startTts();
                    }
                  },
                ),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: (book.chapters.length - 1).clamp(0, 9999).toDouble(),
                    value: _state.chapterIdx.toDouble().clamp(
                          0.0,
                          (book.chapters.length - 1).clamp(0, 9999).toDouble(),
                        ),
                    divisions: book.chapters.length > 1 ? book.chapters.length - 1 : null,
                    label: 'Ch ${_state.chapterIdx + 1}',
                    onChanged: (v) {
                      setState(() => _state.chapterIdx = v.round());
                    },
                    onChangeEnd: (v) => _jumpTo(v.round()),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  color: theme.chromeFg,
                  onPressed: _state.chapterIdx < book.chapters.length - 1 ? _goNext : null,
                  tooltip: 'Next chapter',
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                children: [
                  Text('Ch ${_state.chapterIdx + 1}/${book.chapters.length}',
                      style: TextStyle(color: theme.chromeFg.withValues(alpha: 0.75), fontSize: 11)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: theme.chromeFg.withValues(alpha: 0.12),
                      color: theme.accent,
                      minHeight: 3,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(progress * 100).round()}%',
                      style: TextStyle(color: theme.chromeFg.withValues(alpha: 0.75), fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTocSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Text('Table of Contents', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_state.bookmarks.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Bookmarks',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey[600])),
              ),
              ..._state.bookmarks.map((i) {
                final c = (i >= 0 && i < book.chapters.length) ? book.chapters[i] : null;
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.bookmark, size: 18),
                  title: Text(c?.title ?? 'Chapter ${i + 1}'),
                  onTap: () { Navigator.of(ctx).pop(); _jumpTo(i); },
                );
              }),
              const Divider(height: 1),
            ],
            Expanded(
              child: ListView(
                controller: scrollController,
                children: book.toc.isEmpty
                    ? _flatTocFromChapters()
                    : _renderTocEntries(book.toc, depth: 0, onTap: (i) {
                        Navigator.of(ctx).pop(); _jumpTo(i);
                      }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _flatTocFromChapters() {
    return [
      for (var i = 0; i < book.chapters.length; i++)
        ListTile(
          dense: true,
          title: Text(book.chapters[i].title),
          selected: i == _state.chapterIdx,
          onTap: () { Navigator.of(context).pop(); _jumpTo(i); },
        ),
    ];
  }

  List<Widget> _renderTocEntries(List<EpubTocEntry> entries, {required int depth, required void Function(int) onTap}) {
    final out = <Widget>[];
    for (final e in entries) {
      out.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: 16.0 + depth * 16.0, right: 16),
        title: Text(e.title.isEmpty ? '(untitled)' : e.title,
            style: TextStyle(fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.normal)),
        selected: e.chapterIdx == _state.chapterIdx,
        onTap: e.chapterIdx >= 0 ? () => onTap(e.chapterIdx) : null,
      ));
      if (e.children.isNotEmpty) {
        out.addAll(_renderTocEntries(e.children, depth: depth + 1, onTap: onTap));
      }
    }
    return out;
  }

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    children: [
                      Text('Text & Theme', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                const Divider(height: 16),
                ListTile(
                  leading: const Icon(Icons.format_size),
                  title: const Text('Text size'),
                  subtitle: Text('${(_state.fontScale * 100).round()}%'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.text_decrease),
                        onPressed: () {
                          _state.fontScale = (_state.fontScale - 0.1).clamp(0.7, 2.5);
                          setSheet(() {});
                          _rerenderForSettings();
                          _scheduleSave();
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.text_increase),
                        onPressed: () {
                          _state.fontScale = (_state.fontScale + 0.1).clamp(0.7, 2.5);
                          setSheet(() {});
                          _rerenderForSettings();
                          _scheduleSave();
                        },
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.font_download_outlined),
                  title: const Text('Font family'),
                  trailing: DropdownButton<String>(
                    value: _state.fontFamily,
                    items: const [
                      DropdownMenuItem(value: 'serif', child: Text('Serif')),
                      DropdownMenuItem(value: 'sans', child: Text('Sans')),
                      DropdownMenuItem(value: 'monospace', child: Text('Mono')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      _state.fontFamily = v;
                      setSheet(() {});
                      _rerenderForSettings();
                      _scheduleSave();
                    },
                    underline: const SizedBox(),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.format_line_spacing),
                  title: const Text('Line spacing'),
                  subtitle: Slider(
                    min: 1.2, max: 2.2, divisions: 10,
                    value: _state.lineHeight,
                    label: _state.lineHeight.toStringAsFixed(1),
                    onChanged: (v) {
                      _state.lineHeight = v;
                      setSheet(() {});
                    },
                    onChangeEnd: (_) {
                      _rerenderForSettings();
                      _scheduleSave();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      for (final t in const ['light', 'sepia', 'dark'])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(t[0].toUpperCase() + t.substring(1)),
                            selected: _state.theme == t,
                            onSelected: (_) {
                              _state.theme = t;
                              setSheet(() {});
                              if (mounted) setState(() {});
                              _controller?.setBackgroundColor(_themeBg(t));
                              _rerenderForSettings();
                              _scheduleSave();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 8),
                SwitchListTile(
                  secondary: const Icon(Icons.swap_horiz),
                  title: const Text('Paginated mode'),
                  subtitle: const Text('Horizontal swipe instead of scrolling'),
                  value: _state.paginated,
                  onChanged: (v) {
                    _state.paginated = v;
                    setSheet(() {});
                    if (mounted) setState(() {});
                    _controller?.runJavaScript(
                      'window.__cupEpubSetPaginated && window.__cupEpubSetPaginated(${v ? "true" : "false"});',
                    );
                    _scheduleSave();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('Read-aloud speed'),
                  subtitle: Slider(
                    min: 0.2, max: 1.0, divisions: 8,
                    value: _state.ttsRate.clamp(0.2, 1.0),
                    label: '${(_state.ttsRate * 100).round()}%',
                    onChanged: (v) {
                      _state.ttsRate = v;
                      setSheet(() {});
                    },
                    onChangeEnd: (v) => _setTtsRate(v),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.bookmarks),
                  title: const Text('Highlights & bookmarks'),
                  subtitle: Text(
                    '${_state.highlights.length} highlights, ${_state.bookmarks.length} bookmarks',
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showHighlightsList();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showHighlightsList() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) {
          final byChapter = <int, List<EpubHighlight>>{};
          for (final h in _state.highlights) {
            byChapter.putIfAbsent(h.chapterIdx, () => []).add(h);
          }
          final chapterIdxs = byChapter.keys.toList()..sort();
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text('Highlights',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Expanded(
                child: _state.highlights.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No highlights yet. Select text in a chapter to make one.'),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: chapterIdxs.fold<int>(
                            0,
                            (sum, idx) => sum + 1 + (byChapter[idx]!.length)),
                        itemBuilder: (_, i) {
                          var cursor = 0;
                          for (final cIdx in chapterIdxs) {
                            if (i == cursor) {
                              final title = (cIdx >= 0 && cIdx < book.chapters.length)
                                  ? book.chapters[cIdx].title
                                  : 'Chapter ${cIdx + 1}';
                              return Container(
                                color: Colors.black12,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                child: Text(title,
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                              );
                            }
                            cursor++;
                            final hs = byChapter[cIdx]!;
                            if (i < cursor + hs.length) {
                              final h = hs[i - cursor];
                              return ListTile(
                                leading: Container(
                                  width: 14, height: 14,
                                  decoration: BoxDecoration(
                                    color: _highlightColor(h.color),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                ),
                                title: Text(h.text,
                                    maxLines: 2, overflow: TextOverflow.ellipsis),
                                subtitle: h.note != null && h.note!.isNotEmpty
                                    ? Text(h.note!,
                                        maxLines: 1, overflow: TextOverflow.ellipsis)
                                    : null,
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _jumpTo(cIdx);
                                },
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _removeHighlight(h.id),
                                ),
                              );
                            }
                            cursor += hs.length;
                          }
                          return const SizedBox.shrink();
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  // Floating menu over a selected range. Positioned just above the
  // selection's bounding box (or below it if the selection is near the
  // top of the screen). Tapping outside dismisses it.
  Widget _buildSelectionMenu(_ThemeColors theme) {
    final anchor = _selectionAnchor!;
    // We've been given client coords (CSS pixels in the WebView). The
    // WebView is the full content area inside SafeArea, so anchor +/-
    // the menu height places it just above the selection.
    final size = MediaQuery.of(context).size;
    const menuW = 320.0;
    final left = (anchor.dx - menuW / 2).clamp(8.0, size.width - menuW - 8);
    final top = anchor.dy > 80 ? anchor.dy - 64 : anchor.dy + 32;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _clearSelection,
          ),
        ),
        Positioned(
          left: left,
          top: top.clamp(8.0, size.height - 60),
          width: menuW,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            color: theme.chromeBg,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _selMenuBtn(theme, Icons.translate, 'Lookup', () {
                    final word = _selectionText;
                    _clearSelection();
                    widget.onLookup(word, '');
                  }),
                  _selMenuBtn(theme, Icons.brush, 'Highlight', () {
                    _addHighlightFromSelection();
                  }),
                  _selMenuBtn(theme, Icons.sticky_note_2_outlined, 'Note', () async {
                    final note = await _promptForNote();
                    if (note == null) { _clearSelection(); return; }
                    _addHighlightFromSelection(note: note.isEmpty ? null : note);
                  }),
                  _selMenuBtn(theme, Icons.copy, 'Copy', () async {
                    final text = _selectionText;
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
                    );
                    _clearSelection();
                  }),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _selMenuBtn(_ThemeColors theme, IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: theme.chromeFg, size: 22),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: theme.chromeFg, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildBookSearchOverlay(_ThemeColors theme) {
    return GestureDetector(
      onTap: () => setState(() => _bookSearchVisible = false),
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        child: GestureDetector(
          onTap: () {},
          child: Align(
            alignment: Alignment.topCenter,
            child: Material(
              color: theme.bg,
              elevation: 6,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      child: Row(
                        children: [
                          Icon(Icons.search, color: theme.fg),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              autofocus: true,
                              decoration: const InputDecoration(
                                hintText: 'Search inside book',
                                border: InputBorder.none,
                              ),
                              onChanged: _runBookSearch,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => _bookSearchVisible = false),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: _bookSearchHits.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                _bookSearchQuery.isEmpty
                                    ? 'Type to search the full text of this book.'
                                    : 'No matches.',
                                style: TextStyle(color: theme.fgMuted),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _bookSearchHits.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final h = _bookSearchHits[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(h.chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text('…${h.snippet}…',
                                      maxLines: 2, overflow: TextOverflow.ellipsis),
                                  onTap: () {
                                    setState(() => _bookSearchVisible = false);
                                    _jumpTo(h.chapterIdx).then((_) {
                                      Future<void>.delayed(const Duration(milliseconds: 400), () {
                                        _findController.text = _bookSearchQuery;
                                        if (mounted) {
                                          setState(() => _findBarVisible = true);
                                          _findInChapter(_bookSearchQuery);
                                        }
                                      });
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _state.save(book.key);
    _findController.dispose();
    // Stop the TTS pipeline cleanly — otherwise speech can continue
    // playing after the user has navigated away from the reader.
    _ttsActive = false;
    try { _tts?.stop(); } catch (_) {}
    super.dispose();
  }
}

class _BookSearchHit {
  _BookSearchHit({required this.chapterIdx, required this.chapterTitle, required this.snippet});
  final int chapterIdx;
  final String chapterTitle;
  final String snippet;
}

// ─── Theme helpers ───────────────────────────────────────────────────────

class _ThemeColors {
  const _ThemeColors({
    required this.bg,
    required this.fg,
    required this.fgMuted,
    required this.link,
    required this.border,
    required this.codeBg,
    required this.chromeBg,
    required this.chromeFg,
    required this.accent,
  });

  final Color bg, fg, fgMuted, link, border, codeBg, chromeBg, chromeFg, accent;
}

_ThemeColors _themeColors(String name) {
  switch (name) {
    case 'sepia':
      return const _ThemeColors(
        bg: Color(0xFFFBF0D9),
        fg: Color(0xFF5B4636),
        fgMuted: Color(0xFF8A7359),
        link: Color(0xFF7B4A12),
        border: Color(0xFFD9C8A8),
        codeBg: Color(0xFFEFE2C6),
        chromeBg: Color(0xFFE7D8B5),
        chromeFg: Color(0xFF5B4636),
        accent: Color(0xFFA0671C),
      );
    case 'dark':
      return const _ThemeColors(
        bg: Color(0xFF121417),
        fg: Color(0xFFE6E6E6),
        fgMuted: Color(0xFFA0A0A0),
        link: Color(0xFF8AB4FF),
        border: Color(0xFF2A2E33),
        codeBg: Color(0xFF1B1E22),
        chromeBg: Color(0xFF1B1E22),
        chromeFg: Color(0xFFE6E6E6),
        accent: Color(0xFF8AB4FF),
      );
    default:
      return const _ThemeColors(
        bg: Color(0xFFFFFFFF),
        fg: Color(0xFF202124),
        fgMuted: Color(0xFF5F6368),
        link: Color(0xFF1A73E8),
        border: Color(0xFFE0E0E0),
        codeBg: Color(0xFFF4F4F4),
        chromeBg: Color(0xFFF7F7F8),
        chromeFg: Color(0xFF202124),
        accent: Color(0xFF1A73E8),
      );
  }
}

Color _themeBg(String name) => _themeColors(name).bg;

