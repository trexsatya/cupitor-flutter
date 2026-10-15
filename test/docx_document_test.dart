import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cupitor/docx_document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'docx_fixtures.dart';

void main() {
  String html(DocxDocument doc) => doc.chapters.map((c) => c.html).join();

  test(
    'reads Swedish Unicode, metadata and escaped text in document order',
    () {
      final doc = DocxDocument.fromArchive(
        docxFixture(
          '''
      <w:p><w:r><w:t>Åsa &amp; Örjan &lt;läser&gt;.</w:t></w:r></w:p>
      <w:p><w:r><w:t>Andra stycket.</w:t></w:r></w:p>
    ''',
          extra: {
            'docProps/core.xml': '''<cp:coreProperties xmlns:cp="urn:core"
          xmlns:dc="urn:dc"><dc:title>Min bok</dc:title>
          <dc:creator>Författaren</dc:creator></cp:coreProperties>''',
          },
        ),
      );
      expect(doc.title, 'Min bok');
      expect(doc.author, 'Författaren');
      final content = XmlDocument.parse('<body>${html(doc)}</body>');
      expect(content.rootElement.childElements.map((p) => p.innerText), [
        'Åsa & Örjan <läser>.',
        'Andra stycket.',
      ]);
    },
  );

  test('uses filename fallback and gives empty documents a readable page', () {
    final doc = DocxDocument.fromArchive(
      docxFixture(''),
      title: 'Anteckningar',
    );
    expect(doc.title, 'Anteckningar');
    expect(doc.chapters, hasLength(1));
    expect(doc.chapters.single.title, 'Anteckningar');
    expect(doc.chapters.single.html, '<p></p>');
  });

  test(
    'splits at inherited heading styles without losing the introduction',
    () {
      final doc = DocxDocument.fromArchive(
        docxFixture(
          '''
      <w:p><w:r><w:t>Inledning.</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="Custom"/></w:pPr>
        <w:r><w:t>Första kapitlet</w:t></w:r></w:p>
      <w:p><w:r><w:t>Brödtext.</w:t></w:r></w:p>
      <w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr>
        <w:r><w:t>Andra delen</w:t></w:r></w:p>
    ''',
          extra: {
            'word/styles.xml': '''<w:styles xmlns:w="$wordNamespace">
        <w:style w:styleId="Custom"><w:basedOn w:val="Heading1"/></w:style>
        <w:style w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/>
        </w:pPr></w:style></w:styles>''',
          },
        ),
      );
      expect(doc.chapters.map((c) => c.title), [
        'Untitled',
        'Första kapitlet',
        'Andra delen',
      ]);
      expect(doc.chapters[1].html, contains('<h1>Första kapitlet</h1>'));
      expect(doc.chapters[1].html, contains('Brödtext.'));
      expect(doc.chapters[2].html, contains('<h2>Andra delen</h2>'));
    },
  );

  test('style cycles terminate and body outline overrides heading style', () {
    final doc = DocxDocument.fromArchive(
      docxFixture(
        '''
      <w:p><w:pPr><w:pStyle w:val="Loop"/></w:pPr><w:r><w:t>A</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="Heading1"/><w:outlineLvl w:val="9"/>
      </w:pPr><w:r><w:t>B</w:t></w:r></w:p>
    ''',
        extra: {
          'word/styles.xml': '''<w:styles xmlns:w="$wordNamespace">
      <w:style w:styleId="Loop"><w:basedOn w:val="Loop"/></w:style>
      </w:styles>''',
        },
      ),
    );
    expect(doc.chapters, hasLength(1));
    expect(html(doc), isNot(contains('<h1>')));
  });

  test('retains formatting, tabs, breaks and displayed field results', () {
    final doc = DocxDocument.fromArchive(
      docxFixture('''
      <w:p><w:pPr><w:jc w:val="center"/></w:pPr>
        <w:r><w:rPr><w:b/><w:i/><w:u w:val="single"/></w:rPr>
          <w:t>Hej</w:t><w:tab/><w:br/><w:t>igen</w:t></w:r>
        <w:r><w:rPr><w:b w:val="0"/><w:vertAlign w:val="subscript"/>
          </w:rPr><w:t>2</w:t></w:r>
        <w:r><w:instrText>DO NOT DISPLAY</w:instrText></w:r>
        <w:fldSimple w:instr="DATE"><w:r><w:t>2026</w:t></w:r></w:fldSimple>
      </w:p>
    '''),
    );
    expect(html(doc), contains('text-align:center'));
    expect(html(doc), contains('<u><em><strong>Hej'));
    expect(html(doc), contains('<br/>igen'));
    expect(html(doc), contains('<sub>2</sub>'));
    expect(html(doc), contains('2026'));
    expect(html(doc), isNot(contains('DO NOT DISPLAY')));
  });

  test('shows accepted revisions and skips hidden/deleted text', () {
    final doc = DocxDocument.fromArchive(
      docxFixture('''
      <w:p><w:del><w:r><w:delText>Borta</w:delText></w:r></w:del>
      <w:ins><w:r><w:t>Synligt</w:t></w:r></w:ins>
      <w:r><w:rPr><w:vanish/></w:rPr><w:t>Hemligt</w:t></w:r></w:p>
    '''),
    );
    expect(html(doc), contains('Synligt'));
    expect(html(doc), isNot(contains('Borta')));
    expect(html(doc), isNot(contains('Hemligt')));
  });

  test(
    'continues numbered lists across paragraphs and honors start overrides',
    () {
      String item(String text) => '''<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/>
      <w:numId w:val="7"/></w:numPr></w:pPr><w:r><w:t>$text</w:t></w:r></w:p>''';
      final doc = DocxDocument.fromArchive(
        docxFixture(
          '''
      ${item('ett')}<w:p><w:r><w:t>Paus</w:t></w:r></w:p>${item('två')}
    ''',
          extra: {
            'word/numbering.xml': '''<w:numbering xmlns:w="$wordNamespace">
        <w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="0">
          <w:start w:val="1"/><w:numFmt w:val="lowerLetter"/>
        </w:lvl></w:abstractNum><w:num w:numId="7">
          <w:abstractNumId w:val="2"/><w:lvlOverride w:ilvl="0">
          <w:startOverride w:val="3"/></w:lvlOverride></w:num></w:numbering>''',
          },
        ),
      );
      final root = XmlDocument.parse('<body>${html(doc)}</body>');
      final lists = root.findAllElements('ol').toList();
      expect(lists.map((l) => l.getAttribute('start')), ['3', '4']);
      expect(lists.map((l) => l.getAttribute('type')), ['a', 'a']);
    },
  );

  test('preserves table text, merged columns and content controls', () {
    final doc = DocxDocument.fromArchive(
      docxFixture('''
      <w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
      <w:p><w:r><w:t>Tabelltext</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
      <w:sdt><w:sdtContent><w:p><w:r><w:t>Kontroll</w:t></w:r></w:p>
      </w:sdtContent></w:sdt>
    '''),
    );
    final root = XmlDocument.parse('<body>${html(doc)}</body>');
    expect(root.findAllElements('td').single.getAttribute('colspan'), '2');
    expect(root.innerText, 'TabelltextKontroll');
  });

  test(
    'embeds local images and keeps safe hyperlinks without active markup',
    () {
      final doc = DocxDocument.fromArchive(
        docxFixture(
          '''
      <w:p><w:hyperlink r:id="web"><w:r><w:t>Länk</w:t></w:r></w:hyperlink>
      <w:hyperlink r:id="bad"><w:r><w:t>Text</w:t></w:r></w:hyperlink>
      <w:r><w:drawing><wp:docPr descr="Bild &quot;ett&quot;"/>
      <a:blip r:embed="pic"/></w:drawing></w:r></w:p>
    ''',
          extra: {
            'word/_rels/document.xml.rels': relationships('''
        <Relationship Id="web" Target="https://example.com/?a=1&amp;b=2" TargetMode="External"/>
        <Relationship Id="bad" Target="javascript:alert(1)" TargetMode="External"/>
        <Relationship Id="pic" Target="media/pic.png"/>
      '''),
          },
          binary: {
            'word/media/pic.png': [137, 80, 78, 71],
          },
        ),
      );
      final root = XmlDocument.parse('<body>${html(doc)}</body>');
      expect(
        root.findAllElements('a').single.getAttribute('href'),
        'https://example.com/?a=1&b=2',
      );
      final image = root.findAllElements('img').single;
      expect(
        image.getAttribute('src'),
        'data:image/png;base64,${base64Encode([137, 80, 78, 71])}',
      );
      expect(image.getAttribute('alt'), 'Bild "ett"');
      expect(html(doc), isNot(contains('javascript:')));
    },
  );

  test('does not fetch externally linked images', () {
    final doc = DocxDocument.fromArchive(
      docxFixture(
        '''
      <w:p><w:r><w:drawing><a:blip r:embed="remote"/>
      </w:drawing></w:r></w:p>
    ''',
        extra: {
          'word/_rels/document.xml.rels': relationships('''
      <Relationship Id="remote" Target="https://example.com/pic.png" TargetMode="External"/>
      '''),
        },
      ),
    );
    expect(html(doc), isNot(contains('<img')));
  });

  test('footnotes stay separate from prose, in each referencing chapter', () {
    final doc = DocxDocument.fromArchive(
      docxFixture(
        '''
      <w:p><w:r><w:t>Text</w:t><w:footnoteReference w:id="1"/></w:r></w:p>
      <w:p><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:r><w:t>Nästa</w:t></w:r></w:p>
      <w:p><w:r><w:t>Mer text</w:t><w:endnoteReference w:id="2"/></w:r></w:p>
    ''',
        extra: {
          'word/footnotes.xml':
              '''<w:footnotes xmlns:w="$wordNamespace" xmlns:r="urn:r">
        <w:footnote w:id="-1" w:type="separator"><w:p><w:r><w:t>Separator</w:t>
        </w:r></w:p></w:footnote><w:footnote w:id="1"><w:p>
        <w:hyperlink r:id="noteLink"><w:r><w:t>Källan</w:t></w:r></w:hyperlink>
        </w:p></w:footnote></w:footnotes>''',
          'word/_rels/footnotes.xml.rels': relationships('''
        <Relationship Id="noteLink" Target="https://example.com/source" TargetMode="External"/>
      '''),
          'word/endnotes.xml':
              '''<w:endnotes xmlns:w="$wordNamespace"><w:endnote w:id="2">
        <w:p><w:r><w:t>Slutnot</w:t></w:r></w:p></w:endnote></w:endnotes>''',
        },
      ),
    );
    expect(doc.chapters, hasLength(2));
    final first = XmlDocument.parse('<body>${doc.chapters[0].html}</body>');
    expect(first.findAllElements('p').first.innerText, 'Text1');
    expect(
      first.findAllElements('aside').single.getAttribute('id'),
      'footnote-1',
    );
    expect(
      first.findAllElements('a').map((a) => a.getAttribute('href')),
      contains('https://example.com/source'),
    );
    expect(doc.chapters[0].html, isNot(contains('Slutnot')));
    expect(doc.chapters[1].html, contains('Slutnot'));
    expect(html(doc), isNot(contains('Separator')));
  });

  test('rejects packages without a Word document body', () {
    expect(DocxDocument.isDocx(Archive()), isFalse);
    expect(() => DocxDocument.fromArchive(Archive()), throwsFormatException);
    expect(
      () => DocxDocument.fromArchive(docxFixture('', document: '<broken>')),
      throwsA(isA<XmlException>()),
    );
  });
}
