import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'epub_reader.dart' show EpubLibrary, EpubLibraryEntry;
import 'media_store.dart';

/// Bundle an EPUB with everything Cupitor knows about it — the book
/// file, reading state, every profile's tags/sentences/media rows,
/// playlists — into a portable `.cupitor.zip`. The other side
/// ([BookImporter]) restores it into a fresh install or a different
/// device. All profiles round-trip so a device swap doesn't lose the
/// per-profile split.
///
/// Layout of the zip:
///   book.epub            # untouched bytes of the original file
///   manifest.json        # everything else, versioned
///   media/[sha1].[ext]   # every referenced local media attachment
class BookExporter {
  BookExporter._();

  /// Format version. Bumped to 2 when the manifest gained a `profiles`
  /// array so all profiles round-trip. v1 bundles (single profile,
  /// tags/sentences/media at the manifest root) are refused — they
  /// only existed during the feature's initial rollout.
  static const int _kVersion = 2;

  /// Build a `.cupitor.zip` for [bookKey] entirely in memory and
  /// return the raw bytes. The caller hands them straight to
  /// file_picker's saveFile / a share sheet / anywhere else —
  /// nothing is retained on the local filesystem, so we don't leave a
  /// second copy behind after the user has picked their destination.
  static Future<Uint8List> buildBundle({
    required String bookKey,
    required File epubFile,
  }) async {
    final db = CupitorDb.instance;
    final archive = Archive();

    // 1. Book file itself. Zipped as-is — no re-parse.
    final epubBytes = await epubFile.readAsBytes();
    archive.addFile(ArchiveFile('book.epub', epubBytes.length, epubBytes));

    // 2. Prefs (reading state + mask locale).
    final prefs = await SharedPreferences.getInstance();
    final readingStateRaw = prefs.getString('epub_state_$bookKey');
    final maskLocaleRaw = prefs.getString('maskSpeechLocale:epub:epub:$bookKey');

    // 3. Library entry (title, author).
    final library = await EpubLibrary.load();
    final libEntry = library.entries.firstWhere(
      (e) => e.key == bookKey,
      orElse: () => EpubLibraryEntry(key: bookKey, path: epubFile.path, title: 'Untitled'),
    );

    // 4. Pages (shared across profiles) + per-profile sentences /
    //    tags / media, walked through the raw DB layer so we can
    //    pack local ids stably.
    final rawDb = await db.rawDb();
    if (rawDb == null) {
      throw StateError('DB not ready — export aborted');
    }
    final pages = await rawDb.query(
      'pages',
      where: 'surface = ? AND locator LIKE ?',
      whereArgs: ['epub', 'epub:$bookKey:%'],
    );
    final pageIds = pages.map((p) => p['id'] as int).toList(growable: false);

    // Track every SHA-1 we've packed so two profiles that share
    // content don't add the same bytes to the archive twice.
    final packedShas = <String>{};
    final profileBlocks = <Map<String, Object?>>[];
    final profiles = await db.listProfiles();

    for (final prof in profiles) {
      List<Map<String, Object?>> sentences = const [];
      List<Map<String, Object?>> sentenceTags = const [];
      List<Map<String, Object?>> media = const [];
      final tagsById = <int, TagRow>{};

      if (pageIds.isNotEmpty) {
        final placeholders = List.filled(pageIds.length, '?').join(',');
        sentences = await rawDb.query(
          'sentences',
          where: 'profile_id = ? AND page_id IN ($placeholders)',
          whereArgs: [prof.id, ...pageIds],
        );
        final sentenceIds = sentences.map((s) => s['id'] as int).toList(growable: false);
        if (sentenceIds.isNotEmpty) {
          final sph = List.filled(sentenceIds.length, '?').join(',');
          sentenceTags = await rawDb.query(
            'sentence_tags',
            where: 'sentence_id IN ($sph)',
            whereArgs: sentenceIds,
          );
          media = await rawDb.query(
            'sentence_media',
            where: 'sentence_id IN ($sph)',
            whereArgs: sentenceIds,
          );
          final tagIds = <int>{for (final st in sentenceTags) st['tag_id'] as int};
          if (tagIds.isNotEmpty) {
            final tph = List.filled(tagIds.length, '?').join(',');
            final tagRows = await rawDb.query(
              'tags',
              where: 'id IN ($tph)',
              whereArgs: tagIds.toList(),
            );
            for (final row in tagRows) {
              tagsById[row['id'] as int] = TagRow.fromMap(row);
            }
          }
        }
      }

      // Skip profiles that have nothing tagged for this book so the
      // manifest stays compact.
      if (sentences.isEmpty) continue;

      // Pack this profile's local media, dedup'd against packedShas.
      final packedMedia = <Map<String, Object?>>[];
      for (final m in media) {
        final url = m['url'] as String?;
        final sha1Hex = (m['sha1'] as String?) ?? '';
        final filename = (m['filename'] as String?) ?? '';
        if (url != null && url.isNotEmpty) {
          packedMedia.add({...m});
          continue;
        }
        if (sha1Hex.isEmpty) continue;
        final ext = _extOf(filename);
        if (!packedShas.contains(sha1Hex)) {
          final srcFile = await MediaStore.instance.resolve(sha1Hex, extension: ext);
          if (srcFile == null) continue;
          final bytes = await srcFile.readAsBytes();
          final zipPath = ext.isEmpty ? 'media/$sha1Hex' : 'media/$sha1Hex.$ext';
          archive.addFile(ArchiveFile(zipPath, bytes.length, bytes));
          packedShas.add(sha1Hex);
        }
        packedMedia.add({...m});
      }

      profileBlocks.add({
        'name': prof.name,
        'tags': [
          for (final t in tagsById.values)
            {'id': t.id, 'name': t.name, 'color': t.color},
        ],
        'sentences': sentences,
        'sentence_tags': sentenceTags,
        'media': packedMedia,
      });
    }

    // 5. Playlists that reference this book (playlists themselves are
    //    global, not profile-scoped).
    final playlistItems = await rawDb.query(
      'playlist_items',
      where: 'book_key = ?',
      whereArgs: [bookKey],
    );
    final playlistIds = <int>{
      for (final it in playlistItems) it['playlist_id'] as int,
    };
    List<Map<String, Object?>> playlistRows = const [];
    if (playlistIds.isNotEmpty) {
      final pph = List.filled(playlistIds.length, '?').join(',');
      playlistRows = await rawDb.query(
        'playlists',
        where: 'id IN ($pph)',
        whereArgs: playlistIds.toList(),
      );
    }

    // 6. Manifest.
    final manifest = <String, Object?>{
      'version': _kVersion,
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'book': {
        'key': bookKey,
        'title': libEntry.title,
        'author': libEntry.author,
      },
      'reading_state': readingStateRaw == null ? null : jsonDecode(readingStateRaw),
      'mask_locale': maskLocaleRaw,
      'pages': pages,
      'profiles': profileBlocks,
      'playlists': [
        for (final p in playlistRows)
          {
            'id': p['id'],
            'name': p['name'],
            'items': [
              for (final it in playlistItems)
                if (it['playlist_id'] == p['id']) it,
            ],
          },
      ],
    };
    final manifestJson = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', manifestJson.length, manifestJson));

    // 7. Encode. Kept fully in-memory — the caller ships these bytes
    //    straight to the OS save dialog and we never touch app_docs.
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null || encoded.isEmpty) {
      throw StateError('Zip encoding produced no bytes');
    }
    return Uint8List.fromList(encoded);
  }

  /// Slug of the book title — handy for suggesting a filename in the
  /// save dialog. Exposed as a small utility because the exporter no
  /// longer decides where the bundle lives on disk.
  static Future<String> defaultFileNameForBook(String bookKey) async {
    final library = await EpubLibrary.load();
    final entry = library.entries.firstWhere(
      (e) => e.key == bookKey,
      orElse: () => EpubLibraryEntry(key: bookKey, path: '', title: 'book'),
    );
    return '${_slugify(entry.title)}.cupitor.zip';
  }

  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String _slugify(String s) {
    final normalized = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (normalized.isEmpty) return 'book';
    return normalized.length > 60 ? normalized.substring(0, 60) : normalized;
  }
}

