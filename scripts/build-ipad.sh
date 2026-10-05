#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh

platform="${1:-simulator}"
sanitizer="${2:-none}"
derived_data=build/iPad
diagnostics=()
case "$platform" in
  simulator) target=aarch64-apple-ios-sim; destination='generic/platform=iOS Simulator'; actions=(build-for-testing); diagnostics=(-enableCodeCoverage YES) ;;
  device) target=aarch64-apple-ios; destination='generic/platform=iOS'; actions=(build analyze) ;;
  *) echo 'Usage: scripts/build-ipad.sh [simulator|device] [none|address|thread]' >&2; exit 2 ;;
esac
case "$sanitizer" in
  none) ;;
  address|thread)
    test "$platform" = simulator || { echo 'Sanitizers require the iPad simulator.' >&2; exit 2; }
    derived_data="build/iPad-memory/$sanitizer"
    diagnostics=(-enableCodeCoverage NO)
    if [ "$sanitizer" = address ]; then
      diagnostics+=(-enableAddressSanitizer YES -enableThreadSanitizer NO)
    else
      diagnostics+=(-enableAddressSanitizer NO -enableThreadSanitizer YES)
    fi
    ;;
  *) echo 'Usage: scripts/build-ipad.sh [simulator|device] [none|address|thread]' >&2; exit 2 ;;
esac
# Cargo keeps build outputs in this SSD workspace; dependency sources also stay
# on the development volume. CI uses its disposable checkout.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  export CARGO_HOME="$PWD/.tools/cargo-ipad"
else
  export CARGO_HOME=/Volumes/SSD/Developer/Codex/cargo-ipad
fi
export IPHONEOS_DEPLOYMENT_TARGET=17.0
scripts/prepare-ipad-engine.sh
rustup toolchain install 1.92.0 --profile minimal --target "$target"
cargo +1.92.0 build --locked --manifest-path Engine/TinymistBridge/Cargo.toml --release --target "$target"
env -u CC -u CXX xcodebuild -project iPad/LeftBlank.xcodeproj -scheme LeftBlank-iPad \
  -destination "$destination" -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath .build/xcode-packages \
  ${diagnostics[@]+"${diagnostics[@]}"} \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO "${actions[@]}"

# Assert the actual app artifact, in addition to the package graph contract.
python3 scripts/check-ipad-mcp-boundary.py "$derived_data/Build/Products"
