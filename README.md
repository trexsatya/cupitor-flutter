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

## Android builds and releases

[Build and deploy Android](https://github.com/trexsatya/cupitor-flutter/actions/workflows/deploy-android.yml)
runs on pushes to `main`, pull requests, and **Actions → Build and deploy Android →
Run workflow**. It runs the Flutter, JavaScript and Android unit tests, then
uploads a universal Android APK to the run's **Artifacts** section (kept for
30 days). The run summary also links to the download.

To publish signed APKs automatically to
[GitHub Releases](https://github.com/trexsatya/cupitor-flutter/releases),
add these **repository secrets** under **Settings → Secrets and variables →
Actions**:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 contents of your existing Android signing keystore |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore's `storePassword` |
| `ANDROID_KEY_ALIAS` | The keystore's `keyAlias` |
| `ANDROID_KEY_PASSWORD` | The signing key's `keyPassword` |

Use the same signing key as the app already installed on your phone so the APK
can update it in place. Keep the keystore backed up outside Git. For example,
with GitHub CLI installed and authenticated:

```sh
openssl base64 -A -in /path/to/your-existing-key.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo trexsatya/cupitor-flutter
gh secret set ANDROID_KEYSTORE_PASSWORD --repo trexsatya/cupitor-flutter
gh secret set ANDROID_KEY_ALIAS --repo trexsatya/cupitor-flutter
gh secret set ANDROID_KEY_PASSWORD --repo trexsatya/cupitor-flutter
```

After configuration, each successful push to `main` (or manual run on `main`)
publishes a release tagged `android-<run number>` and marks it as latest. Each
release includes the source commit and its tested APK. Re-running a published
build keeps the existing release assets. The repository is private, so downloads
require GitHub access to it.

With all four secrets unset, builds still produce a debug-signed `*-test.apk`
artifact; they do not publish a release. Those test APKs use the runner's
temporary debug key and may not update an existing installation. A partial
signing configuration fails with a setup message. Pull requests and manual
runs on other branches build test APKs without access to signing secrets.

The workflow pins Flutter 3.32.8, Java 17, Android SDK 36 and NDK 27.0.12077973.
It adds the workflow run number to the build number in `pubspec.yaml`, so
successive builds can be installed as updates without editing the file each time.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
