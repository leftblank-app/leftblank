#!/bin/bash
# Build the typst-syntax bridge that LeftBlankCore links on macOS. SwiftPM
# consumes it as a binary target, so run this (or scripts/bootstrap.sh) before
# the first `swift build`. The iPad links the same crate through
# Engine/TinymistBridge instead (scripts/build-ipad.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  export CARGO_HOME="$PWD/.tools/cargo-syntax"
  rustup toolchain install 1.92.0 --profile minimal --component rustfmt --component clippy
else
  # Shared with the iPad engine, which already caches the same Typst git source.
  export CARGO_HOME=/Volumes/SSD/Developer/Codex/cargo-ipad
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
target=aarch64-apple-darwin
cargo +1.92.0 build --locked --release --lib --manifest-path Engine/SyntaxBridge/Cargo.toml --target "$target"
library="Engine/SyntaxBridge/target/$target/release/libleftblank_syntax.a"
framework=Engine/SyntaxBridge/target/LeftBlankSyntax.xcframework
# Recreate only after the library changes, so SwiftPM does not relink needlessly.
if [ ! -f "$framework/Info.plist" ] || [ "$library" -nt "$framework/Info.plist" ]; then
  rm -rf "$framework"
  xcodebuild -create-xcframework -library "$library" -output "$framework" >/dev/null
fi
python3 scripts/rust-licenses.py syntax
