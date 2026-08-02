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

import 'book_transfer.dart';
import 'db.dart';
import 'eink_mode.dart';
import 'jslog.dart';
import 'memory_manager.dart';
import 'notif/notification_manager.dart';
import 'playlist_screen.dart';
import 'playlist_service.dart';
import 'profile_service.dart';
import 'tag_browser.dart';
import 'tag_capture.dart';
import 'tag_filter.dart';
import 'media_store.dart';
import 'tag_settings.dart';
import 'text_transform.dart';

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
///
/// [initialHighlight] is the phrase to jump to after the initial chapter
/// finishes loading. When supplied the reader opens with the find bar
/// visible, the phrase pre-filled, and the first match scrolled into
/// view. Used by global-search "open hit" and similar deep-link flows.
Future<void> openEpubReader(
  BuildContext context, {
  required File file,
  required EpubLibrary library,
  required void Function(String word, String context) onLookup,
  String? initialHighlight,
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
    builder: (_) => EpubReaderScreen(
      book: book,
      onLookup: onLookup,
      initialHighlight: initialHighlight,
    ),
    fullscreenDialog: true,
  ));
}

// ─── The reader screen ───────────────────────────────────────────────────

class EpubReaderScreen extends StatefulWidget {
  const EpubReaderScreen({
    super.key,
    required this.book,
    required this.onLookup,
    this.initialHighlight,
  });

  final EpubBook book;
  final void Function(String word, String context) onLookup;

  /// Phrase to scroll to after the initial chapter loads. When
  /// non-null the reader opens with the find bar visible and the
  /// first match centred on screen. Consumed exactly once — subsequent
  /// chapter loads (navigation, prev/next) do NOT re-apply it.
  final String? initialHighlight;

  @override
  State<EpubReaderScreen> createState() => _EpubReaderScreenState();
}

class _EpubReaderScreenState extends State<EpubReaderScreen> {
  late EpubReadingState _state;
  WebViewController? _controller;
  bool _ready = false;
  bool _chromeVisible = true;
  Timer? _chromeHideTimer;
  static const Duration _chromeIdleHide = Duration(seconds: 5);
  Timer? _saveDebounce;
  int _findCount = 0;
  /// One-shot highlight passed in via [EpubReaderScreen.initialHighlight].
  /// Nulled the first time it's applied so re-loads don't re-fire it.
  String? _pendingHighlight;
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

  // ─── Sentence-tagging ───────────────────────────────────────────────
  // Mirrors the same feature on the main WebView (see lib/main.dart).
  // EPUB uses `.cup-sent[data-sent=N]` spans (already created by the
  // chapter wrapper script) as sentence units instead of clickable-word
  // spans, but the DB layer and bottom sheet are identical.
  bool _tagDbReady = false;
  bool _tagCaptureToggleVisible = false;
  bool _tagCaptureArmed = false;
  Offset _tagCaptureChipPos = const Offset(-1, -1);
  // Second capture mode — appends tapped sentences to the active
  // playlist (managed via PlaylistService) so a language app inside
  // dialog1 can render them as manual cards. Chip lives beside the
  // tag capture chip; enabling / arming is independent.
  bool _playlistChipVisible = false;
  bool _playlistCaptureArmed = false;
  Offset _playlistChipPos = const Offset(-1, -1);
  Set<int> _tagFilterTagIds = <int>{};
  bool _tagMasksVisible = false;
  bool _tagTransformsEnabled = true;
  bool _tagShowMaskImages = false;
  Completer<ExtendResult>? _pendingTagExtend;

  EpubBook get book => widget.book;

  @override
  void initState() {
    super.initState();
    _pendingHighlight = widget.initialHighlight?.trim();
    if (_pendingHighlight != null && _pendingHighlight!.isEmpty) {
      _pendingHighlight = null;
    }
    _bootstrap();
    // Hide the chrome shortly after the reader opens so the page starts
    // distraction-free; any scroll or center-tap brings it back.
    _scheduleChromeHide();
  }

  void _revealChromeAndScheduleHide() {
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
    _scheduleChromeHide();
  }

  void _toggleChromeVisibility() {
    if (_chromeVisible) {
      _chromeHideTimer?.cancel();
      setState(() => _chromeVisible = false);
    } else {
      _revealChromeAndScheduleHide();
    }
  }

