import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const wordNamespace =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

Archive docxFixture(
  String body, {
  Map<String, String> extra = const {},
  Map<String, List<int>> binary = const {},
  String? document,
}) {
  final files = {
    '[Content_Types].xml':
        '''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>''',
    'word/document.xml':
        document ??
        '''<w:document xmlns:w="$wordNamespace"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
      xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
      <w:body>$body</w:body></w:document>''',
    ...extra,
  };
  final archive = Archive();
  for (final file in files.entries) {
    final bytes = utf8.encode(file.value);
    archive.addFile(ArchiveFile(file.key, bytes.length, bytes));
  }
  for (final file in binary.entries) {
    archive.addFile(ArchiveFile(file.key, file.value.length, file.value));
  }
  return archive;
}

Uint8List zipFixture(Archive archive) =>
    Uint8List.fromList(ZipEncoder().encode(archive)!);

String relationships(String children) => '''
  <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  $children</Relationships>''';
