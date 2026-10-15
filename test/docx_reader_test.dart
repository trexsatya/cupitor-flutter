import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cupitor/book_transfer.dart';
import 'package:cupitor/db.dart';
import 'package:cupitor/epub_reader.dart';
import 'package:cupitor/global_search.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'docx_fixtures.dart';

// The Flutter test binding replaces HTTP with 400 responses. This override
// uses Dart's real client only in the local loopback-server test below.
class _LocalHttpOverrides extends HttpOverrides {}

class _Picker extends FilePicker {
  _Picker(this.file);
  final PlatformFile file;
  List<String>? extensions;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    extensions = allowedExtensions;
    return FilePickerResult([file]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  final bytes = zipFixture(
    docxFixture('''
    <w:p><w:pPr><w:outlineLvl w:val="0"/></w:pPr>
      <w:r><w:t>Kapitel ett</w:t></w:r></w:p>
    <w:p><w:r><w:t>Sökbar svensk text.</w:t></w:r></w:p>
    <w:p><w:pPr><w:outlineLvl w:val="0"/></w:pPr>
      <w:r><w:t>Kapitel två</w:t></w:r></w:p>
  '''),
  );

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cupitor_docx_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmp.path,
        );
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDownAll(() async {
    await (await CupitorDb.instance.rawDb())?.close();
    await tmp.delete(recursive: true);
  });

  test(
    'opens DOCX in the shared chapter/TOC model with original content identity',
    () async {
      final file = await File('${tmp.path}/Min bok.DOCX').writeAsBytes(bytes);
      final book = await EpubBook.openFile(file);
      expect(book.title, 'Min bok');
      expect(book.filePath, file.path);
      expect(book.key, sha1.convert(bytes).toString());
      expect(book.chapters.map((c) => c.title), ['Kapitel ett', 'Kapitel två']);
      expect(book.toc.map((c) => c.chapterIdx), [0, 1]);
      expect(book.chapters.first.html, contains('Sökbar svensk text.'));
      final renamed = await file.copy('${tmp.path}/Renamed.docx');
      expect((await EpubBook.openFile(renamed)).key, book.key);
      await EpubReadingState(chapterIdx: 1, scrollPct: .4).save(book.key);
      expect((await EpubReadingState.load(book.key)).chapterIdx, 1);
    },
  );

  test(
    'cache detects DOCX bytes for nameless URLs and handles name collisions',
    () async {
      final unnamed = await cacheEpubFromBytes(bytes);
      expect(unnamed.path, endsWith('.docx'));
      final first = await cacheEpubFromBytes(
        bytes,
        suggestedName: 'shared.epub',
      );
      expect(first.path, endsWith('/shared.docx'));
      final other = zipFixture(
        docxFixture('<w:p><w:r><w:t>Annan</w:t></w:r></w:p>'),
      );
      final second = await cacheEpubFromBytes(
        other,
        suggestedName: 'shared.docx',
      );
      expect(second.path, isNot(first.path));
      expect(second.path, endsWith('.docx'));
      expect(await first.readAsBytes(), bytes);
      expect(await second.readAsBytes(), other);
      expect(
        (await cacheEpubFromBytes(bytes, suggestedName: 'shared.docx')).path,
        first.path,
      );
    },
  );

  test(
    'device picker offers both formats and keeps original DOCX bytes',
    () async {
      final picker = _Picker(
        PlatformFile(name: 'Picked.docx', size: bytes.length, bytes: bytes),
      );
      FilePicker.platform = picker;
      final file = await pickEpubFromDevice();
      expect(picker.extensions, containsAll(['epub', 'docx']));
      expect(file!.path, endsWith('.docx'));
      expect(await file.readAsBytes(), bytes);
    },
  );

  test('global library search includes DOCX chapters', () async {
    final file = await cacheEpubFromBytes(bytes, suggestedName: 'Search.docx');
    final book = await EpubBook.openFile(file);
    final library = await EpubLibrary.load();
    await library.touch(
      EpubLibraryEntry(key: book.key, path: file.path, title: book.title),
    );
    final hits = await collectAllHits('sökbar');
    expect(hits.single.bookKey, book.key);
    expect(hits.single.chapterIdx, 0);
    expect(hits.single.chapterTitle, 'Kapitel ett');
  });

  test(
    'downloads a DOCX URL with query parameters into the same cache',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = server.listen((request) async {
        request.response.add(bytes);
        await request.response.close();
      });
      try {
        final file = await downloadEpubFromUrl(
          'http://127.0.0.1:${server.port}/Downloaded.DOCX?token=test#part',
        );
        expect(file!.path, endsWith('/Downloaded.docx'));
        expect((await EpubBook.openFile(file)).chapters, hasLength(2));
      } finally {
        await serving.cancel();
        await server.close(force: true);
      }
    }, _LocalHttpOverrides()),
  );

  test('existing EPUB parsing and original hash remain unchanged', () async {
    final archive = Archive();
    final files = {
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf':
          '''<package xmlns:dc="urn:dc"><metadata><dc:title>EPUB title</dc:title></metadata>
      <manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
      <spine><itemref idref="ch1"/></spine></package>''',
      'ch1.xhtml': '<html><body><p>Original EPUB text.</p></body></html>',
    };
    for (final item in files.entries) {
      final data = utf8.encode(item.value);
      archive.addFile(ArchiveFile(item.key, data.length, data));
    }
    final epubBytes = zipFixture(archive);
    final file = await cacheEpubFromBytes(
      epubBytes,
      suggestedName: 'Original.epub',
    );
    final book = await EpubBook.openFile(file);
    expect(book.title, 'EPUB title');
    expect(book.key, sha1.convert(epubBytes).toString());
    expect(book.chapters.single.html, '<p>Original EPUB text.</p>');
    expect(file.path, endsWith('.epub'));
  });

  test(
    'DOCX bundle round trip preserves bytes, library identity and reading state',
    () async {
      final file = await cacheEpubFromBytes(
        bytes,
        suggestedName: 'Transfer.docx',
      );
      final book = await EpubBook.openFile(file);
      final library = await EpubLibrary.load();
      await library.touch(
        EpubLibraryEntry(key: book.key, path: file.path, title: book.title),
      );
      await EpubReadingState(chapterIdx: 1, scrollPct: .25).save(book.key);
      final bundle = await BookExporter.buildBundle(
        bookKey: book.key,
        epubFile: file,
      );
      final archive = ZipDecoder().decodeBytes(bundle);
      expect(archive.findFile('book.docx')!.content, bytes);
      expect(archive.findFile('book.epub'), isNull);
      await library.remove(book.key);
      final zip = await File(
        '${tmp.path}/Transfer.cupitor.zip',
      ).writeAsBytes(bundle);
      await BookImporter.importBundle(zipFile: zip);
      final restored = (await EpubLibrary.load()).entries.single;
      expect(restored.key, book.key);
      expect(restored.path, endsWith('.docx'));
      expect(await File(restored.path).readAsBytes(), bytes);
      expect(
        (await EpubBook.openFile(File(restored.path))).chapters,
        hasLength(2),
      );
      final state = await EpubReadingState.load(restored.key);
      expect(state.chapterIdx, 1);
      expect(state.scrollPct, .25);
    },
  );
}
