# Brave ad blocking

Android and macOS use Brave Software's `adblock` Rust crate, pinned to 0.13.6
in `native/adblock/Cargo.lock`. This embeds Brave's ad blocker, rather than
replacing Android WebView or WKWebView with the Brave browser.

- Android calls the engine through JNI before network subresources load.
  Engine-selected scriptlets run at document start in all frames on WebViews
  supporting AndroidX's document-start API. Older WebViews retain the custom
  JSON/Skip fallback alongside native network filtering.
- macOS compiles the engine's network rules into `WKContentRuleList` and runs
  scriptlets in every frame. Per-frame fetch/XHR requests also consult the
  native matcher. WebKit's public content-blocking API cannot express every
  Brave network feature; this is not complete Brave Shields parity.
- Both platforms apply ordinary cosmetic CSS rules and generic class/id
  rules, including cosmetic exceptions. Procedural cosmetic operators are not
  implemented. YouTube scriptlets are embedded directly into document-start
  code, so they work with restrictive CSP and unattached/background WebViews.
- The existing ad-blocking toggle and explicit custom blocked hosts remain.
  Scriptlet changes take effect on the next navigation. Existing ad-state,
  enabled Skip retries and content-recovery safeguards remain active.
- The ordinary web app has no native request-interception layer; its existing
  fallback continues to work within the hosting browser's restrictions.

The app ships a verified compressed snapshot of 12 maintained lists and 224
scriptlet/redirect resources for the first launch and offline use. At most once
a day, it checks `assets/adblock/manifest.json` on this repository's `main`
branch via `raw.githubusercontent.com`. When the version increases, it fetches
the prebuilt `bundle.json.gz.b64` from the same directory. Devices no longer
download individual upstream lists or assemble scriptlets themselves.

Downloads have size, decompression, SHA-256, schema and engine-version checks.
Unchanged versions need only the manifest request. The native engine must
accept an update before it is cached for subsequent offline launches. Failed
downloads, a manifest/bundle race on GitHub, invalid data and failed activation
retain the last working copy. Older remote versions cannot downgrade the cache.
The bundled snapshot wins over data cached by an older app version. Source
commits, hashes and licenses remain under `assets/adblock/`.

## Building

Install Rust 1.100.0 (the CI toolchain), with `cargo` and `rustup` on PATH.
Android builds also need NDK 27.0.12077973; set `ANDROID_NDK_HOME` to its
directory. Gradle compiles ARM64, ARMv7 and x86_64 libraries before packaging.
The macOS Xcode phase builds a universal ARM64/x86_64 static library.
Generated native binaries are ignored by Git.

```sh
cargo test --manifest-path native/adblock/Cargo.toml --locked
node --test test/js/brave_adblock.test.mjs test/js/youtube_ads.test.mjs
```

For Chromium regressions, first generate the actual engine/scriptlet fixture:

```sh
CUPITOR_BRAVE_FIXTURE="$PWD/native/adblock/target/brave-fixture.json" \
  cargo test --manifest-path native/adblock/Cargo.toml --locked
# Use the same playwright-core/Chrome setup as deploy-android.yml.
node --test test/browser/brave_adblock.test.cjs
```

To rebuild the offline snapshot, clone the four upstream repositories into a
directory named with `brave-engine`, `brave-resources`, `ublock-assets` and
`brave-lists`, check out the reviewed commits, then run
`python3 scripts/update-brave-bundle.py /path/to/checkouts`. The bundle version
defaults to the UTC build timestamp; use `--version` to reproduce a specific
version. Every content change needs a higher version, since WebKit caches rules
by version. Commit the regenerated bundle and manifest together to `main` to
publish filter updates without rebuilding the app. The native Rust engine is
still compiled into each app; only filter/scriptlet data is fetched at runtime.

Test downloads, cache promotion, rollback and offline handling with:

```sh
flutter test test/brave_adblock_update_test.dart test/brave_adblock_bundle_test.dart
```
