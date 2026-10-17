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

## YouTube subtitle sidebar

Open a YouTube video in the app's main browser and tap **⤓CC** in the subtitle
sidebar. Cupitor reuses its existing YouTube download flow: choose a caption
track, download it, then use the complete transcript beside the player.
The panel follows playback, supports seeking and previous/next cues, and keeps
the existing translation, replay strategies and select-lines/send-to-lookup
controls. A downloaded track replaces the live harvested lines for that video.

The last five downloaded tracks are kept in the page's tab session so returning
to a video or reloading it can restore its transcript. **Clear transcript**
also removes that video's saved track. A download finishing after you switch
videos is rejected rather than attaching captions to the wrong video.

This feature needs both the updated Android/macOS app and the updated remote
subtitle sidebar (`db/js/src/20-caption-sidebar.js` and
`db/js/src/70-caption-capture.js`, bundled into `db/js/snippet.js` in
`trexsatya/trexsatya.github.io`). The button stays hidden in older app versions.
The CC button in dialog1 still offers the existing standalone download dialog.

Dialog1's top bar now fades after three seconds of inactivity and reappears
on tap. Its height stays reserved, so the WebView and video do not move or
resize. Active microphone capture and held touches keep it visible; the
explicit fullscreen button continues to use its existing layout.

## YouTube controls in dialog1

On Android, dialog1's webapp can call
`window.CupitorYouTubeControls?.setVisible(false)` to hide YouTube's embedded
player controls, or pass `true` to show them without reloading the player.
The webapp owns tap handling and idle timers. See
[the bridge API](docs/youtube-controls-bridge.md)
for feature detection, iframe lifecycle handling and integration examples.

## Android App Bundle builds and releases

[Build and deploy Android](https://github.com/trexsatya/cupitor-flutter/actions/workflows/deploy-android.yml)
runs on pushes to `main`, pull requests, and **Actions → Build and deploy Android →
Run workflow**. It runs the Flutter, reader JavaScript and Android unit tests,
then builds an Android App Bundle (`.aab`). The bundle is downloadable from the
run's **Artifacts** section (kept for 30 days), with a link in the run summary.

To publish signed bundles automatically to
[GitHub Releases](https://github.com/trexsatya/cupitor-flutter/releases),
add these **repository secrets** under **Settings → Secrets and variables →
Actions**:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 contents of your existing Android upload/signing keystore |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore's `storePassword` |
| `ANDROID_KEY_ALIAS` | The keystore's `keyAlias` |
| `ANDROID_KEY_PASSWORD` | The signing key's `keyPassword` |

For Google Play, use the upload key registered for this app in Play Console.
Keep the keystore backed up outside Git. For example, with GitHub CLI installed
and authenticated:

```sh
openssl base64 -A -in /path/to/your-existing-key.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo trexsatya/cupitor-flutter
gh secret set ANDROID_KEYSTORE_PASSWORD --repo trexsatya/cupitor-flutter
gh secret set ANDROID_KEY_ALIAS --repo trexsatya/cupitor-flutter
gh secret set ANDROID_KEY_PASSWORD --repo trexsatya/cupitor-flutter
```

After configuration, each successful push to `main` (or manual run on `main`)
publishes a release tagged `android-<run number>` and marks it as latest. Each
release includes the source commit and its tested AAB. Re-running a published
build keeps the existing release assets. The repository is private, so downloads
require GitHub access to it. Download the signed `*-release.aab` and upload it
in Play Console. This workflow publishes to GitHub Releases; Play Console
upload remains manual.

With all four secrets unset, builds still produce a debug-signed `*-test.aab`
artifact for build verification. Publishing to GitHub Releases is disabled, and
the test bundle cannot be uploaded as a production Play release. A partial
signing configuration fails with a setup message. Pull requests and manual
runs on other branches build test bundles without access to signing secrets.

The workflow pins Flutter 3.32.8, Java 17, Android SDK 36 and NDK 27.0.12077973.
It adds the workflow run number to the build number in `pubspec.yaml`. When
uploading to Play, this number must exceed the app's last uploaded version code;
increase the base build number in `pubspec.yaml` if needed.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
