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
scriptlet/redirect resources. It starts offline, checks trusted upstream HTTPS
sources at most once a day, resolves list includes, and retains the last good
bundle if download, parsing or native activation fails. The bundled snapshot
wins over data cached by an older app version. Source commits, hashes and
licenses are under `assets/adblock/`.

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
`python3 scripts/update-brave-bundle.py /path/to/checkouts`.
