#!/bin/bash
# LB-019 spike: build Engine/SyntaxBridge (typst-syntax behind a C ABI) for
# macOS, iOS and the iOS simulator, and wrap it as one static XCFramework that
# a SwiftPM binaryTarget (or the Xcode projects) can link on both platforms.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  export CARGO_HOME="${CARGO_HOME:-/Volumes/SSD/Developer/Claude/cargo-home}"
fi
export MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0
manifest=Engine/SyntaxBridge/Cargo.toml
output=Benchmarks/VisualEditing/Artifacts/LeftBlankSyntax.xcframework
targets=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
rustup toolchain install 1.92.0 --profile minimal --target "$(IFS=,; echo "${targets[*]}")" >/dev/null
headers="$(mktemp -d "$TMPDIR/syntax-headers.XXXXXX")"
cp Engine/SyntaxBridge/include/LeftBlankSyntax.h "$headers/"
cat > "$headers/module.modulemap" <<'MAP'
module LeftBlankSyntaxFFI {
    header "LeftBlankSyntax.h"
    export *
}
MAP
arguments=()
for target in "${targets[@]}"; do
  started=$(date +%s)
  cargo +1.92.0 build --manifest-path "$manifest" --release --target "$target" --lib
  library="Engine/SyntaxBridge/target/$target/release/libleftblank_syntax.a"
  echo "$target: $(( $(date +%s) - started ))s, $(du -h "$library" | cut -f1) static library"
  arguments+=(-library "$library" -headers "$headers")
done
rm -rf "$output"
mkdir -p "$(dirname "$output")"
xcodebuild -create-xcframework "${arguments[@]}" -output "$output" >/dev/null
rm -rf "$headers"
du -sh "$output"
