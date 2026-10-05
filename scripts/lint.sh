#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh

mode="${1:---lint}"
case "$mode" in
  --lint|--fix) ;;
  *) echo 'Usage: scripts/lint.sh [--lint|--fix]' >&2; exit 2 ;;
esac

# Official release archives, pinned by version and SHA-256. Never use brew's
# changing latest version or a shared global install.
install_tool() {
  local name="$1" version="$2" repository="$3" archive="$4" checksum="$5"
  local directory="$PWD/.tools/$name-$version"
  if [ ! -x "$directory/$name" ]; then
    mkdir -p "$directory"
    curl --fail --location --retry 3 \
      "https://github.com/$repository/releases/download/$version/$archive" \
      --output "$directory/archive.zip"
    echo "$checksum  $directory/archive.zip" | shasum -a 256 --check
    unzip -oq "$directory/archive.zip" -d "$directory"
    rm "$directory/archive.zip"
  fi
  test "$("$directory/$name" --version)" = "$version"
}
install_tool swiftformat 0.63.1 nicklockwood/SwiftFormat swiftformat.zip \
  385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb
install_tool swiftlint 0.64.1 realm/SwiftLint portable_swiftlint.zip \
  a624aa080e825b6987ff3d54505324b42ff35953ba9b824bb608d9dd5bd80c3a

format="$PWD/.tools/swiftformat-0.63.1/swiftformat"
lint="$PWD/.tools/swiftlint-0.64.1/swiftlint"
paths=(Package.swift Sources iPad/Sources iPad/UITests iPad/Tests Tests Benchmarks scripts design)
if [ "$mode" = --fix ]; then
  "$lint" lint --fix --config .swiftlint.yml --no-cache
  "$format" "${paths[@]}" --config .swiftformat --cache ignore
fi
# Run every check even when an earlier one fails, to report every finding in CI.
status=0
"$format" "${paths[@]}" --config .swiftformat --lint --cache ignore || status=1
"$lint" lint --strict --config .swiftlint.yml --no-cache || status=1
python3 scripts/test-icon-policy.py "$lint" || status=1
exit "$status"
