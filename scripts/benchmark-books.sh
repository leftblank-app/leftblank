#!/bin/bash
# Run after scripts/test.sh. Reuses its instrumented debug test binary.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
mkdir -p build/benchmarks
status=0
# Keep the other book and preview evidence even if one scenario fails. Never
# retry a failing measurement or let an old report stand in for the current run.
python3 - <<'PYCLEAN'
from pathlib import Path
for name in ('war-and-peace.json', 'sicp.json', 'syntax.json', 'summary.md', 'book-preview-1.png', 'book-preview-224.png', 'book-preview-448.png'):
    (Path('build/benchmarks') / name).unlink(missing_ok=True)
PYCLEAN
LEFTBLANK_INTEGRATION=1 \
  LEFTBLANK_LARGE_FIXTURE="$PWD/Examples/Books/WarAndPeace/war-and-peace-highlighted.typ" \
  LEFTBLANK_PERFORMANCE_REPORT="$PWD/build/benchmarks/war-and-peace.json" \
  swift test --skip-build --enable-code-coverage --filter realMultiMegabyteDocumentNavigationScrollingAndTyping || status=1
LEFTBLANK_INTEGRATION=1 LEFTBLANK_CODE_WORD="define size" LEFTBLANK_SEARCH_WORD=procedure LEFTBLANK_BENCH_EXPORT=1 \
  LEFTBLANK_LARGE_FIXTURE="$PWD/Examples/Books/SICP/main.typ" \
  LEFTBLANK_PERFORMANCE_REPORT="$PWD/build/benchmarks/sicp.json" \
  swift test --skip-build --enable-code-coverage --filter realMultiMegabyteDocumentNavigationScrollingAndTyping || status=1
LEFTBLANK_SYNTAX_REPORT="$PWD/build/benchmarks/syntax.json" \
  swift test --skip-build --enable-code-coverage --filter bookLengthSourcesParseWithinBudget || status=1
LEFTBLANK_INTEGRATION=1 LEFTBLANK_BOOK_PREVIEW=1 \
  swift test --skip-build --enable-code-coverage --filter completeBookPreviewRemainsUsableInLargeWindow || status=1
python3 - <<'PY'
import json
from pathlib import Path
rows = ['# Book editing benchmarks', '', '| Book | Source bytes | Open (s) | First compile (s) | Typing median / p95 / max (ms) | Typing CPU max (ms) | Navigate + draw median (ms) | Scroll + draw p95 (ms) |', '|---|---:|---:|---:|---:|---:|---:|---:|']
for book in ['war-and-peace', 'sicp']:
    report = Path(f'build/benchmarks/{book}.json')
    if not report.exists():
        rows.append(f'| {book} | Report unavailable: scenario failed before completion | | | | | | |')
        continue
    r = json.loads(report.read_text())
    first = r.get('first_compile_seconds')
    first = f'{first:.2f}' if isinstance(first, (int, float)) else 'not reached'
    rows.append(f'| {book} | {r["bytes"]:,} | {r["open_seconds"]:.2f} | {first} | {r["typing_ms"]["median"]:.2f} / {r["typing_ms"]["p95"]:.2f} / {r["typing_ms"]["max"]:.2f} | {r["typing_thread_cpu_ms"]["max"]:.2f} | {r["navigation_ms"]["median"]:.2f} | {r["scroll_draw_ms"]["p95"]:.2f} |')
syntax = Path('build/benchmarks/syntax.json')
if syntax.exists():
    parsed = json.loads(syntax.read_text())
    rows += ['', '| Parser (typst-syntax) | Nodes | Full parse (ms) | Keystroke median / max (ms) | Unclosed `$` (ms) |', '|---|---:|---:|---:|---:|']
    for book in ['war-and-peace', 'sicp']:
        r = parsed[book]
        rows.append(f'| {book} | {r["nodes"]:,} | {r["parse_ms"]:.2f} | {r["typing_median_ms"]:.2f} / {r["typing_max_ms"]:.2f} | {r["unclosed_dollar_ms"]:.2f} |')
else:
    rows += ['', 'Parser report unavailable: scenario failed before completion.']
rows += ['', 'First compile: engine start to the first successful Tinymist compile, measured while the benchmark keeps working. Typing gates: 80 samples, wall p95 < 100 ms, wall max < 250 ms, main-thread CPU max < 100 ms. First input is included; no retries or discarded outliers.', '', 'Instrumented debug AppKit tests. CPU layout and bitmap painting, not display FPS. Memory excludes Tinymist and WebKit. See docs/large-document-performance.md for scope.']
Path('build/benchmarks/summary.md').write_text('\n'.join(rows) + '\n')
PY
exit "$status"
