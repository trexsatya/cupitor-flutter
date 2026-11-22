#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root/native/adblock"
command -v cargo >/dev/null || { echo 'Install the Rust toolchain before building Cupitor.' >&2; exit 1; }
case "${1:-}" in
  android)
    ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
    test -n "$ndk_root" || { echo 'ANDROID_NDK_HOME must name the installed Android NDK.' >&2; exit 1; }
    case "$(uname -s)" in Darwin) ndk_host=darwin-x86_64;; *) ndk_host=linux-x86_64;; esac
    toolchain="$ndk_root/toolchains/llvm/prebuilt/$ndk_host/bin"
    rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
    for spec in 'aarch64-linux-android:arm64-v8a:aarch64-linux-android24-clang' \
                'armv7-linux-androideabi:armeabi-v7a:armv7a-linux-androideabi24-clang' \
                'x86_64-linux-android:x86_64:x86_64-linux-android24-clang'; do
      IFS=: read -r target abi linker <<< "$spec"
      target_key="$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')"
      env "CARGO_TARGET_${target_key}_LINKER=$toolchain/$linker" \
        cargo build --lib --release --locked --target "$target"
      destination="$repo_root/android/app/src/main/jniLibs/$abi"
      mkdir -p "$destination"
      cp "target/$target/release/libcupitor_adblock.so" "$destination/"
    done
    ;;
  macos)
    export MACOSX_DEPLOYMENT_TARGET=12.0
    rustup target add aarch64-apple-darwin x86_64-apple-darwin
    cargo build --lib --release --locked --target aarch64-apple-darwin
    cargo build --lib --release --locked --target x86_64-apple-darwin
    mkdir -p build/macos
    lipo -create target/aarch64-apple-darwin/release/libcupitor_adblock.a \
      target/x86_64-apple-darwin/release/libcupitor_adblock.a -output build/macos/libcupitor_adblock.a
    ;;
  *) echo 'Usage: scripts/build-brave-engine.sh android|macos' >&2; exit 2;;
esac
