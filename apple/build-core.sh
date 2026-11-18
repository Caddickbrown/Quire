#!/bin/bash
# Build a universal macOS / iOS device / iOS simulator Rust XCFramework.
set -euo pipefail
# A caller's CARGO_TARGET_DIR is honoured (e.g. on an external disk); a relative
# one is read from the caller's directory, before the cd below.
caller_target="${CARGO_TARGET_DIR:-}"
if [[ -n "$caller_target" && "$caller_target" != /* ]]; then
    caller_target="$PWD/$caller_target"
fi
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
    echo 'Apple builds require macOS with full Xcode selected by xcode-select.' >&2
    exit 1
fi
command -v cargo >/dev/null || { echo 'Install Rust with rustup first.' >&2; exit 1; }
# The cross targets are rustup's. A cargo from somewhere else that comes first
# on PATH (Homebrew's) has only the host's, and fails with "can't find crate
# for `core`": build with the toolchain rustup adds the targets to.
if command -v rustup >/dev/null && toolchain_cargo="$(rustup which cargo 2>/dev/null)"; then
    PATH="$(dirname "$toolchain_cargo"):$PATH"
    export PATH
fi
# Apple builds get their own "apple" folder inside the target dir, so the
# deployment-target settings below don't rebuild the host's artifacts. With no
# CARGO_TARGET_DIR (Xcode Cloud, CI) that is the workspace's target/apple.
if [[ -n "$caller_target" ]]; then
    export CARGO_TARGET_DIR="$caller_target/apple"
else
    export CARGO_TARGET_DIR="$PWD/target/apple"
fi
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
build_root="$PWD/apple/Frameworks/build"
mkdir -p "$build_root/macos" "$build_root/simulator" apple/Generated/Headers
for triple in aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    rustup target add "$triple"
    cargo build --locked --release -p quire-bindings --lib --target "$triple"
done
# Generate from a host dylib; do not attempt to load an iPhone library on the host.
cargo build --locked -p quire-bindings --features bindgen --lib --bin quire-bindgen
"$CARGO_TARGET_DIR/debug/quire-bindgen" generate --library "$CARGO_TARGET_DIR/debug/libquire_bindings.dylib" \
    --metadata-no-deps --language swift --config bindings/uniffi.toml --out-dir apple/Generated
cp apple/Generated/QuireCoreFFI.h apple/Generated/Headers/
cp apple/Generated/QuireCoreFFI.modulemap apple/Generated/Headers/module.modulemap
lipo -create "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libquire_bindings.a" \
    "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libquire_bindings.a" -output "$build_root/macos/libquire_bindings.a"
lipo -create "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libquire_bindings.a" \
    "$CARGO_TARGET_DIR/x86_64-apple-ios/release/libquire_bindings.a" -output "$build_root/simulator/libquire_bindings.a"
# xcodebuild refuses to replace an existing output. Remove only this generated bundle.
python3 - <<'PY'
import shutil
shutil.rmtree('apple/Frameworks/QuireCoreFFI.xcframework', ignore_errors=True)
PY
xcodebuild -create-xcframework \
    -library "$build_root/macos/libquire_bindings.a" -headers apple/Generated/Headers \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libquire_bindings.a" -headers apple/Generated/Headers \
    -library "$build_root/simulator/libquire_bindings.a" -headers apple/Generated/Headers \
    -output apple/Frameworks/QuireCoreFFI.xcframework