/// Restore a `.cupitor.zip` back into the DB + MediaStore + prefs +
/// library. Every profile in the bundle is restored; each is slotted
/// into a locally-matching profile by name (case-insensitive) or a
/// fresh one is created. If the book already lives on this device its
/// old data is wiped across all profiles first so the import replaces
/// the previous copy end-to-end.
class BookImporter {
  BookImporter._();

  static Future<BookImportResult> importBundle({
    required File zipFile,
  }) async {
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1. Manifest — everything else is validated against it.
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const FormatException('manifest.json missing — not a Cupitor bundle');
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>))
        as Map<String, dynamic>;
    final version = (manifest['version'] as num?)?.toInt() ?? 0;
    if (version != BookExporter._kVersion) {
      throw FormatException(
        'Unsupported bundle version $version — expected ${BookExporter._kVersion}. '
        'Re-export the book from the source device.',
      );
    }

    // 2. Book file — extract to app_docs/imported_epubs/<sha>.epub.
    //    Recompute the SHA so we don't trust the exporter's claim.
    final bookFile = archive.findFile('book.epub');
    if (bookFile == null) {
      throw const FormatException('book.epub missing from bundle');
    }
    final bookBytes = Uint8List.fromList(bookFile.content as List<int>);
    final freshKey = sha1.convert(bookBytes).toString();

    // 3. Replace semantics: if this device already knows this book,
    //    wipe its DB rows across every profile before re-inserting so
    //    the newest bundle wins cleanly. Media files that just went
    //    orphan get swept afterwards.
    final db = CupitorDb.instance;
    final library = await EpubLibrary.load();
    final alreadyKnown = library.entries.any((e) => e.key == freshKey);
    if (alreadyKnown) {
      await db.deleteBookData(
        profileId: CupitorDb.defaultProfileId, // param ignored — wipe is per-book
        bookKey: freshKey,
      );
      final referenced = await db.referencedFileSha1s();
      await MediaStore.instance.deleteOrphans(referenced);
    }

    // 4. Extract EPUB to disk (overwrites any prior copy at the same
    //    content-addressed path).
    final docs = await getApplicationDocumentsDirectory();
    final booksDir = Directory('${docs.path}/imported_epubs');
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    final epubDest = File('${booksDir.path}/$freshKey.epub');
    await epubDest.writeAsBytes(bookBytes, flush: true);

    // 5. Register in the library. `touch` removes any prior entry
    //    with this key and inserts the fresh one at the top.
    final bookMeta = (manifest['book'] as Map<String, dynamic>?) ?? const {};
    await library.touch(EpubLibraryEntry(
      key: freshKey,
      path: epubDest.path,
      title: (bookMeta['title'] as String?) ?? 'Untitled',
      author: bookMeta['author'] as String?,
    ));

    // 6. Prefs: reading state + mask locale. Overwrite existing.
    final prefs = await SharedPreferences.getInstance();
    final rs = manifest['reading_state'];
    if (rs is Map) {
      await prefs.setString('epub_state_$freshKey', jsonEncode(rs));
    }
    final maskLocale = manifest['mask_locale'] as String?;
    if (maskLocale != null) {
      await prefs.setString('maskSpeechLocale:epub:epub:$freshKey', maskLocale);
    }

    // 7. DB inserts.
    final rawDb = await db.rawDb();
    if (rawDb == null) {
      throw StateError('DB not ready — import aborted');
    }
    final now = DateTime.now().millisecondsSinceEpoch;

    // Pages: rewrite locator prefix from the bundle's book key to the
    // fresh key. Upsert by (surface, locator).
    final srcBookKey = (bookMeta['key'] as String?) ?? '';
    final pageIdMap = <int, int>{};
    for (final p in (manifest['pages'] as List? ?? const [])) {
      final srcId = (p['id'] as num).toInt();
      final srcLocator = (p['locator'] as String?) ?? '';
      final newLocator = srcBookKey.isNotEmpty && srcLocator.startsWith('epub:$srcBookKey:')
          ? srcLocator.replaceFirst('epub:$srcBookKey:', 'epub:$freshKey:')
          : srcLocator;
      final existing = await rawDb.query(
        'pages',
        where: 'surface = ? AND locator = ?',
        whereArgs: ['epub', newLocator],
        limit: 1,
      );
      final localId = existing.isNotEmpty
          ? existing.first['id'] as int
          : await rawDb.insert('pages', {
              'surface': 'epub',
              'locator': newLocator,
              'title': p['title'],
              'last_seen_at': now,
            });
      pageIdMap[srcId] = localId;
    }

    // Per-profile: tags, sentences, sentence_tags, media.
    var totalSentences = 0;
    var totalTagsMapped = 0;
    final profileBlocks = (manifest['profiles'] as List? ?? const []);
    for (final block in profileBlocks) {
      final profileName = (block['name'] as String?) ?? 'Default';
      final localProfile = await db.findOrCreateProfileByName(profileName);
      final localProfileId = localProfile.id;

      // Tags: reuse by (profile_id, name COLLATE NOCASE), else insert.
      final tagIdMap = <int, int>{};
      for (final t in (block['tags'] as List? ?? const [])) {
        final srcId = (t['id'] as num).toInt();
        final name = t['name'] as String;
        final color = (t['color'] as String?) ?? '#FFC107';
        final existing = await rawDb.query(
          'tags',
          where: 'profile_id = ? AND name = ? COLLATE NOCASE',
          whereArgs: [localProfileId, name],
          limit: 1,
        );
        final localId = existing.isNotEmpty
            ? existing.first['id'] as int
            : await rawDb.insert('tags', {
                'profile_id': localProfileId,
                'name': name,
                'color': color,
                'created_at': now,
              });
        tagIdMap[srcId] = localId;
      }
      totalTagsMapped += tagIdMap.length;

      // Sentences: dedupe by identity. (Wiped above in the replace
      // path, so on a re-import this is effectively a pure insert.)
      final sentenceIdMap = <int, int>{};
      for (final s in (block['sentences'] as List? ?? const [])) {
        final srcId = (s['id'] as num).toInt();
        final srcPageId = (s['page_id'] as num).toInt();
        final localPage = pageIdMap[srcPageId];
        if (localPage == null) continue;
        final text = s['text'] as String;
        final prevFp = s['prev_fp'] as String?;
        final nextFp = s['next_fp'] as String?;
        final mask = s['mask'] as String?;
        final existing = await rawDb.query(
          'sentences',
          where: 'profile_id = ? AND page_id = ? AND text = ? '
              'AND IFNULL(prev_fp,"") = IFNULL(?,"") '
              'AND IFNULL(next_fp,"") = IFNULL(?,"")',
          whereArgs: [localProfileId, localPage, text, prevFp, nextFp],
          limit: 1,
        );
        final localId = existing.isNotEmpty
            ? existing.first['id'] as int
            : await rawDb.insert('sentences', {
                'profile_id': localProfileId,
                'page_id': localPage,
                'text': text,
                'prev_fp': prevFp,
                'next_fp': nextFp,
                'mask': mask,
                'created_at': (s['created_at'] as num?)?.toInt() ?? now,
              });
        sentenceIdMap[srcId] = localId;
      }
      totalSentences += sentenceIdMap.length;

      // sentence_tags — insert (or ignore duplicates thanks to PK).
      for (final st in (block['sentence_tags'] as List? ?? const [])) {
        final srcSid = (st['sentence_id'] as num).toInt();
        final srcTid = (st['tag_id'] as num).toInt();
        final localS = sentenceIdMap[srcSid];
        final localT = tagIdMap[srcTid];
        if (localS == null || localT == null) continue;
        await rawDb.insert(
          'sentence_tags',
          {'sentence_id': localS, 'tag_id': localT},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }

      // Media: extract files from zip → MediaStore, then insert rows.
      for (final m in (block['media'] as List? ?? const [])) {
        final srcSid = (m['sentence_id'] as num).toInt();
        final localS = sentenceIdMap[srcSid];
        if (localS == null) continue;
        final url = m['url'] as String?;
        final kind = (m['kind'] as String?) ?? 'image';
        final filename = (m['filename'] as String?) ?? '';
        final mime = m['mime_type'] as String?;
        final sha1Hex = (m['sha1'] as String?) ?? '';
        if (url != null && url.isNotEmpty) {
          await db.addSentenceMedia(
            sentenceId: localS,
            kind: kind,
            sha1: '',
            url: url,
            filename: filename,
            mimeType: mime,
          );
          continue;
        }
        if (sha1Hex.isEmpty) continue;
        final ext = _extOf(filename);
        // Look for the file in the archive under media/<sha1>.<ext>
        // — or media/<sha1> when the exporter had no extension.
        final zipPath = ext.isEmpty ? 'media/$sha1Hex' : 'media/$sha1Hex.$ext';
        final entry = archive.findFile(zipPath) ?? archive.findFile('media/$sha1Hex');
        if (entry == null) continue;
        final fileBytes = Uint8List.fromList(entry.content as List<int>);
        // Write to a temp file so MediaStore can ingest via its normal
        // hash-and-copy path (which verifies content matches the sha1).
        final tmp = await getTemporaryDirectory();
        final tmpFile = File(
          '${tmp.path}/cupitor_import_${DateTime.now().microsecondsSinceEpoch}'
          '${ext.isEmpty ? '' : '.$ext'}',
        );
        await tmpFile.writeAsBytes(fileBytes, flush: true);
        try {
          final info = await MediaStore.instance.ingest(tmpFile, originalFilename: filename);
          await db.addSentenceMedia(
            sentenceId: localS,
            kind: kind,
            sha1: info.sha1,
            filename: filename,
            mimeType: mime,
            sizeBytes: info.sizeBytes,
          );
        } finally {
          try { await tmpFile.delete(); } catch (_) {}
        }
      }
    }

    // 8. Playlists: create or reuse by name, append items (dedup via
    //    the existing addPlaylistItem which is idempotent for
    //    identical text + book + chapter).
    for (final pl in (manifest['playlists'] as List? ?? const [])) {
      final name = (pl['name'] as String?) ?? 'Imported';
      final existing = await rawDb.query(
        'playlists',
        where: 'name = ?',
        whereArgs: [name],
        limit: 1,
      );
      final playlistId = existing.isNotEmpty
          ? existing.first['id'] as int
          : await rawDb.insert('playlists', {'name': name, 'created_at': now});
      for (final it in (pl['items'] as List? ?? const [])) {
        await db.addPlaylistItem(
          playlistId: playlistId,
          sentenceText: (it['sentence_text'] as String?) ?? '',
          // Retarget to the freshly-imported book so "Open EPUB" from
          // the language app resolves via this device's library.
          bookKey: freshKey,
          bookTitle: bookMeta['title'] as String?,
          chapterIdx: (it['chapter_idx'] as num?)?.toInt(),
          chapterTitle: it['chapter_title'] as String?,
        );
      }
    }

    return BookImportResult(
      bookKey: freshKey,
      bookPath: epubDest.path,
      title: (bookMeta['title'] as String?) ?? 'Untitled',
      replacedExisting: alreadyKnown,
      sentencesImported: totalSentences,
      tagsMappedOrCreated: totalTagsMapped,
      profilesTouched: profileBlocks.length,
    );
  }

  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}

class BookImportResult {
  final String bookKey;
  final String bookPath;
  final String title;
  final bool replacedExisting;
  final int sentencesImported;
  final int tagsMappedOrCreated;
  final int profilesTouched;
  const BookImportResult({
    required this.bookKey,
    required this.bookPath,
    required this.title,
    required this.replacedExisting,
    required this.sentencesImported,
    required this.tagsMappedOrCreated,
    required this.profilesTouched,
  });
}
