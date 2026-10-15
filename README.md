# cupitor

A new Flutter project.

## Reading EPUB and DOCX

Use **Tools → Books → Open EPUB / DOCX** to select a local file or download
one from a URL. Links ending in `.epub` or `.docx` in the main browser also
open in the reader. Both formats appear in **Book library** and share search,
dictionary lookup, text-to-speech, themes, highlights, tags and saved reading
position. Cupitor bundle export/import keeps the original document and its
reading state; DOCX bundles require a version of Cupitor with DOCX support.

Select text to use the reader toolbar: **Lookup**, **Search**, **Highlight**,
**Note** or **Copy**. Search opens dialog1 with the selected text through the
same flow as **Open lookup dialog**. On Android the reader supplies this single
toolbar while keeping the native selection handles available.

In **Tools → View snippet logs**, use **Save log** in the top bar to save a
UTF-8 `.txt` snapshot through the system file picker. Messages arriving while
the picker is open remain in the app for the next export.

DOCX is read locally with the existing ZIP/XML dependencies. Headings become
chapters. Paragraphs, direct bold/italic/underline formatting, basic numbered
and bulleted lists, tables, embedded PNG/JPEG/GIF/WebP/BMP images and safe web
links are supported. Footnotes and endnotes appear separately at the end of
each referencing chapter, with links back to the text.

This is a reflowable reading view: Word page layout, headers/footers, text
boxes, equations, complex numbering, vertically merged table cells and full
style fidelity are not reproduced. Internal bookmark links work within a
chapter. Encrypted/password-protected documents and legacy `.doc` files are
not supported.

Run the document reader tests with:

```sh
flutter test test/docx_document_test.dart test/docx_reader_test.dart
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
