import 'package:cupitor/epub_reference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chapters = ['Text/chapter-06.xhtml', 'Text/chapter-07.xhtml', 'notes.xhtml'];
  EpubReference? resolve(String href) => resolveEpubReference(href,
      currentHref: chapters.first, chapterHrefs: chapters);
  test('same chapter footnote and backlink', () {
    final ref = resolve('#ref-note-8')!;
    expect(ref.chapterIndex, 0);
    expect(ref.fragment, 'ref-note-8');
  });
  test('relative chapters, parent directory, encoded fragment and custom URL', () {
    expect(resolve('chapter-07.xhtml#ref-note-8')!.chapterIndex, 1);
    expect(resolve('../notes.xhtml#note-8')!.chapterIndex, 2);
    expect(resolve('#r%C3%A4tt')!.fragment, 'rätt');
    expect(resolve('#literal%2541')!.fragment, 'literal%41');
    expect(resolve('cupitor-epub://chapter/chapter-07.xhtml#r%C3%A4tt')!.fragment, 'rätt');
    expect(resolve('cupitor-epub://chapter/chapter-07.xhtml#ref-note-8')!.chapterIndex, 1);
  });
  test('external and missing resources are not chapter links', () {
    expect(resolve('https://example.com/notes.xhtml'), isNull);
    expect(resolve('//example.com/notes.xhtml'), isNull);
    expect(resolve('missing.xhtml#x'), isNull);
  });
}