  void _scheduleChromeHide() {
    _chromeHideTimer?.cancel();
    _chromeHideTimer = Timer(_chromeIdleHide, () {
      if (!mounted) return;
      // Keep the chrome up while the user is using the find or book-
      // search overlays — those are inside the chrome itself.
      if (_findBarVisible || _bookSearchVisible) {
        _scheduleChromeHide();
        return;
      }
      // Keep chrome up while any modal is on top of the reader (popup
      // menu, dialog, bottom sheet). Otherwise the PopupMenuButton (and
      // its siblings) would unmount mid-interaction — Flutter's menu
      // future guards `if (!mounted) return;` and would silently drop
      // the user's selection.
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
        _scheduleChromeHide();
        return;
      }
      if (_chromeVisible) setState(() => _chromeVisible = false);
    });
  }

  Future<void> _bootstrap() async {
    _state = await EpubReadingState.load(book.key);
    if (_state.chapterIdx >= book.chapters.length) _state.chapterIdx = 0;
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_themeBg(_state.theme))
      ..addJavaScriptChannel('CupEpub', onMessageReceived: _onJsMessage)
      // Sentence-tagging bridges — same protocol as the main WebView so
      // the Dart-side capture sheet and DB layer can be shared.
      ..addJavaScriptChannel('SentenceTagHandler',
          onMessageReceived: (msg) => _onSentenceTagMessage(msg.message))
      ..addJavaScriptChannel('SentenceFilterHandler',
          onMessageReceived: (_) {})
      ..addJavaScriptChannel('SnippetLogChannel', onMessageReceived: (msg) {
        final raw = msg.message;
        final pipe = raw.indexOf('|');
        if (pipe < 0) {
          JsLogSink.add('log', raw);
        } else {
          JsLogSink.add(raw.substring(0, pipe), raw.substring(pipe + 1));
        }
      });
    if (isSqlitePlatform) {
      CupitorDb.instance.isReady().then((ok) async {
        if (!mounted) return;
        final wasReady = _tagDbReady;
        setState(() => _tagDbReady = ok);
        if (ok) {
          await ProfileService.init();
          if (!mounted) return;
          await _loadProfileScopedPrefs();
          ProfileService.active.addListener(_onProfileChanged);
        }
        if (ok && !wasReady) _installTagHelpersAndRehydrate();
      });
    }
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
        case 'log':
          JsLogSink.add('log', (env['msg'] as String?) ?? '');
          break;
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
          // Bring chrome back so the user can reach the toolbar without
          // first having to tap the page; auto-hide kicks in again 5 s
          // after the scroll settles.
          _revealChromeAndScheduleHide();
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
        case 'swipeLeft':
          // Finger moved left → advance to next chapter (LTR reading).
          if (_state.chapterIdx < book.chapters.length - 1) {
            _state.scrollPct = 0.0;
            _loadChapter(_state.chapterIdx + 1);
          }
          break;
        case 'swipeRight':
          // Finger moved right → go back to previous chapter.
          if (_state.chapterIdx > 0) {
            _state.scrollPct = 1.0;
            _loadChapter(_state.chapterIdx - 1, restoreScroll: true);
          }
          break;
        case 'tapBackground':
          // Tap on empty space (no word resolved) — treat as a request
          // to toggle the chrome. Lets users reveal the toolbars on
          // chapters that don't scroll.
          _toggleChromeVisibility();
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
          _installTagHelpersAndRehydrate();
          // Apply the one-shot deep-link highlight (from global search's
          // "open hit" flow) right after the chapter is settled. Cleared
          // immediately so navigating away and back doesn't re-scroll.
          final hl = _pendingHighlight;
          if (hl != null && hl.isNotEmpty) {
            _pendingHighlight = null;
            _applyInitialHighlight(hl);
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

  // ─── Sentence tagging (JS injection + bridge + UI hooks) ───────────────

  String get _tagLocator => epubLocator(book.key, _state.chapterIdx);

  // Tag helpers script, injected on each `chapterReady`. Works against
  // the existing `.cup-sent[data-sent=N]` spans that the chapter wrapper
  // already creates for TTS; capture mode treats each as one sentence.
  // Prev/Next extend by ±1 in the chapter-local index. `fp()` matches
  // lib/db.dart#fp byte-for-byte (validated by the self-test in db.dart).
  static const String _epubTagHelpersJs = '''
(function(){
  if (window.__cupitorEpubTagInstalled) return;
  window.__cupitorEpubTagInstalled = true;
  window.__cupitorCaptureMode = false;
  var st = { from: -1, to: -1, sid: null };
  var rehydrated = [];
  var masksVisible = false;
  // null = no filter active. Otherwise an object map { tagId -> 1 }
  // used by both the fade pass and mask injection so a group whose
  // tags are filtered OUT stops painting masks over visible groups.
  var activeFilterSet = null;
  // dbid -> { tagIds:[], colors:[], from, to, mask, id }. The single
  // source of truth for which group covers which span. Span attributes
  // (data-cupitor-dbid CSV, tagids CSV, mask text) are derived from this.
  var tagSets = {};
  // Run-key ("dbid:from-to") -> { el, runFrom, runTo, dbid }. Each
  // injected .cupitor-mask spans a contiguous run of .cup-sent elements
  // where one group "owns" the mask (longest-wins on shared spans).
  var maskInjections = {};
  function ensureStyles() {
    if (document.getElementById('__cupitor_epub_tag_styles')) return;
    var s = document.createElement('style');
    s.id = '__cupitor_epub_tag_styles';
    s.textContent =
      '.cupitor-temp-highlight{background-color:rgba(255,235,59,0.35) !important;}' +
      '.cupitor-fade{opacity:0.25 !important;transition:opacity 0.15s;}' +
      '.cupitor-masked-out{display:none !important;}' +
      '.cupitor-mask{display:inline;padding:0 2px;border-radius:2px;' +
      'background:rgba(0,0,0,0.05);font-style:italic;cursor:pointer;}' +
      // Image mask: bounded so a large attachment doesn't push the
      // page around. `display:inline-block` so the mask element still
      // sits in the sentence flow; the img itself is a block child
      // that respects the max-width / max-height.
      '.cupitor-mask-image{max-width:100%;max-height:220px;display:block;' +
      'border-radius:2px;object-fit:contain;}' +
      // Transformed text: dotted underline so it reads as "differs from
      // source". Original text is preserved on data-cupitor-orig and
      // surfaced via the title attribute.
      '.cupitor-xform{border-bottom:1px dotted rgba(0,120,215,0.75);}' +
      // Small leading marker showing which media kinds are attached to a
      // tagged sentence. Rendered via a data attribute so we can update
      // it purely with setAttribute — no DOM insertion / removal on tag
      // stamp / unstamp. Emoji picked for zero-asset rendering.
      '.cup-sent[data-cupitor-media-marker]::before{' +
      'content:attr(data-cupitor-media-marker) " ";' +
      'font-size:0.85em;opacity:0.75;margin-right:2px;' +
      '-webkit-user-select:none;user-select:none;}' +
      'body.cupitor-filter-active{color:rgba(0,0,0,0.30) !important;}' +
      'body.cupitor-filter-active .cup-sent,' +
      'body.cupitor-filter-active .cupitor-mask{color:initial !important;}';
    (document.head || document.documentElement).appendChild(s);
  }
  // --- multi-stamp helpers ---
  function spanDbids(el) {
    var s = el.getAttribute('data-cupitor-dbid');
    if (!s) return [];
    return s.split(',').map(function(x){return parseInt(x,10);})
      .filter(function(n){return !isNaN(n);});
  }
  function setSpanDbids(el, ids) {
    if (!ids.length) el.removeAttribute('data-cupitor-dbid');
    else el.setAttribute('data-cupitor-dbid', ids.join(','));
  }
  function addDbidToSpan(el, id) {
    var ids = spanDbids(el);
    if (ids.indexOf(id) >= 0) return;
    ids.push(id);
    setSpanDbids(el, ids);
  }
  function removeDbidFromSpan(el, id) {
    var ids = spanDbids(el).filter(function(x){return x !== id;});
    setSpanDbids(el, ids);
  }
  // ---------- Text transformation rules ----------
  //
  // Dart pushes per-language rules into window.__cupitorTextTransforms
  // and then invokes __cupitorApplyTextTransforms(). Rules rewrite text
  // inside each .cup-sent; the original text is snapshotted on
  // data-cupitor-orig so tag identity (which fingerprints against
  // original text) stays intact regardless of how the reader displays it.
  function currentLangPrimary() {
    var raw = (document.documentElement && document.documentElement.lang) ||
              (navigator && navigator.language) || '';
    return String(raw).toLowerCase().split(/[-_]/)[0] || '';
  }
  function escapeRegex(s) {
    return String(s).replace(/[.*+?^\${}()|[\\]\\\\]/g, '\\\\\$&');
  }
  function compileSubstringRules(rules) {
    var out = [];
    for (var i = 0; i < (rules || []).length; i++) {
      var r = rules[i];
      if (!r || r.type !== 'substring' || !r.pattern) continue;
      // Whole-word mode: Unicode-aware negative lookarounds so "af"
      // matches the standalone token "af" but not "afton". \b won't
      // work with non-ASCII letters (å/ä/ö).
      var wholeWord = r.wholeWord !== false;
      var src = escapeRegex(r.pattern);
      var flags = 'g';
      if (wholeWord) {
        src = '(?<![\\\\p{L}\\\\p{M}\\\\p{N}_])' + src + '(?![\\\\p{L}\\\\p{M}\\\\p{N}_])';
        flags = 'gu';
      }
      out.push({
        re: new RegExp(src, flags),
        to: r.replacement != null ? String(r.replacement) : '',
      });
    }
    return out;
  }
  function applyRulesToString(text, compiled) {
    if (!compiled.length) return text;
    var out = text;
    for (var i = 0; i < compiled.length; i++) {
      out = out.replace(compiled[i].re, compiled[i].to);
    }
    return out;
  }
  function originalTextOf(el) {
    if (!el) return '';
    var snap = el.getAttribute && el.getAttribute('data-cupitor-orig');
    return snap != null ? snap : (el.textContent || '');
  }
  // Split a text node so every substring matched by any rule is wrapped
  // in <span class="cupitor-xform" title="orig">newText</span>. Returns
  // true if at least one substitution was applied. Non-matching runs
  // stay as plain text nodes, so only the changed pieces get the
  // dotted underline — not the whole sentence.
  function wrapTransformsInTextNode(node, compiled) {
    var parts = [{text: node.data, transformed: false}];
    for (var i = 0; i < compiled.length; i++) {
      var re = compiled[i].re;
      var replacement = compiled[i].to;
      var nextParts = [];
      for (var k = 0; k < parts.length; k++) {
        var p = parts[k];
        if (p.transformed) { nextParts.push(p); continue; }
        var s = p.text;
        re.lastIndex = 0;
        var m, lastIdx = 0, matched = false;
        while ((m = re.exec(s)) !== null) {
          if (m[0].length === 0) { re.lastIndex++; continue; }
          if (m.index > lastIdx) {
            nextParts.push({text: s.slice(lastIdx, m.index), transformed: false});
          }
          nextParts.push({text: replacement, transformed: true, orig: m[0]});
          lastIdx = m.index + m[0].length;
          matched = true;
        }
        if (matched) {
          if (lastIdx < s.length) nextParts.push({text: s.slice(lastIdx), transformed: false});
        } else {
          nextParts.push(p);
        }
      }
      parts = nextParts;
    }
    var any = false;
    for (var j = 0; j < parts.length; j++) { if (parts[j].transformed) { any = true; break; } }
    if (!any) return false;
    var frag = document.createDocumentFragment();
    for (var q = 0; q < parts.length; q++) {
      var seg = parts[q];
      if (seg.transformed) {
        var span = document.createElement('span');
        span.className = 'cupitor-xform';
        span.textContent = seg.text;
        span.setAttribute('title', seg.orig);
        frag.appendChild(span);
      } else if (seg.text.length) {
        frag.appendChild(document.createTextNode(seg.text));
      }
    }
    node.parentNode.replaceChild(frag, node);
    return true;
  }
  window.__cupitorApplyTextTransforms = function() {
    ensureStyles();
    // User toggle: skip entirely when transforms are turned off. The
    // flag is undefined-friendly — anything other than a strict
    // `false` counts as "on" so first-run behavior is unchanged.
    if (window.__cupitorTransformsEnabled === false) return;
    var lang = currentLangPrimary();
    var all = (window.__cupitorTextTransforms || {});
    var rules = all[lang] || [];
    var compiled = compileSubstringRules(rules);
    if (!compiled.length) return;
    // Per .cup-sent: snapshot the original text on the parent (identity
    // paths — norms[], sliceText — recover from data-cupitor-orig), then
    // wrap changed substrings in child spans so ONLY those get the
    // dotted-underline decoration. The parent .cup-sent itself no
    // longer receives the .cupitor-xform class.
    var sents = document.querySelectorAll('.cup-sent');
    for (var i = 0; i < sents.length; i++) {
      var sent = sents[i];
      // Skip cup-sents we've already transformed (idempotent re-runs).
      if (sent.hasAttribute('data-cupitor-orig')) continue;
      var origText = sent.textContent || '';
      // Collect text nodes first so wrapping doesn't disturb the walker.
      var textNodes = [];
      var walker = document.createTreeWalker(sent, NodeFilter.SHOW_TEXT, null, false);
      var node;
      while ((node = walker.nextNode())) textNodes.push(node);
      var didChange = false;
      for (var t = 0; t < textNodes.length; t++) {
        if (wrapTransformsInTextNode(textNodes[t], compiled)) didChange = true;
      }
      if (didChange) {
        sent.setAttribute('data-cupitor-orig', origText);
        sent.setAttribute('title', origText);
      }
    }
  };
  // Undo whatever __cupitorApplyTextTransforms did to the DOM: for
  // every .cup-sent that was rewritten (has a data-cupitor-orig
  // snapshot), replace its children with a single text node holding
  // the original text. This wipes wrapper spans introduced by the
  // transform pass; a subsequent apply call re-creates them.
  window.__cupitorRevertTextTransforms = function() {
    var sents = document.querySelectorAll('.cup-sent[data-cupitor-orig]');
    for (var i = 0; i < sents.length; i++) {
      var sent = sents[i];
      var orig = sent.getAttribute('data-cupitor-orig') || '';
      while (sent.firstChild) sent.removeChild(sent.firstChild);
      sent.appendChild(document.createTextNode(orig));
      sent.removeAttribute('data-cupitor-orig');
      sent.removeAttribute('title');
    }
  };
  // Recompute the tagids CSV / mask attribute / background color of a
  // single span from the union of groups now covering it.
  function recomputeSpanAttrs(el) {
    var ids = spanDbids(el);
    if (!ids.length) {
      el.removeAttribute('data-cupitor-tagids');
      el.removeAttribute('data-cupitor-mask');
      el.style.backgroundColor = '';
      return;
    }
    var tagBag = {};
    // Shortest-wins for paint: when a short overlay (e.g. spans 3..4)
    // sits on top of a longer group (1..8), the narrower one should
    // visually pop — like CSS specificity. The longer group still
    // paints the spans it owns exclusively.
    var paintGroup = null;
    var bestMaskGroup = null;
    for (var i = 0; i < ids.length; i++) {
      var g = tagSets[ids[i]];
      if (!g) continue;
      for (var j = 0; j < (g.tagIds || []).length; j++) tagBag[g.tagIds[j]] = 1;
      if (g.colors && g.colors.length) {
        var gLen = g.to - g.from + 1;
        if (!paintGroup || (paintGroup.to - paintGroup.from + 1) > gLen) {
          paintGroup = g;
        }
      }
      if (g.mask) {
        var mLen = g.to - g.from + 1;
        if (!bestMaskGroup || (bestMaskGroup.to - bestMaskGroup.from + 1) < mLen) {
          bestMaskGroup = g;
        }
      }
    }
    var paintColors = paintGroup ? paintGroup.colors : null;
    var tagArr = Object.keys(tagBag);
    if (tagArr.length) el.setAttribute('data-cupitor-tagids', tagArr.join(','));
    else el.removeAttribute('data-cupitor-tagids');
    if (bestMaskGroup) el.setAttribute('data-cupitor-mask', bestMaskGroup.mask);
    else el.removeAttribute('data-cupitor-mask');
    paintSpansWithTagColors([el], paintColors || []);
  }
  function registerTagSet(id, tagIds, colors, from, to, mask) {
    tagSets[id] = {
      id: id,
      tagIds: tagIds || [],
      colors: colors || [],
      from: from, to: to,
      mask: mask || '',
    };
  }
  function stampGroup(id) {
    var g = tagSets[id];
    if (!g) return;
    for (var i = g.from; i <= g.to; i++) {
      var el = getSentSpan(i);
      if (!el) continue;
      addDbidToSpan(el, id);
      recomputeSpanAttrs(el);
    }
  }
  function unstampGroup(id) {
    var g = tagSets[id];
    if (!g) return;
    for (var i = g.from; i <= g.to; i++) {
      var el = getSentSpan(i);
      if (!el) continue;
      removeDbidFromSpan(el, id);
      recomputeSpanAttrs(el);
    }
    delete tagSets[id];
  }
  // Longest-wins: among the groups on this span that have a mask, pick
  // the dbid whose range covers the most sentences. When a filter is
  // active, groups whose tagIds don't intersect the filter are skipped
  // — so masking respects "show only these tags" semantics. Returns
  // null when no eligible group on the span carries a mask.
  // A group has "maskover content" if either it has explicit mask
  // text OR the user turned on "Show maskover pictures" and this
  // group's sentence carries an image attachment. Both are treated
  // identically by the injection pipeline — a picture stands in for
  // the text when there is no text to stand behind.
  function hasMaskContent(g) {
    if (!g) return false;
    if (g.mask) return true;
    if (window.__cupitorShowMaskImages
        && window.__cupitorMediaImages
        && window.__cupitorMediaImages[g.id]) {
      return true;
    }
    return false;
  }
  function winningMaskDbid(el) {
    var ids = spanDbids(el);
    var bestId = null, bestLen = -1;
    for (var i = 0; i < ids.length; i++) {
      var g = tagSets[ids[i]];
      if (!hasMaskContent(g)) continue;
      if (activeFilterSet) {
        var anyMatch = false;
        for (var t = 0; t < (g.tagIds || []).length; t++) {
          if (activeFilterSet[g.tagIds[t]]) { anyMatch = true; break; }
        }
        if (!anyMatch) continue;
      }
      var len = g.to - g.from + 1;
      if (len > bestLen) { bestLen = len; bestId = ids[i]; }
    }
    return bestId;
  }
  function getSentSpan(n) {
    return document.querySelector('.cup-sent[data-sent="' + n + '"]');
  }
  function sentenceCount() {
    return document.querySelectorAll('.cup-sent').length;
  }
  function fpNormalize(s) {
    var out = (s || '').toLowerCase();
    out = out.replace(/[.,!?;:'"()\\[\\]{}\\-—–…]/g, '');
    out = out.replace(/\\s+/g, ' ').replace(/^\\s+|\\s+\$/g, '');
    return out;
  }
  async function fp(s) {
    var norm = fpNormalize(s);
    if (!norm) return '';
    try {
      var enc = new TextEncoder().encode(norm);
      var buf = await crypto.subtle.digest('SHA-1', enc);
      var bytes = new Uint8Array(buf);
      var hex = '';
      for (var i = 0; i < bytes.length; i++) {
        var h = bytes[i].toString(16);
        if (h.length === 1) hex += '0';
        hex += h;
      }
      return hex.substring(0, 8);
    } catch (e) { return ''; }
  }
  function sliceText(from, to) {
    var t = '';
    for (var i = from; i <= to; i++) {
      var el = getSentSpan(i);
      // Use the ORIGINAL text when a transform has rewritten this
      // .cup-sent so captured payloads fingerprint against source text.
      if (el) t += (t ? ' ' : '') + originalTextOf(el).replace(/\\s+/g, ' ').trim();
    }
    return t;
  }
  function applyTempHighlight() {
    document.querySelectorAll('.cup-sent.cupitor-temp-highlight').forEach(function(el) {
      el.classList.remove('cupitor-temp-highlight');
    });
    for (var i = st.from; i <= st.to; i++) {
      var el = getSentSpan(i);
      if (el) el.classList.add('cupitor-temp-highlight');
    }
  }
  async function emitCapture(op) {
    var text = sliceText(st.from, st.to);
    var prevText = st.from > 0 ? (getSentSpan(st.from - 1)?.textContent || '') : '';
    var nextText = st.to < sentenceCount() - 1 ? (getSentSpan(st.to + 1)?.textContent || '') : '';
    var prevFp = prevText ? await fp(prevText) : '';
    var nextFp = nextText ? await fp(nextText) : '';
    if (window.SentenceTagHandler) {
      window.SentenceTagHandler.postMessage(JSON.stringify({
        op: op,
        sentenceId: st.sid,
        text: text,
        prev: prevText,
        next: nextText,
        prevFp: prevFp,
        nextFp: nextFp,
      }));
    }
  }
  window.__cupitorSetCaptureMode = function(active) {
    window.__cupitorCaptureMode = !!active;
    if (!active && st.sid) {
      document.querySelectorAll('.cup-sent.cupitor-temp-highlight').forEach(function(el) {
        el.classList.remove('cupitor-temp-highlight');
      });
      st = { from: -1, to: -1, sid: null };
    }
  };
  window.__cupitorOnEpubSentenceTap = function(ev) {
    ensureStyles();
    var tgt = ev.target;
    var span = tgt && tgt.closest && tgt.closest('.cup-sent');
    // Tapping the visible mask should behave like tapping the hidden
    // .cup-sent it replaces — otherwise capture-mode taps on masked
    // text fall through to the lookup dialog.
    if (!span) {
      var maskEl = tgt && tgt.closest && tgt.closest('.cupitor-mask');
      if (maskEl) {
        var ids = spanDbids(maskEl);
        if (ids.length && window.SentenceTagHandler) {
          var anchor = tagSets[ids[0]];
          var idx = anchor ? anchor.from : -1;
          ev.preventDefault();
          ev.stopPropagation();
          window.SentenceTagHandler.postMessage(JSON.stringify({
            op: 'taggedChoice',
            sentenceIndex: idx,
            dbids: ids,
          }));
          return true;
        }
      }
    }
    if (window.__cupitorVerbose && window.SnippetLogChannel) {
      var tgName = (tgt && tgt.tagName) ? tgt.tagName : '?';
      var hasSent = span ? span.getAttribute('data-sent') : 'none';
      window.SnippetLogChannel.postMessage(
        '[tagging-epub] tap target=' + tgName + ' .cup-sent=' + hasSent
      );
    }
    if (!span) return false;
    var n = parseInt(span.getAttribute('data-sent'), 10);
    if (isNaN(n)) return false;
    ev.preventDefault();
    ev.stopPropagation();
    // Playlist capture takes precedence over tag capture: when armed,
    // any sentence tap opens the playlist mini-sheet on Dart side and
    // re-uses the existing extend flow (`__cupitorRequestExtend`) so
    // Prev/Next/Drop-first/Drop-last work identically to tag capture.
    // Text is joined from originalTextOf inside sliceText — transforms
    // don't leak into the persisted card.
    if (window.__cupitorPlaylistCaptureMode && window.SentenceTagHandler) {
      st = { from: n, to: n, sid: 'pl_' + n };
      applyTempHighlight();
      emitCapture('playlistCapture');
      return true;
    }
    // If the sentence is already part of a tagged group, ask Dart to
    // show a chooser (Edit existing | Tag this sentence alone) instead
    // of jumping straight into capture — otherwise a single-sentence
    // commit overwrites the group's visual link on this span.
    var existingIds = spanDbids(span);
    if (existingIds.length && window.SentenceTagHandler) {
      window.SentenceTagHandler.postMessage(JSON.stringify({
        op: 'taggedChoice',
        sentenceIndex: n,
        dbids: existingIds,
      }));
      return true;
    }
    st = { from: n, to: n, sid: 'cs_' + n };
    applyTempHighlight();
    emitCapture('capture');
    return true;
  };
  // Programmatic entry point used when Dart's chooser picks "Tag this
  // sentence alone" — kicks off a fresh capture for the chosen index.
  window.__cupitorForceCaptureSentence = function(n) {
    var span = document.querySelector('.cup-sent[data-sent="' + n + '"]');
    if (!span) return;
    st = { from: n, to: n, sid: 'cs_' + n };
    applyTempHighlight();
    emitCapture('capture');
  };
  window.__cupitorRequestExtend = async function(sid, direction) {
    if (!st || st.sid !== sid) {
      if (window.SentenceTagHandler) {
        window.SentenceTagHandler.postMessage(JSON.stringify({
          op: 'extend', sentenceId: sid, direction: direction, text: null,
        }));
      }
      return;
    }
    var atBoundary = false;
    if (direction === 'prev') {
      if (st.from > 0) st.from -= 1; else atBoundary = true;
    } else if (direction === 'next') {
      if (st.to < sentenceCount() - 1) st.to += 1; else atBoundary = true;
    } else if (direction === 'trimStart') {
      if (st.to > st.from) st.from += 1; else atBoundary = true;
    } else if (direction === 'trimEnd') {
      if (st.to > st.from) st.to -= 1; else atBoundary = true;
    }
    if (atBoundary) {
      if (window.SentenceTagHandler) {
        window.SentenceTagHandler.postMessage(JSON.stringify({
          op: 'extend', sentenceId: sid, direction: direction, text: null,
        }));
      }
      return;
    }
    applyTempHighlight();
    var payload = await (async function() {
      var text = sliceText(st.from, st.to);
      var prevText = st.from > 0 ? (getSentSpan(st.from - 1)?.textContent || '') : '';
      var nextText = st.to < sentenceCount() - 1 ? (getSentSpan(st.to + 1)?.textContent || '') : '';
      var prevFp = prevText ? await fp(prevText) : '';
      var nextFp = nextText ? await fp(nextText) : '';
      return { op: 'extend', sentenceId: sid, direction: direction, text: text,
               prev: prevText, next: nextText, prevFp: prevFp, nextFp: nextFp };
    })();
    if (window.SentenceTagHandler) {
      window.SentenceTagHandler.postMessage(JSON.stringify(payload));
    }
  };
  window.__cupitorClearTempHighlight = function(sid) {
    document.querySelectorAll('.cup-sent.cupitor-temp-highlight').forEach(function(el) {
      el.classList.remove('cupitor-temp-highlight');
    });
    st = { from: -1, to: -1, sid: null };
  };
  function paintSpansWithTagColors(spans, colors) {
    if (!colors || !colors.length) {
      spans.forEach(function(el) { el.style.backgroundColor = ''; });
      return;
    }
    var hex = (colors[0] || '#FFC107').replace('#','');
    if (hex.length === 3) hex = hex.split('').map(function(c){return c+c;}).join('');
    var r = parseInt(hex.substring(0,2),16),
        g = parseInt(hex.substring(2,4),16),
        b = parseInt(hex.substring(4,6),16);
    var rgba = 'rgba(' + r + ',' + g + ',' + b + ',0.30)';
    spans.forEach(function(el) { el.style.backgroundColor = rgba; });
  }
  window.__cupitorCommitTags = function(sid, dbid, colorsJson, tagIdsCsv, mask) {
    var colors;
    try { colors = JSON.parse(colorsJson); } catch (_) { colors = []; }
    var tagIds = (tagIdsCsv == null ? '' : String(tagIdsCsv))
      .split(',').map(function(x){return parseInt(x,10);})
      .filter(function(n){return !isNaN(n);});
    for (var i = st.from; i <= st.to; i++) {
      var el = getSentSpan(i);
      if (el) el.classList.remove('cupitor-temp-highlight');
    }
    if (dbid != null && String(dbid) !== '') {
      var id = parseInt(dbid, 10);
      // Re-edit of an existing group: tear down its old stamp first so
      // recompute reflects the new range / tags / mask cleanly.
      if (tagSets[id]) unstampGroup(id);
      registerTagSet(id, tagIds, colors, st.from, st.to, mask || '');
      stampGroup(id);
      if (masksVisible) refreshAllMaskInjections();
    }
    st = { from: -1, to: -1, sid: null };
  };
  window.__cupitorApplyTags = function(json) {
    ensureStyles();
    try { rehydrated = JSON.parse(json); } catch (_) { rehydrated = []; }
    // Hard reset: drop mask injections + every span's stamp state.
    clearAllMaskInjections();
    tagSets = {};
    document.querySelectorAll('.cup-sent').forEach(function(el) {
      el.removeAttribute('data-cupitor-dbid');
      el.removeAttribute('data-cupitor-tagids');
      el.removeAttribute('data-cupitor-mask');
      el.removeAttribute('data-cupitor-media-marker');
      el.style.backgroundColor = '';
    });
    // Emoji per media kind; kept in the JS engine so nothing has to be
    // pushed from Dart beyond the kinds list. 'link' represents URL
    // attachments (extension-inferred kind is ignored for those).
    var __mediaGlyph = {
      image: '\u{1F4F7}', audio: '\u{1F50A}',
      video: '\u{1F3AC}', link: '\u{1F517}',
    };
    function __applyMediaMarker(el, kinds) {
      if (!el || !kinds || !kinds.length) return;
      var existing = el.getAttribute('data-cupitor-media-marker') || '';
      var out = existing;
      for (var i = 0; i < kinds.length; i++) {
        var g = __mediaGlyph[kinds[i]];
        if (g && out.indexOf(g) < 0) out += g;
      }
      if (out !== existing) el.setAttribute('data-cupitor-media-marker', out);
    }
    var matched = 0;
    var unmatched = [];
    var all = document.querySelectorAll('.cup-sent');
    var norms = new Array(all.length);
    // Fingerprint each cup-sent against its ORIGINAL text so records
    // saved before any transform still rehydrate identically.
    for (var k = 0; k < all.length; k++) norms[k] = fpNormalize(originalTextOf(all[k]));
    // Overlapping captures are first-class: don't skip already-stamped
    // spans, just locate each record's own range and add it to tagSets.
    // No upper cap on run length — the inner loop bails as soon as the
    // running concatenation exceeds the record's target length + 8 chars,
    // which is a tighter bound than any fixed sentence-count would be.
    for (var r = 0; r < rehydrated.length; r++) {
      var rec = rehydrated[r];
      var normRec = fpNormalize(rec.text);
      var found = false;
      for (var i = 0; i < all.length && !found; i++) {
        var acc = norms[i];
        if (acc === normRec) {
          registerTagSet(rec.id, rec.tagIds || [], rec.tagColors || [], i, i, rec.mask || '');
          stampGroup(rec.id);
          __applyMediaMarker(all[i], rec.mediaKinds);
          matched++; found = true;
          break;
        }
        for (var j = i + 1; j < all.length; j++) {
          // join with a single space — mirrors the Dart-side rule when
          // committing multi-sentence captures.
          acc = acc + (acc && norms[j] ? ' ' : '') + norms[j];
          if (acc === normRec) {
            registerTagSet(rec.id, rec.tagIds || [], rec.tagColors || [], i, j, rec.mask || '');
            stampGroup(rec.id);
            __applyMediaMarker(all[i], rec.mediaKinds);
            matched++; found = true;
            break;
          }
          if (acc.length > normRec.length + 8) break;
        }
      }
      if (!found) {
        unmatched.push(rec);
      }
    }
    // Whitespace-insensitive second pass for records the strict-equality
    // walk missed. Removes inner spaces from both the record text and
    // the running concatenation so a stray space (or its absence) at a
    // .cup-sent boundary no longer blocks a match.
    if (unmatched.length) {
      var stillUnmatched = [];
      for (var u = 0; u < unmatched.length; u++) {
        var rec2 = unmatched[u];
        var collapsedRec = fpNormalize(rec2.text).replace(/\\s+/g, '');
        var found2 = false;
        for (var i2 = 0; i2 < all.length && !found2; i2++) {
          var acc2 = norms[i2];
          var collapsedAcc = acc2.replace(/\\s+/g, '');
          if (collapsedAcc === collapsedRec) {
            registerTagSet(rec2.id, rec2.tagIds || [], rec2.tagColors || [], i2, i2, rec2.mask || '');
            stampGroup(rec2.id);
            __applyMediaMarker(all[i2], rec2.mediaKinds);
            matched++; found2 = true;
            break;
          }
          for (var j2 = i2 + 1; j2 < all.length; j2++) {
            acc2 = acc2 + (acc2 && norms[j2] ? ' ' : '') + norms[j2];
            collapsedAcc = acc2.replace(/\\s+/g, '');
            if (collapsedAcc === collapsedRec) {
              registerTagSet(rec2.id, rec2.tagIds || [], rec2.tagColors || [], i2, j2, rec2.mask || '');
              stampGroup(rec2.id);
              __applyMediaMarker(all[i2], rec2.mediaKinds);
              matched++; found2 = true;
              break;
            }
            if (collapsedAcc.length > collapsedRec.length + 8) break;
          }
        }
        if (!found2) stillUnmatched.push(rec2);
      }
      unmatched = stillUnmatched;
    }
    if (masksVisible) refreshAllMaskInjections();
    if (window.SnippetLogChannel) {
      window.SnippetLogChannel.postMessage(
        '[tagging-epub] rehydrate matched=' + matched + '/' + rehydrated.length
      );
      for (var u2 = 0; u2 < unmatched.length; u2++) {
        var ur = unmatched[u2];
        var snippet = (ur.text || '').replace(/\\n/g, ' ').substring(0, 140);
        window.SnippetLogChannel.postMessage(
          '[tagging-epub] unmatched id=' + ur.id +
          ' tags=' + (ur.tagIds || []).join(',') +
          ' textLen=' + (ur.text || '').length +
          ' text=' + JSON.stringify(snippet)
        );
      }
    }
  };
  // Wipe ALL tag-paint, dbid stamps, mask injections. Used by Dart when
  // switching profiles; the install/rehydrate cycle re-runs with the
  // new profile's records right after.
  window.__cupitorClearAllTags = function() {
    rehydrated = [];
    tagSets = {};
    activeFilterSet = null;
    clearAllMaskInjections();
    document.querySelectorAll('.cup-sent').forEach(function(el) {
      el.style.backgroundColor = '';
      el.removeAttribute('data-cupitor-dbid');
      el.removeAttribute('data-cupitor-tagids');
      el.removeAttribute('data-cupitor-mask');
      el.classList.remove('cupitor-fade');
    });
    document.body && document.body.classList.remove('cupitor-filter-active');
  };
  // Dart calls this after a record is deleted in the DB so we drop just
  // that group's stamp (and any masks it owned) without re-rehydrating.
  window.__cupitorUnstampGroup = function(dbid) {
    var id = parseInt(dbid, 10);
    if (isNaN(id)) return;
    if (tagSets[id]) {
      unstampGroup(id);
      if (masksVisible) refreshAllMaskInjections();
    }
  };
  window.__cupitorApplyFilter = function(json) {
    ensureStyles();
    var ids;
    try { ids = JSON.parse(json); } catch (_) { ids = []; }
    if (!ids.length) {
      activeFilterSet = null;
      document.body && document.body.classList.remove('cupitor-filter-active');
    } else {
      activeFilterSet = {};
      for (var k = 0; k < ids.length; k++) activeFilterSet[ids[k]] = 1;
      document.body && document.body.classList.add('cupitor-filter-active');
    }
    // Re-layout masks so a filtered-out group no longer wins the mask
    // run for spans where a filter-matching shorter group exists.
    if (masksVisible) refreshAllMaskInjections();
    // Include .cupitor-mask: when masks are visible the original .cup-sent
    // is display:none, so the mask span is what the user sees and the
    // filter must drive its fade state via its own data-cupitor-tagids.
    var spans = document.querySelectorAll('.cup-sent, .cupitor-mask');
    if (!activeFilterSet) {
      for (var i = 0; i < spans.length; i++) spans[i].classList.remove('cupitor-fade');
      return;
    }
    for (var i2 = 0; i2 < spans.length; i2++) {
      var csv = spans[i2].getAttribute('data-cupitor-tagids');
      var keep = false;
      if (csv) {
        var arr = csv.split(',');
        for (var mIdx = 0; mIdx < arr.length; mIdx++) {
          var n = parseInt(arr[mIdx], 10);
          if (!isNaN(n) && activeFilterSet[n]) { keep = true; break; }
        }
      }
      if (keep) spans[i2].classList.remove('cupitor-fade');
      else spans[i2].classList.add('cupitor-fade');
    }
  };
  function clearAllMaskInjections() {
    Object.keys(maskInjections).forEach(function(key) {
      var info = maskInjections[key];
      if (info && info.el && info.el.parentNode) info.el.parentNode.removeChild(info.el);
    });
    maskInjections = {};
    document.querySelectorAll('.cup-sent.cupitor-masked-out').forEach(function(el) {
      el.classList.remove('cupitor-masked-out');
    });
  }
  // Walk all .cup-sent, group consecutive ones by their "winning" mask
  // group (longest-wins per span), and inject one .cupitor-mask span per
  // run. Overlapping groups whose mask loses to a longer one don't get
  // their own mask injected.
  function refreshAllMaskInjections() {
    clearAllMaskInjections();
    if (!masksVisible) return;
    var all = document.querySelectorAll('.cup-sent');
    var runStart = -1, runDbid = null;
    function injectRun(start, end, winningDbid) {
      if (start < 0 || winningDbid == null) return;
      var g = tagSets[winningDbid];
      if (!hasMaskContent(g)) return;
      var firstEl = all[start], lastEl = all[end];
      var maskEl = document.createElement('span');
      maskEl.className = 'cupitor-mask';
      maskEl.setAttribute('data-cupitor-dbid', String(winningDbid));
      var tagIds = firstEl.getAttribute('data-cupitor-tagids') || '';
      if (tagIds) maskEl.setAttribute('data-cupitor-tagids', tagIds);
      var bg = firstEl.style.backgroundColor;
      if (bg) maskEl.style.backgroundColor = bg;
      // Image maskover: when the toggle is on and the winning group's
      // sentence has an image attached (URL or local data URL, pushed
      // into window.__cupitorMediaImages), render the image in place
      // of the text mask so the user sees the picture "cover" instead.
      var imgSrc = (window.__cupitorShowMaskImages && window.__cupitorMediaImages)
          ? window.__cupitorMediaImages[winningDbid] : null;
      if (imgSrc) {
        var img = document.createElement('img');
        img.className = 'cupitor-mask-image';
        img.src = imgSrc;
        img.alt = g.mask || '';
        maskEl.appendChild(img);
      } else {
        maskEl.textContent = g.mask;
      }
      lastEl.parentNode.insertBefore(maskEl, lastEl.nextSibling);
      for (var i = start; i <= end; i++) {
        all[i].classList.add('cupitor-masked-out');
      }
      maskInjections[winningDbid + ':' + start + '-' + end] = {
        el: maskEl, runFrom: start, runTo: end, dbid: winningDbid,
      };
    }
    for (var i = 0; i < all.length; i++) {
      var w = winningMaskDbid(all[i]);
      if (w == null) {
        if (runStart >= 0) { injectRun(runStart, i - 1, runDbid); runStart = -1; runDbid = null; }
        continue;
      }
      if (w !== runDbid) {
        if (runStart >= 0) injectRun(runStart, i - 1, runDbid);
        runStart = i; runDbid = w;
      }
    }
    if (runStart >= 0) injectRun(runStart, all.length - 1, runDbid);
  }
  window.__cupitorSetMasksVisible = function(active) {
    ensureStyles();
    masksVisible = !!active;
    refreshAllMaskInjections();
  };
  // Exposed so Dart-side toggles (e.g. Show maskover pictures) can
  // re-render mask elements without flipping mask visibility itself.
  window.__cupitorRefreshMaskInjections = function() {
    refreshAllMaskInjections();
  };
  var LP_MS = 500;
  var lpTimer = null, lpTarget = null, lpFired = false;
  function lpStart(ev) {
    var src = ev.target && ev.target.closest && ev.target.closest('[data-cupitor-dbid]');
    if (!src) return;
    lpTarget = src; lpFired = false;
    clearTimeout(lpTimer);
    lpTimer = setTimeout(function() {
      lpFired = true;
      var ids = spanDbids(lpTarget);
      if (!ids.length) return;
      if (!window.SentenceTagHandler) return;
      if (ids.length === 1) {
        window.SentenceTagHandler.postMessage(JSON.stringify({
          op: 'editRequest', dbid: ids[0],
        }));
      } else {
        // Long-press on a span owned by multiple groups: route through
        // the chooser so the user can pick which one to edit.
        var nAttr = lpTarget.getAttribute('data-sent');
        var nIdx = parseInt(nAttr, 10);
        window.SentenceTagHandler.postMessage(JSON.stringify({
          op: 'taggedChoice',
          sentenceIndex: isNaN(nIdx) ? -1 : nIdx,
          dbids: ids,
        }));
      }
    }, LP_MS);
  }
  function lpEnd() { clearTimeout(lpTimer); lpTimer = null; lpTarget = null; }
  document.addEventListener('touchstart', lpStart, { passive: true });
  document.addEventListener('touchend', lpEnd, { passive: true });
  document.addEventListener('touchcancel', lpEnd, { passive: true });
  document.addEventListener('touchmove', lpEnd, { passive: true });
  document.addEventListener('mousedown', lpStart);
  document.addEventListener('mouseup', lpEnd);
  document.addEventListener('mouseleave', lpEnd);
  document.addEventListener('click', function(e) {
    if (lpFired) { e.preventDefault(); e.stopPropagation(); lpFired = false; }
  }, true);
})();
''';

  Future<void> _loadProfileScopedPrefs() async {
    final id = ProfileService.currentId;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(ProfileService.filterKey('epub', id));
    final parsed = (raw ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final masks = prefs.getBool(ProfileService.masksKey('epub', id)) ?? false;
    // Per-profile toggles for the two new settings. Keys mirror the
    // profile-scoping pattern used by ProfileService.masksKey.
    final xformOn = prefs.getBool('tagXformEnabled:epub:$id') ?? true;
    final maskImgs = prefs.getBool('tagMaskImages:epub:$id') ?? false;
    if (!mounted) return;
    setState(() {
      _tagFilterTagIds = parsed;
      _tagMasksVisible = masks;
      _tagTransformsEnabled = xformOn;
      _tagShowMaskImages = maskImgs;
    });
  }

  Future<void> _onProfileChanged() async {
    // Wipe the chapter's current paint, then re-run the install flow
    // under the new profile.
    await _controller?.runJavaScript(
      'window.__cupitorClearAllTags && window.__cupitorClearAllTags();',
    );
    await _loadProfileScopedPrefs();
    await _installTagHelpersAndRehydrate();
  }

  Future<void> _installTagHelpersAndRehydrate() async {
    try {
      // Install helpers FIRST and unconditionally — capture mode must
      // work even before the SQLite ready-check resolves. Otherwise the
      // first chapter loaded after launch has no capture handlers and
      // arming the floating chip silently does nothing.
      await _controller?.runJavaScript(_epubTagHelpersJs);
      await _controller?.runJavaScript(
        'window.__cupitorVerbose = ${JsLogSink.verbose.value ? 'true' : 'false'};'
        'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(${_tagCaptureArmed ? 'true' : 'false'});',
      );
      // Push text-transform rules BEFORE rehydrate paints anything so
      // display and identity settle in the same pass. Rules are keyed
      // per language; the engine reads document.documentElement.lang.
      // When the user has toggled transformations off we still push
      // the rules (so a later on-toggle can apply without reload) but
      // set the engine flag to skip application.
      try {
        final all = await TransformRuleStore.loadAll();
        final payload = <String, dynamic>{};
        all.forEach((lang, rules) {
          payload[lang] = rules.map((r) => r.toJson()).toList();
        });
        final applyCall = _tagTransformsEnabled
            ? 'window.__cupitorApplyTextTransforms && window.__cupitorApplyTextTransforms();'
            : '';
        await _controller?.runJavaScript(
          'window.__cupitorTextTransforms = ${jsonEncode(payload)};'
          'window.__cupitorTransformsEnabled = $_tagTransformsEnabled;'
          '$applyCall',
        );
      } catch (_) { /* transforms are a soft dependency */ }
      // Push the mask-image toggle before rehydrate so the very first
      // mask injection lands with the right mode.
      await _controller?.runJavaScript(
        'window.__cupitorShowMaskImages = $_tagShowMaskImages;',
      );
      JsLogSink.add(
        'log',
        '[tagging-epub] rehydrate-entry dbReady=$_tagDbReady profile=${ProfileService.currentId} locator=$_tagLocator',
      );
      if (!_tagDbReady) return;
      final rows = await CupitorDb.instance.sentencesForPage(
        profileId: ProfileService.currentId,
        surface: 'epub',
        locator: _tagLocator,
      );
      final totalTags = rows.fold<int>(0, (a, r) => a + r.tags.length);
      String sample = '(none)';
      if (rows.isNotEmpty) {
        final r = rows.first;
        sample = 'id=${r.id} tagIds=${r.tags.map((t) => t.id).toList()} '
            'tagNames=${r.tags.map((t) => t.name).toList()}';
      }
      JsLogSink.add(
        'log',
        '[tagging-epub] rehydrate-query rows=${rows.length} totalTags=$totalTags first=$sample',
      );
      if (totalTags == 0 && rows.isNotEmpty) {
        final snap = await CupitorDb.instance.diagnosticsSnapshot();
        JsLogSink.add('log', '[tagging-epub] diag $snap');
      }
      if (rows.isNotEmpty) {
        final json = jsonEncode(rows.map((r) => r.toJson()).toList());
        await _controller?.runJavaScript(
          'window.__cupitorApplyTags && window.__cupitorApplyTags(${jsonEncode(json)});',
        );
      }
      // Build the sentence_id → image src map for the "show maskover
      // pictures" toggle. URL rows use the URL directly; local files
      // are base64-encoded into a data URL so the WebView (which sees
      // a fake cupitor-epub:// base) can render them without a bridge.
      // Cap the encoded size per image so a huge attachment doesn't
      // eat the JS payload; oversize images are dropped silently and
      // the mask falls back to text.
      try {
        final imgs = await CupitorDb.instance.imageMediaByDbidForPage(
          profileId: ProfileService.currentId,
          surface: 'epub',
          locator: _tagLocator,
        );
        final payload = <String, String>{};
        for (final entry in imgs.entries) {
          final m = entry.value;
          if (m.isUrl && (m.url ?? '').isNotEmpty) {
            payload[entry.key.toString()] = m.url!;
            continue;
          }
          final ext = _extOfFilename(m.filename);
          final file = await MediaStore.instance.resolve(m.sha1, extension: ext);
          if (file == null) continue;
          try {
            final size = await file.length();
            if (size > 2 * 1024 * 1024) continue; // skip > 2 MB
            final bytes = await file.readAsBytes();
            final mime = m.mimeType ?? _mimeForExt(ext);
            payload[entry.key.toString()] = 'data:$mime;base64,${base64Encode(bytes)}';
          } catch (_) { /* skip unreadable file */ }
        }
        await _controller?.runJavaScript(
          'window.__cupitorMediaImages = ${jsonEncode(payload)};',
        );
      } catch (_) { /* image maskover is a soft dependency */ }
      if (_tagFilterTagIds.isNotEmpty) {
        await _controller?.runJavaScript(
          "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(_tagFilterTagIds.toList()))});",
        );
      }
      if (_tagMasksVisible) {
        await _controller?.runJavaScript(
          'window.__cupitorSetMasksVisible && window.__cupitorSetMasksVisible(true);',
        );
      }
    } catch (_) {}
  }

  static String _extOfFilename(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String _mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'png': return 'image/png';
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'bmp': return 'image/bmp';
      case 'heic':
      case 'heif': return 'image/heic';
      case 'svg': return 'image/svg+xml';
      default: return 'application/octet-stream';
    }
  }

  void _onSentenceTagMessage(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      switch (m['op']) {
        case 'capture':
          _controller?.runJavaScript(
            'window.SnippetLogChannel && window.SnippetLogChannel.postMessage('
            "'[tagging-epub] dart got capture sid=' + ${jsonEncode(jsonEncode((m['sentenceId'] as String?) ?? ''))} + "
            "' dbReady=$_tagDbReady');",
          );
          _openTagCaptureSheet(
            sid: m['sentenceId'] as String,
            text: (m['text'] as String?) ?? '',
            prevFp: (m['prevFp'] as String?) ?? '',
            nextFp: (m['nextFp'] as String?) ?? '',
          );
          break;
        case 'extend':
          _pendingTagExtend?.complete(ExtendResult(
            text: m['text'] as String?,
            prevFp: (m['prevFp'] as String?) ?? '',
            nextFp: (m['nextFp'] as String?) ?? '',
          ));
          _pendingTagExtend = null;
          break;
        case 'editRequest':
          final dbid = (m['dbid'] as num?)?.toInt();
          if (dbid != null) _openEpubEditSheetForDbId(dbid);
          break;
        case 'taggedChoice':
          final raw = m['dbids'];
          final dbids = (raw is List)
              ? raw.map((e) => (e as num).toInt()).toList()
              : <int>[];
          final sIdx = (m['sentenceIndex'] as num?)?.toInt();
          if (dbids.isNotEmpty && sIdx != null) {
            _showTaggedSentenceChoice(dbids, sIdx);
          }
          break;
        case 'playlistCapture':
          _openPlaylistCaptureSheet(
            sid: (m['sentenceId'] as String?) ?? '',
            text: (m['text'] as String?) ?? '',
            prevFp: (m['prevFp'] as String?) ?? '',
            nextFp: (m['nextFp'] as String?) ?? '',
          );
          break;
      }
    } catch (_) {}
  }

  Future<void> _openPlaylistCaptureSheet({
    required String sid,
    required String text,
    required String prevFp,
    required String nextFp,
  }) async {
    if (!mounted) return;
    if (PlaylistService.activeId.value == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
          'No active playlist — open Playlists and create one first.',
        )),
      );
      // No st to clear on JS side yet — the temp highlight was applied.
      await _controller?.runJavaScript(
        "window.__cupitorClearTempHighlight && window.__cupitorClearTempHighlight('');",
      );
      return;
    }
    final result = await showModalBottomSheet<_PlaylistCaptureResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PlaylistCaptureSheet(
        initialText: text,
        onExtendRequested: (dir) => _requestTagExtend(sid, dir),
      ),
    );
    // Always clear the transient highlight in JS: state was seeded on
    // the tap, so cancel and successful save both need to reset it.
    await _controller?.runJavaScript(
      "window.__cupitorClearTempHighlight && window.__cupitorClearTempHighlight('');",
    );
    if (result == null || !mounted) return;
    final row = await PlaylistService.addToActive(
      sentenceText: result.text,
      bookKey: book.key,
      bookTitle: book.title,
      chapterIdx: _state.chapterIdx,
      chapterTitle: _currentChapterTitleForPlaylist(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(row == null ? 'Could not save to playlist.' : 'Added to playlist.'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String? _currentChapterTitleForPlaylist() {
    if (_state.chapterIdx < 0 || _state.chapterIdx >= book.chapters.length) {
      return null;
    }
    final c = book.chapters[_state.chapterIdx];
    return c.title.isEmpty ? null : c.title;
  }

  Future<void> _showTaggedSentenceChoice(
    List<int> existingDbids,
    int sentenceIndex,
  ) async {
    if (!mounted) return;
    // Fetch every group's row so the sheet can show tag names + a
    // preview of the captured text for each option.
    final entries = <({int dbid, TaggedSentenceRow row})>[];
    for (final d in existingDbids) {
      final r = await CupitorDb.instance.sentenceById(d);
      if (r != null) entries.add((dbid: d, row: r));
    }
    if (!mounted) return;
    final choice = await showModalBottomSheet<dynamic>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                entries.length == 1
                    ? 'This sentence is already part of a tagged group.'
                    : 'This sentence belongs to ${entries.length} tagged groups.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 8),
            for (final e in entries)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(
                  e.row.sentence.tags.isEmpty
                      ? 'Edit existing (no tags)'
                      : 'Edit "${e.row.sentence.tags.map((t) => t.name).join(', ')}"',
                ),
                subtitle: Text(
                  e.row.sentence.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(ctx).pop(e.dbid),
              ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('Tag this sentence alone'),
              subtitle: const Text('Creates a new tag on just this sentence'),
              onTap: () => Navigator.of(ctx).pop('new'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.of(ctx).pop(null),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice is int) {
      _openEpubEditSheetForDbId(choice);
    } else if (choice == 'new') {
      await _controller?.runJavaScript(
        'window.__cupitorForceCaptureSentence && window.__cupitorForceCaptureSentence($sentenceIndex);',
      );
    } else {
      await _controller?.runJavaScript(
        "window.__cupitorClearTempHighlight && window.__cupitorClearTempHighlight('');",
      );
    }
  }

  /// Persist media attach/remove requests from the capture sheet.
  /// Called after the sentence is upserted (so we know its row id).
  Future<void> _applyMediaChanges(CaptureSaveResult res, int sentenceId) async {
    for (final id in res.removedMediaIds) {
      final orphanSha = await CupitorDb.instance.deleteMediaReturningOrphanSha1(id);
      if (orphanSha != null) {
        await MediaStore.instance.deleteFile(orphanSha);
      }
    }
    for (final pending in res.pendingMedia) {
      try {
        final info = await MediaStore.instance.ingest(
          pending.file,
          originalFilename: pending.originalFilename,
        );
        final kind = MediaStore.kindFromMime(null, info.extension);
        await CupitorDb.instance.addSentenceMedia(
          sentenceId: sentenceId,
          kind: kind,
          sha1: info.sha1,
          filename: info.originalFilename,
          sizeBytes: info.sizeBytes,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Attach failed: $e')),
          );
        }
      }
    }
    for (final urlAtt in res.pendingUrls) {
      try {
        await CupitorDb.instance.addSentenceMedia(
          sentenceId: sentenceId,
          kind: urlAtt.kind,
          sha1: '',
          url: urlAtt.url,
          filename: (urlAtt.label != null && urlAtt.label!.isNotEmpty)
              ? urlAtt.label!
              : urlAtt.url,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('URL attach failed: $e')),
          );
        }
      }
    }
  }

  Future<void> _openEpubEditSheetForDbId(int dbid) async {
    if (!_tagDbReady) return;
    final row = await CupitorDb.instance.sentenceById(dbid);
    if (row == null || !mounted) return;
    final s = row.sentence;
    final sid = 'cs_edit_$dbid';
    final res = await showTagCaptureSheet(
      context: context,
      initial: CapturePayload(
        sentenceId: sid,
        text: s.text,
        prevFp: s.prevFp ?? '',
        nextFp: s.nextFp ?? '',
      ),
      profileId: row.profileId,
      surface: row.surface,
      locator: row.locator,
      onExtendRequested: (_) async =>
          const ExtendResult(text: null, prevFp: '', nextFp: ''),
      preselectedTagIds: s.tags.map((t) => t.id),
      initialMask: s.mask ?? '',
      extendDisabled: true,
      existingDbId: dbid,
    );
    if (res == null) return;
    if (res.deleted) {
      try {
        await CupitorDb.instance.deleteSentence(dbid);
        if (row.surface == 'epub' && row.locator == _tagLocator) {
          // Drop this group's stamp from every covered span and let the
          // helper recompute attrs (preserves other overlapping groups).
          await _controller?.runJavaScript(
            'window.__cupitorUnstampGroup && window.__cupitorUnstampGroup($dbid);',
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tagged sentence deleted.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: $e')),
          );
        }
      }
      return;
    }
    try {
      final upsertedId = await CupitorDb.instance.upsertSentenceWithTags(
        profileId: row.profileId,
        surface: row.surface,
        locator: row.locator,
        title: row.pageTitle ??
            '${book.title} — ${book.chapters[_state.chapterIdx].title}',
        text: res.text,
        prevFp: res.prevFp.isEmpty ? null : res.prevFp,
        nextFp: res.nextFp.isEmpty ? null : res.nextFp,
        tagIds: res.tagIds,
        mask: res.mask,
      );
      await _applyMediaChanges(res, upsertedId ?? dbid);
      // Re-apply visuals only if the edited sentence belongs to the
      // chapter currently rendered in this reader instance. EPUB rows
      // from other chapters / books get the new visual on next open.
      if (row.surface == 'epub' && row.locator == _tagLocator) {
        await _installTagHelpersAndRehydrate();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved. Visual update will appear next time the page is open.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _setEpubMasksVisible(bool active) async {
    setState(() => _tagMasksVisible = active);
    await _controller?.runJavaScript(
      'window.__cupitorSetMasksVisible && window.__cupitorSetMasksVisible($active);',
    );
    final p = await SharedPreferences.getInstance();
    await p.setBool(ProfileService.masksKey('epub', ProfileService.currentId), active);
  }

  Future<void> _setEpubTransformsEnabled(bool active) async {
    setState(() => _tagTransformsEnabled = active);
    // Flip the runtime flag and either apply or revert. On revert the
    // JS restores every .cup-sent's data-cupitor-orig snapshot; on
    // apply it walks the sentences again — cheap since we only pay
    // for the ones that match a rule.
    final applyCall = active
        ? 'window.__cupitorApplyTextTransforms && window.__cupitorApplyTextTransforms();'
        : 'window.__cupitorRevertTextTransforms && window.__cupitorRevertTextTransforms();';
    await _controller?.runJavaScript(
      'window.__cupitorTransformsEnabled = $active;$applyCall',
    );
    final p = await SharedPreferences.getInstance();
    await p.setBool('tagXformEnabled:epub:${ProfileService.currentId}', active);
  }

  Future<void> _setEpubShowMaskImages(bool active) async {
    setState(() => _tagShowMaskImages = active);
    await _controller?.runJavaScript(
      'window.__cupitorShowMaskImages = $active;'
      'window.__cupitorRefreshMaskInjections && window.__cupitorRefreshMaskInjections();',
    );
    final p = await SharedPreferences.getInstance();
    await p.setBool('tagMaskImages:epub:${ProfileService.currentId}', active);
  }

  void _openEpubTagBrowser() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TagBrowserScreen(
        currentSurface: 'epub',
        currentLocator: _tagLocator,
        onNavigate: (locator) {
          // Switch to the chapter the row belongs to when it's another
          // chapter of THIS book. Cross-book / web rows aren't navigable
          // from inside the reader — user is told to open the main app.
          if (locator.startsWith('epub:')) {
            final parts = locator.split(':');
            if (parts.length == 3 && parts[1] == book.key) {
              final idx = int.tryParse(parts[2]);
              if (idx != null && idx >= 0 && idx < book.chapters.length) {
                Navigator.of(context).pop();
                _loadChapter(idx);
                return;
              }
            }
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('That row is from a different book')),
            );
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(
              'Web pages open from the main webview. Close the book first.',
            )),
          );
        },
        onEdit: (dbid) => _openEpubEditSheetForDbId(dbid),
      ),
    ));
  }

  void _showJsLogs() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: const Text('EPUB JS logs'),
          actions: [
            ValueListenableBuilder<bool>(
              valueListenable: JsLogSink.verbose,
              builder: (_, on, __) => Row(
                children: [
                  const Text('Verbose', style: TextStyle(fontSize: 12)),
                  Switch(
                    value: on,
                    onChanged: (v) {
                      JsLogSink.verbose.value = v;
                      _controller?.runJavaScript(
                        'window.__cupitorVerbose = ${v ? 'true' : 'false'};',
                      );
                    },
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy_all),
              tooltip: 'Copy all',
              onPressed: () async {
                final text = JsLogSink.entries.join('\n');
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Copied ${JsLogSink.entries.length} lines')),
                  );
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear',
              onPressed: () => JsLogSink.clear(),
            ),
          ],
        ),
        body: SafeArea(
          child: ValueListenableBuilder<int>(
            valueListenable: JsLogSink.version,
            builder: (_, __, ___) {
              final entries = JsLogSink.entries;
              if (entries.isEmpty) {
                return const Center(child: Text('No logs yet'));
              }
              return ListView.builder(
                reverse: true,
                itemCount: entries.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: SelectableText(
                    entries[entries.length - 1 - i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ));
  }

  Future<void> _openEpubTagSettingsSheet() async {
    if (!_tagDbReady) return;
    await showTagSettingsSheet(
      context: context,
      initial: TagSettingsValues(
        dbReady: _tagDbReady,
        captureChipVisible: _tagCaptureToggleVisible,
        masksVisible: _tagMasksVisible,
        filterTagIds: _tagFilterTagIds,
        segmentationScope: 'block',
        // EPUB uses pre-segmented .cup-sent spans — the page-wide
        // scope concept doesn't apply, so hide that section.
        showSegmentation: false,
        transformsEnabled: _tagTransformsEnabled,
        showMaskImages: _tagShowMaskImages,
        showMaskImagesOption: true,
        playlistChipVisible: _playlistChipVisible,
        showPlaylistSection: true,
      ),
      callbacks: TagSettingsCallbacks(
        onSetCaptureChipVisible: (_) => _toggleTagCaptureChipVisibility(),
        onSetMasksVisible: (v) => _setEpubMasksVisible(v),
        onSetTransformsEnabled: (v) => _setEpubTransformsEnabled(v),
        onSetShowMaskImages: (v) => _setEpubShowMaskImages(v),
        onSetPlaylistChipVisible: (v) {
          if (v != _playlistChipVisible) _togglePlaylistChipVisibility();
        },
        onOpenPlaylistScreen: () {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const PlaylistScreen(),
          ));
        },
        onExportBook: _exportCurrentBook,
        onOpenMemoryManager: () {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const MemoryManagerScreen(),
          ));
        },
        onOpenNotificationManager: () {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const NotificationManagerScreen(),
          ));
        },
        onOpenFilterSheet: () async {
          final pid = ProfileService.currentId;
          final r = await showTagFilterSheet(
            context: context, initial: _tagFilterTagIds, profileId: pid,
          );
          if (r == null) return null;
          setState(() => _tagFilterTagIds = r);
          await _controller?.runJavaScript(
            "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(r.toList()))});",
          );
          final p = await SharedPreferences.getInstance();
          await p.setStringList(
            ProfileService.filterKey('epub', pid),
            r.map((e) => e.toString()).toList(),
          );
          return r;
        },
        onApplyFilter: (s) async {
          setState(() => _tagFilterTagIds = s);
          await _controller?.runJavaScript(
            "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(s.toList()))});",
          );
          final p = await SharedPreferences.getInstance();
          await p.setStringList(
            ProfileService.filterKey('epub', ProfileService.currentId),
            s.map((e) => e.toString()).toList(),
          );
        },
        onSetSegmentationScope: (_) {},
        onOpenBrowser: _openEpubTagBrowser,
      ),
    );
  }

  Future<ExtendResult> _requestTagExtend(String sid, String direction) {
    if (_pendingTagExtend != null && !_pendingTagExtend!.isCompleted) {
      _pendingTagExtend!.complete(const ExtendResult(text: null, prevFp: '', nextFp: ''));
    }
    final c = Completer<ExtendResult>();
    _pendingTagExtend = c;
    _controller?.runJavaScript(
      "window.__cupitorRequestExtend && window.__cupitorRequestExtend('$sid','$direction');",
    );
    Future.delayed(const Duration(seconds: 3), () {
      if (!c.isCompleted) {
        c.complete(const ExtendResult(text: null, prevFp: '', nextFp: ''));
        _pendingTagExtend = null;
      }
    });
    return c.future;
  }

  Future<void> _openTagCaptureSheet({
    required String sid,
    required String text,
    required String prevFp,
    required String nextFp,
  }) async {
    if (!_tagDbReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tag DB not ready yet — try again in a moment')),
        );
      }
      return;
    }
    final profileId = ProfileService.currentId;
    final res = await showTagCaptureSheet(
      context: context,
      initial: CapturePayload(sentenceId: sid, text: text, prevFp: prevFp, nextFp: nextFp),
      profileId: profileId,
      surface: 'epub',
      locator: _tagLocator,
      onExtendRequested: (d) => _requestTagExtend(sid, d),
    );
    if (res == null) {
      _controller?.runJavaScript(
        "window.__cupitorClearTempHighlight && window.__cupitorClearTempHighlight('$sid');",
      );
      return;
    }
    try {
      final dbid = await CupitorDb.instance.upsertSentenceWithTags(
        profileId: profileId,
        surface: 'epub',
        locator: _tagLocator,
        title: '${book.title} — ${book.chapters[_state.chapterIdx].title}',
        text: res.text,
        prevFp: res.prevFp.isEmpty ? null : res.prevFp,
        nextFp: res.nextFp.isEmpty ? null : res.nextFp,
        tagIds: res.tagIds,
        mask: res.mask,
      );
      if (dbid != null) await _applyMediaChanges(res, dbid);
      final tags = await CupitorDb.instance.listTags(profileId);
      final colors = res.tagIds
          .map((id) => tags.firstWhere((t) => t.id == id,
              orElse: () => TagRow(id: 0, profileId: profileId, name: '', color: '#FFC107')))
          .where((t) => t.id != 0)
          .map((t) => t.color)
          .toList();
      final tagIdsCsv = res.tagIds.join(',');
      await _controller?.runJavaScript(
        "window.__cupitorCommitTags && window.__cupitorCommitTags('$sid', ${dbid ?? 'null'}, ${jsonEncode(jsonEncode(colors))}, ${jsonEncode(tagIdsCsv)}, ${jsonEncode(res.mask)});",
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _showEpubTagFilterSheet() async {
    if (!_tagDbReady) return;
    final pid = ProfileService.currentId;
    final result = await showTagFilterSheet(
      context: context, initial: _tagFilterTagIds, profileId: pid,
    );
    if (result == null) return;
    setState(() => _tagFilterTagIds = result);
    await _controller?.runJavaScript(
      "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(result.toList()))});",
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      ProfileService.filterKey('epub', pid),
      result.map((e) => e.toString()).toList(),
    );
  }

  void _onTagCaptureChipTap() {
    setState(() => _tagCaptureArmed = !_tagCaptureArmed);
    _controller?.runJavaScript(
      'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(${_tagCaptureArmed ? 'true' : 'false'});',
    );
  }

  void _toggleTagCaptureChipVisibility() {
    setState(() {
      _tagCaptureToggleVisible = !_tagCaptureToggleVisible;
      if (!_tagCaptureToggleVisible) _tagCaptureArmed = false;
    });
    _controller?.runJavaScript(
      'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(${_tagCaptureArmed ? 'true' : 'false'});',
    );
  }

  Future<void> _onPlaylistChipTap() async {
    // Arming without an active playlist would silently drop taps. If
    // none exists, prompt the user to create one — same flow as
    // opening the playlist screen and hitting +.
    if (!_playlistCaptureArmed && PlaylistService.activeId.value == null) {
      await _ensurePlaylistExists();
      if (PlaylistService.activeId.value == null) return;
    }
    setState(() => _playlistCaptureArmed = !_playlistCaptureArmed);
    _controller?.runJavaScript(
      'window.__cupitorPlaylistCaptureMode = $_playlistCaptureArmed;'
      // Playlist capture reuses the tag-tap gate on the JS side (any
      // touch on a .cup-sent posts through SentenceTagHandler), so we
      // also need __cupitorCaptureMode to be on for the handler to
      // fire. Turn it on when arming and remember to leave the tag
      // arm state alone.
      '${_playlistCaptureArmed ? 'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(true);' : ''}',
    );
  }

  void _togglePlaylistChipVisibility() {
    setState(() {
      _playlistChipVisible = !_playlistChipVisible;
      if (!_playlistChipVisible) _playlistCaptureArmed = false;
    });
    _controller?.runJavaScript(
      'window.__cupitorPlaylistCaptureMode = $_playlistCaptureArmed;',
    );
  }

  /// One-shot bundle-and-save for the currently-open book. Builds the
  /// zip in memory (no on-disk copy retained) and offers the user a
  /// native "save to" dialog so they can drop it wherever they want.
  /// Any DB / IO error is surfaced via a SnackBar.
  Future<void> _exportCurrentBook() async {
    if (!mounted) return;
    final file = File(book.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('EPUB file missing: ${book.filePath}')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Exporting book…')),
    );
    try {
      final bytes = await BookExporter.buildBundle(
        bookKey: book.key,
        epubFile: file,
      );
      final suggestedName = await BookExporter.defaultFileNameForBook(book.key);
      if (!mounted) return;
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Cupitor bundle',
        fileName: suggestedName,
        bytes: bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          savedPath == null
              ? 'Export cancelled'
              : 'Exported: $savedPath',
        )),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  Future<void> _ensurePlaylistExists() async {
    final playlists = await CupitorDb.instance.listPlaylists();
    if (playlists.isNotEmpty) {
      // At least one exists — pick the first if nothing's active.
      if (PlaylistService.activeId.value == null) {
        await PlaylistService.setActive(playlists.first.id);
      }
      return;
    }
    if (!mounted) return;
    final ctrl = TextEditingController(text: 'My playlist');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create playlist'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await PlaylistService.createPlaylist(name.trim());
  }

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

  /// Deep-link highlight: opens the find bar with [q] pre-filled and
  /// scrolls the first match into view. Called exactly once, right
  /// after the initial chapter finishes loading.
  ///
  /// Global search queries can carry an OR (`a|b`) — the find bar
  /// takes a single phrase, so we split and use the first, which is
  /// enough to jump the user to a hit in this chapter (the exact
  /// snippet that matched is guaranteed to contain at least the first
  /// phrase for hits selected from a `phrase|…` query).
  void _applyInitialHighlight(String q) {
    final firstPhrase = q.split('|').first.trim();
    if (firstPhrase.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _findBarVisible = true;
      _findController.text = firstPhrase;
    });
    _findInChapter(firstPhrase);
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
    // Neutralize any <script> blocks the book ships. EPUBs are XHTML;
    // an unclosed or syntactically-broken book script propagates into
    // the surrounding document and prevents our own <script> from
    // running. We rewrite the opening tag so the HTML parser treats it
    // as a custom element (treated as plain text content), and do the
    // same for the close to keep matched balance.
    var chapterHtml = ch.html
        .replaceAll(RegExp(r'<script\b', caseSensitive: false), '<x-script ')
        .replaceAll(RegExp(r'</script\s*>', caseSensitive: false), '</x-script>');
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
  /* Find-in-chapter highlight. Underline (not just a background tint) so
     it stays visible on eink and high-contrast themes AND when the hit
     lands inside a tagged span — saved highlights (.cup-hl*), the
     current-speaking sentence (.cup-sent-current), or a has-note
     sentence (which draws its own bottom line via box-shadow).
     • !important guards against parent-inherited text-decoration.
     • #d32f2f (crimson) doesn't collide with the yellow/green/pink/blue
       saved-highlight palette.
     • Solid style + a background tint on current-step keeps Prev/Next
       distinct from the other hits. */
  .cup-find-hit {
    text-decoration: underline solid #d32f2f !important;
    text-decoration-thickness: 2px !important;
    text-underline-offset: 2px;
    background: rgba(255, 215, 0, .45);
    border-radius: 2px;
  }
  .cup-find-current {
    text-decoration: underline solid #b71c1c !important;
    text-decoration-thickness: 3px !important;
    text-underline-offset: 2px;
    background: rgba(255, 140, 0, .8);
    color: #000;
  }
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
  /* Paginated mode: turn the body into a horizontally-scrolling column
     stream. Each column is one "page"; scroll-snap makes swipes feel
     natural. We override y-overflow so internal scrolling within the
     chapter is taken over by the page system instead.
     `column-gap` + `column-rule` render a visible book-style gutter
     between adjacent pages so the user can see one page end and the
     next begin during a swipe. The rule colour is semi-transparent
     neutral grey so it reads on any theme background. */
  body.cup-paginated {
    column-width: 100vw;
    column-gap: 40px;
    column-rule: 1px solid rgba(128, 128, 128, 0.28);
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
<script>
// Bootstrap script — runs before the book HTML so we can catch syntax
// errors in either the book's inline scripts or our own main script.
(function(){
  try {
    var b = window.CupEpub;
    if (b) b.postMessage(JSON.stringify({type:'log', msg:'[epub] bootstrap ran, bridges='
      + ' CupEpub=' + (typeof window.CupEpub)
      + ' SentenceTag=' + (typeof window.SentenceTagHandler)
      + ' SnippetLog=' + (typeof window.SnippetLogChannel)
    }));
    window.onerror = function(msg, src, line, col) {
      try {
        if (b) b.postMessage(JSON.stringify({
          type:'log',
          msg:'[epub] window.onerror: ' + msg + ' @ ' + src + ':' + line + ':' + col
        }));
        // Defer until DOM is ready so documentElement.outerHTML exists.
        setTimeout(function(){
          try {
            var html = document.documentElement ? document.documentElement.outerHTML : '';
            var lines = html.split('\\n');
            var lo = Math.max(0, line - 4);
            var hi = Math.min(lines.length, line + 3);
            for (var i = lo; i < hi; i++) {
              if (b) b.postMessage(JSON.stringify({
                type:'log',
                msg:'[epub:src ' + (i+1) + '] ' + lines[i].slice(0, 200)
              }));
            }
          } catch(e2) {
            if (b) b.postMessage(JSON.stringify({
              type:'log', msg:'[epub] dump failed: ' + e2
            }));
          }
        }, 50);
      } catch(e) {}
      return false;
    };
  } catch(e) {}
})();
</script>
$chapterHtml
<script>
(function() {
  var bridge = window.CupEpub;
  function post(o) { if (bridge) bridge.postMessage(JSON.stringify(o)); }
  function dlog(s) { post({ type: 'log', msg: s }); }
  function vlog(s) { if (window.__cupitorVerbose) dlog(s); }
  dlog('[epub] chapter script start, hasBridge=' + !!bridge
      + ' SnippetLog=' + (typeof window.SnippetLogChannel)
      + ' SentenceTag=' + (typeof window.SentenceTagHandler));
  window.addEventListener('error', function(e) {
    dlog('[epub] window.onerror: ' + (e && e.message ? e.message : 'unknown')
       + ' @ ' + (e && e.filename ? e.filename : '?') + ':' + (e && e.lineno ? e.lineno : '?'));
  });

  // ── Scroll progress (throttled) ──
  // `programmaticScrollUntil` gates the boundary check so a
  // `__cupEpubRestoreScroll(1.0)` (used when the host navigates BACK
  // to a chapter and wants to land where the user last was) doesn't
  // immediately fire `navEnd` and bounce the reader forward again. We
  // require a genuine user gesture — touchstart/wheel/keydown clears
  // the gate — before treating "at the bottom" as an intent to move
  // to the next chapter.
  var lastSent = 0;
  var programmaticScrollUntil = 0;
  window.addEventListener('scroll', function() {
    var now = Date.now();
    if (now - lastSent < 400) return;
    lastSent = now;
    var h = document.documentElement.scrollHeight - window.innerHeight;
    var pct = h > 0 ? (window.scrollY / h) : 0;
    post({ type: 'scroll', pct: pct });
    // Bottom of the chapter → host can advance. Suppressed briefly
    // after a programmatic scroll (see `__cupEpubRestoreScroll`).
    if (now < programmaticScrollUntil) return;
    if (h > 0 && (h - window.scrollY) < 4) post({ type: 'navEnd' });
  }, { passive: true });
  // Any real user interaction clears the programmatic-scroll gate
  // early — no need to wait out the full 1.5 s window if the user
  // has already put a finger down.
  var _clearProgrammaticGate = function() { programmaticScrollUntil = 0; };
  window.addEventListener('touchstart', _clearProgrammaticGate, { passive: true });
  window.addEventListener('wheel', _clearProgrammaticGate, { passive: true });
  window.addEventListener('keydown', _clearProgrammaticGate, { passive: true });

  // ── Restore scroll on chapter load ──
  window.__cupEpubRestoreScroll = function(pct) {
    var h = document.documentElement.scrollHeight - window.innerHeight;
    if (h > 0) window.scrollTo(0, Math.max(0, Math.floor(h * pct)));
    // Safety cap on the boundary suppression in case no touchstart /
    // wheel / keydown ever comes (e.g. Mac trackpad edge cases).
    programmaticScrollUntil = Date.now() + 1500;
  };

  // ── Word tap → lookup ──
  // We use caretRangeFromPoint to find the word the user actually tapped.
  // Tap-and-drag is treated as a selection (handled below). Plain text
  // inside <a>, <img>, <button> is left alone — the original anchor still
  // wins. The flash class gives visual feedback that the tap was caught.
  function isWordChar(c) { return /[\\p{L}\\p{M}\\p{N}'’-]/u.test(c); }
  // caretRangeFromPoint can resolve to an element node (the .cup-sent
  // span) instead of its text child — common when sentences are wrapped
  // for TTS / tagging. Descend to the off'th child's text content when
  // that happens so the rest of the lookup chain has something to work
  // with.
  function resolveTextNode(node, off) {
    if (!node) return { node: null, off: 0 };
    if (node.nodeType === 3) return { node: node, off: off };
    if (node.nodeType === 1) {
      // off indexes into childNodes; clamp and walk down to first text.
      var child = node.childNodes[Math.min(off, node.childNodes.length - 1)];
      if (!child) child = node.firstChild;
      while (child && child.nodeType !== 3) {
        child = child.firstChild;
      }
      if (child && child.nodeType === 3) return { node: child, off: 0 };
    }
    return { node: null, off: 0 };
  }
  function wordAt(node, off) {
    var r = resolveTextNode(node, off);
    if (!r.node) return null;
    var t = r.node.data || '';
    var s = r.off, e = r.off;
    while (s > 0 && isWordChar(t[s - 1])) s--;
    while (e < t.length && isWordChar(t[e])) e++;
    if (e === s) return null;
    // Text-transform rules wrap changed substrings in child spans
    // (e.g. "afton" → text "ton" + <span>"av"</span>), so tapping the
    // wrapped fragment lands us in a text node whose .data is only
    // that fragment. If the extracted word touches either edge of the
    // local text, walk the block's flattened text across siblings so
    // the lookup gets the full visible token, not a piece of it.
    if (s === 0 || e === t.length) {
      var block = r.node.parentNode;
      while (block && block.tagName
             && /^(SPAN|B|I|EM|STRONG|A|U|MARK|SUB|SUP|SMALL|CODE)\$/i.test(block.tagName)) {
        block = block.parentNode;
      }
      if (block) {
        var flat = block.textContent || '';
        var running = 0, offsetInFlat = -1;
        var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null, false);
        var nn;
        while ((nn = walker.nextNode())) {
          if (nn === r.node) { offsetInFlat = running; break; }
          running += (nn.data || '').length;
        }
        if (offsetInFlat >= 0) {
          var fs = offsetInFlat + s;
          var fe = offsetInFlat + e;
          while (fs > 0 && isWordChar(flat[fs - 1])) fs--;
          while (fe < flat.length && isWordChar(flat[fe])) fe++;
          if (fe > fs) {
            return { word: flat.substring(fs, fe), start: s, end: e, node: r.node };
          }
        }
      }
    }
    return { word: t.substring(s, e), start: s, end: e, node: r.node };
  }

  // Line-wrap hyphenation: when the EPUB has "trans-\\nlation" or "well- known"
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

  // ── Horizontal swipe → prev/next chapter ──
  // Skipped in paginated mode (browser scroll-snap handles page turns
  // natively; end-of-chapter still routes through navStart/navEnd).
  // Skipped when a text selection exists, capture mode is armed, or
  // more than one touch is down (pinch/zoom). Threshold: 60 px of
  // horizontal travel, mostly horizontal (dx >= 1.5 * dy), completed
  // in under 800 ms — same envelope users get from a natural page-turn
  // flick without hijacking accidental drags.
  var swipeStartX = 0, swipeStartY = 0, swipeStartTs = 0, swipeMulti = false;
  document.addEventListener('touchstart', function(ev) {
    if (ev.touches && ev.touches.length > 1) { swipeMulti = true; return; }
    swipeMulti = false;
    if (ev.touches && ev.touches[0]) {
      swipeStartX = ev.touches[0].clientX;
      swipeStartY = ev.touches[0].clientY;
      swipeStartTs = Date.now();
    }
  }, { passive: true });
  document.addEventListener('touchend', function(ev) {
    if (swipeMulti) { swipeMulti = false; return; }
    if (document.body.classList.contains('cup-paginated')) return;
    if (window.__cupitorCaptureMode) return;
    if (window.__cupitorPlaylistCaptureMode) return;
    var sel = window.getSelection();
    if (sel && sel.toString().trim().length > 0) return;
    var t = ev.changedTouches && ev.changedTouches[0];
    if (!t) return;
    var dx = t.clientX - swipeStartX;
    var dy = t.clientY - swipeStartY;
    var dt = Date.now() - swipeStartTs;
    if (dt > 800) return;
    var adx = Math.abs(dx), ady = Math.abs(dy);
    if (adx < 60) return;
    if (adx < ady * 1.5) return;
    if (dx < 0) post({ type: 'swipeLeft' });
    else post({ type: 'swipeRight' });
  }, { passive: true });
  document.addEventListener('click', function(ev) {
    var t = ev.target;
    var tn = (t && t.tagName) ? t.tagName : '?';
    var inSent = !!(t && t.closest && t.closest('.cup-sent'));
    vlog('[epub] click target=' + tn + ' inSent=' + inSent
        + ' capMode=' + (!!window.__cupitorCaptureMode)
        + ' hasEpubTap=' + (typeof window.__cupitorOnEpubSentenceTap));
    // Sentence-tag capture mode: route taps to the tagging helpers
    // (defined by the post-load injection) and swallow the rest. Lookup
    // is suppressed until the user disarms capture on the floating chip.
    if (window.__cupitorCaptureMode && window.__cupitorOnEpubSentenceTap) {
      if (window.__cupitorOnEpubSentenceTap(ev)) return;
    }
    // Ignore taps that hit interactive elements that should keep their
    // native behaviour. Anchors are tricky: many EPUBs (litteraturbanken
    // among them) wrap individual words in <a> tags as a structural
    // hook. Bail only when the anchor has a real href so plain wrapper
    // anchors still route to lookup.
    var tgt = ev.target;
    var hit = tgt && tgt.closest && tgt.closest('button, img, input, textarea, select');
    if (hit) { vlog('[epub] lookup early-exit: closest=' + hit.tagName + '.' + (hit.className || '')); return; }
    var anchor = tgt && tgt.closest && tgt.closest('a');
    if (anchor) {
      var href = anchor.getAttribute('href') || '';
      if (href.length > 0) { vlog('[epub] lookup early-exit: anchor href=' + href.slice(0, 60)); return; }
    }
    // Ignore if the user selected text — that goes through the selection
    // hook instead.
    var sel = window.getSelection();
    var selText = sel ? sel.toString() : '';
    if (selText && selText.trim().length > 0) { vlog('[epub] lookup early-exit: selection=' + selText.slice(0, 40)); return; }
    var x = ev.clientX || lastTouchX;
    var y = ev.clientY || lastTouchY;
    var range;
    if (document.caretRangeFromPoint) {
      range = document.caretRangeFromPoint(x, y);
    } else if (document.caretPositionFromPoint) {
      var p = document.caretPositionFromPoint(x, y);
      if (p) { range = document.createRange(); range.setStart(p.offsetNode, p.offset); range.collapse(true); }
    }
    vlog('[epub] lookup: x=' + x + ' y=' + y + ' rangeOk=' + !!range
        + (range ? ' container=' + (range.startContainer.nodeType === 3 ? 'text' : (range.startContainer.tagName || '?'))
                  + ' off=' + range.startOffset : ''));
    if (!range) { post({ type: 'tapBackground' }); return; }
    var w = wordAt(range.startContainer, range.startOffset);
    vlog('[epub] lookup: wordAt=' + (w ? w.word : 'null'));
    if (!w) { post({ type: 'tapBackground' }); return; }
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
            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: einkMode,
                builder: (_, eink, child) => ColorFiltered(
                  colorFilter: eink ? einkColorFilter : identityColorFilter,
                  child: child,
                ),
                child: WebViewWidget(controller: _controller!),
              ),
            ),
            if (_chromeVisible) ...[
              Positioned(top: 0, left: 0, right: 0, child: _buildTopBar(theme)),
              if (_findBarVisible)
                Positioned(top: 56, left: 0, right: 0, child: _buildFindBar(theme)),
              Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar(theme, progress)),
            ],
            if (_bookSearchVisible) Positioned.fill(child: _buildBookSearchOverlay(theme)),
            if (_selectionAnchor != null) _buildSelectionMenu(theme),
            if (_tagCaptureToggleVisible)
              TagCaptureFloatingChip(
                armed: _tagCaptureArmed,
                initialPos: _tagCaptureChipPos,
                onTap: _onTagCaptureChipTap,
                onHide: _toggleTagCaptureChipVisibility,
                onMoved: (p) => _tagCaptureChipPos = p,
              ),
            if (_playlistChipVisible)
              TagCaptureFloatingChip(
                armed: _playlistCaptureArmed,
                initialPos: _playlistChipPos,
                onTap: _onPlaylistChipTap,
                onHide: _togglePlaylistChipVisibility,
                onMoved: (p) => _playlistChipPos = p,
                armedIcon: Icons.playlist_add_check,
                idleIcon: Icons.playlist_add,
                armedColor: Colors.deepPurple,
                armedBorderColor: const Color(0xFF311B92),
              ),
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
            if (_tagDbReady)
              IconButton(
                icon: const Icon(Icons.label_outline),
                color: theme.chromeFg,
                tooltip: 'Tag sentences',
                onPressed: _openEpubTagSettingsSheet,
              ),
            IconButton(
              icon: Icon(_currentChapterBookmarked() ? Icons.bookmark : Icons.bookmark_border),
              color: theme.chromeFg,
              tooltip: 'Bookmark',
              onPressed: _toggleBookmark,
            ),
            IconButton(
              icon: const Icon(Icons.list_alt),
              color: theme.chromeFg,
              tooltip: 'Table of contents',
              onPressed: _showTocSheet,
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: Icon(Icons.more_vert, color: theme.chromeFg),
              onSelected: (key) {
                switch (key) {
                  case 'lookup':
                    widget.onLookup('', '');
                    break;
                  case 'browse-tags':
                    if (_tagDbReady) _openEpubTagBrowser();
                    break;
                  case 'search-book':
                    setState(() => _bookSearchVisible = true);
                    break;
                  case 'find-chapter':
                    setState(() => _findBarVisible = !_findBarVisible);
                    if (!_findBarVisible) {
                      _findController.clear();
                      _findInChapter('');
                    }
                    break;
                  case 'theme':
                    _showSettingsSheet();
                    break;
                  case 'logs':
                    _showJsLogs();
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'lookup',
                  child: ListTile(leading: Icon(Icons.travel_explore), title: Text('Open lookup dialog')),
                ),
                if (_tagDbReady)
                  const PopupMenuItem(
                    value: 'browse-tags',
                    child: ListTile(leading: Icon(Icons.collections_bookmark_outlined), title: Text('Browse tagged sentences')),
                  ),
                const PopupMenuItem(
                  value: 'search-book',
                  child: ListTile(leading: Icon(Icons.search), title: Text('Search in book')),
                ),
                const PopupMenuItem(
                  value: 'find-chapter',
                  child: ListTile(leading: Icon(Icons.find_in_page), title: Text('Find in chapter')),
                ),
                const PopupMenuItem(
                  value: 'theme',
                  child: ListTile(leading: Icon(Icons.format_size), title: Text('Text & theme')),
                ),
                const PopupMenuItem(
                  value: 'logs',
                  child: ListTile(leading: Icon(Icons.bug_report_outlined), title: Text('JS logs')),
                ),
              ],
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
    _chromeHideTimer?.cancel();
    ProfileService.active.removeListener(_onProfileChanged);
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

// ─── Playlist capture mini-sheet ────────────────────────────────────
// Small bottom sheet shown after a tap in playlist-capture mode. Lets
// the user extend the range via Prev/Next, trim it via Drop first /
// Drop last, then Save to append one card to the active playlist.
// Mirrors the tag-capture sheet's extend flow but drops tags / mask /
// media / dictation — playlist cards are text + book/chapter labels.

class _PlaylistCaptureResult {
  final String text;
  const _PlaylistCaptureResult({required this.text});
}

class _PlaylistCaptureSheet extends StatefulWidget {
  final String initialText;
  final Future<ExtendResult> Function(String direction) onExtendRequested;
  const _PlaylistCaptureSheet({
    required this.initialText,
    required this.onExtendRequested,
  });

  @override
  State<_PlaylistCaptureSheet> createState() => _PlaylistCaptureSheetState();
}

class _PlaylistCaptureSheetState extends State<_PlaylistCaptureSheet> {
  late String _text;
  bool _prevAvailable = true;
  bool _nextAvailable = true;
  // Bumped on Prev/Next, decremented on Drop first/last. Trim buttons
  // are gated on this being > 1 — a single sentence can't be trimmed.
  int _rangeSize = 1;
  bool _busy = false;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _text = widget.initialText;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _extend(String direction) async {
    if (_busy) return;
    setState(() => _busy = true);
    final res = await widget.onExtendRequested(direction);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.text == null) {
        // Boundary hit — grey the button that fired.
        if (direction == 'prev') _prevAvailable = false;
        if (direction == 'next') _nextAvailable = false;
      } else {
        _text = res.text!;
        _rangeSize += 1;
        // Reaching a new sentence on one end un-greys the opposite
        // boundary if it had previously fired.
        if (direction == 'prev') _nextAvailable = true;
        if (direction == 'next') _prevAvailable = true;
      }
    });
    _scrollToEnd();
  }

  Future<void> _trim(String side) async {
    if (_busy || _rangeSize <= 1) return;
    setState(() => _busy = true);
    final direction = side == 'start' ? 'trimStart' : 'trimEnd';
    final res = await widget.onExtendRequested(direction);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.text != null) {
        _text = res.text!;
        _rangeSize = (_rangeSize - 1).clamp(1, 1 << 30);
        // A trim always un-greys the opposite boundary — even if we
        // hit it earlier, the shrunk range makes further extension
        // valid again.
        _prevAvailable = true;
        _nextAvailable = true;
      }
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.playlist_add, size: 20),
                  const SizedBox(width: 8),
                  Text('Add to playlist', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  ValueListenableBuilder<int?>(
                    valueListenable: PlaylistService.activeId,
                    builder: (_, id, __) => Text(
                      '$_rangeSize selected',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Captured range preview. Bounded height so a long
              // selection scrolls instead of pushing the buttons
              // off-screen.
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(10),
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: SelectableText(
                      _text,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (!_busy && _prevAvailable) ? () => _extend('prev') : null,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Prev'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (!_busy && _nextAvailable) ? () => _extend('next') : null,
                      icon: const Icon(Icons.arrow_forward, size: 18),
                      label: const Text('Next'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (!_busy && _rangeSize > 1) ? () => _trim('start') : null,
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      label: const Text('Drop first'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (!_busy && _rangeSize > 1) ? () => _trim('end') : null,
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      label: const Text('Drop last'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(_PlaylistCaptureResult(text: _text)),
                    icon: const Icon(Icons.playlist_add_check),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

