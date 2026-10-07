#!/bin/bash
# LB-019 spike: reproduce every measurement in docs/visual-editing.md.
#   scripts/visual-editing-spike.sh [--skip-ipad]
# Reports land in build/visual-editing/ (JSON per platform, parser/baseline logs).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
root="$PWD"
out="$root/build/visual-editing"
mkdir -p "$out"
rm -f "$out"/*.json "$out"/*.log
books=("$PWD/Examples/Books/WarAndPeace/war-and-peace-highlighted.typ" "$PWD/Examples/Books/SICP/main.typ")

scripts/build-syntax-xcframework.sh
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  export CARGO_HOME="${CARGO_HOME:-/Volumes/SSD/Developer/Claude/cargo-home}"
fi
cargo +1.92.0 test --release --manifest-path Engine/SyntaxBridge/Cargo.toml
cargo +1.92.0 run -q --release --manifest-path Engine/SyntaxBridge/Cargo.toml --example bench -- "${books[@]}" \
  | tee "$out/parser-rust.jsonl"

# Today's regex scan, for comparison with the parser.
swiftc -O -module-name Baseline Sources/LeftBlankCore/SourcePresentation.swift \
  Benchmarks/VisualEditing/Baseline/main.swift -o "$out/source-presentation"
"$out/source-presentation" "${books[@]}" | tee "$out/source-presentation.jsonl"

cd Benchmarks/VisualEditing
status=0
LB019_REPORT_DIR="$out" swift test || status=1
for book in "${books[@]}"; do
  LB019_REPORT_DIR="$out" LB019_FIXTURE="$book" swift test --skip-build \
    --filter 'LargeDocumentTests|ParserBenchmarkTests' || status=1
done
if [ "${1:-}" != --skip-ipad ]; then
  device="$(python3 - <<'PY'
import json, subprocess
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
ipads = [d for runtime, ds in devices.items() if 'iOS' in runtime for d in ds if d['name'].startswith('iPad Pro')]
print(ipads[0]['udid'])
PY
)"
  for book in "${books[@]}"; do
    TEST_RUNNER_LB019_REPORT_DIR="$out" TEST_RUNNER_LB019_FIXTURE="$book" xcodebuild test \
      -scheme VisualEditingSpike -destination "platform=iOS Simulator,id=$device" \
      -derivedDataPath "$out/DerivedData" > "$out/ipad-$(basename "$book").log" 2>&1 || status=1
    grep -E 'Test run|TEST (SUCCEEDED|FAILED)' "$out/ipad-$(basename "$book").log" || true
  done
fi
for report in "$out"/lb019-*.json; do python3 "$root/scripts/visual-editing-summary.py" "$report"; done
exit "$status"
