# Real-book editor performance

Measured on 2026-10-08, Apple M4 Pro, macOS 27.0, the TextKit 2 editor with
the visual layer ([visual editing](visual-editing.md#e-the-delivered-editor)),
Tinymist 0.15.8 / Typst 0.15.1; iPad numbers are in the same section. These are instrumented debug test runs, not a
release-mode FPS claim. Both fixture sources, licenses and generators are in
[Examples/Books](../Examples/Books/README.md).

## Workload and results

The 3.3 MB War and Peace fixture preserves the downloaded novel and adds 39
small, distributed Python/math/Unicode blocks. SICP is the complete original
Scheme second edition: 1.45 MB of manuscript, 1,098 Scheme blocks, 1,356 math
expressions and 84 SVG figures. It imports its own local typography module.
Neither book is repeated to manufacture a larger buffer.

| Book | Source bytes | Open (s) | Typing median / p95 / max (ms) | Navigate + draw median / max (ms) | Scroll + draw p95 (ms) |
|---|---:|---:|---:|---:|---:|
| war-and-peace | 3,302,718 | 0.56 | 5.52 / 5.75 / 6.87 | 7.14 / 10.13 | 2.56 |
| sicp | 1,446,633 | 0.52 | 3.78 / 4.15 / 4.64 | 14.83 / 25.01 | 2.98 |

Both books land all six jumps in the viewport with zero hit-test error, and a
line returns to the same place in the viewport after scrolling three screens
away and back. TextKit builds about 1,300 of War and Peace's 67,963
paragraphs and 1,000 of SICP's 20,512 over the whole run; the benchmark fails
above 5,000, because every edit walks the elements built after it. The previous TextKit 1 editor (2026-10-01) opened War and Peace
in 4.09 s and SICP in 3.32 s, typed at 9.29 / 52.23 and 6.70 / 10.88 ms
(median / max), navigated in 4.20 and 6.07 ms median, and scrolled at 5.04 and
3.89 ms p95. SICP ended at 219.4 MiB (287.8 before).

SICP exported to **448 pages** in 0.21 seconds after engine startup.
The test/editor process ended at 222.0 MiB for War and Peace and
219.4 MiB for SICP (290.7 and 287.8 with TextKit 1). These are process physical-footprint snapshots,
not peak memory and not total application memory: Tinymist and WebKit are separate
processes. Each current report comes from its own fresh test process.

The earlier War and Peace run had a 619.3 ms median / 628.1 ms maximum synchronous
typing path. The current run measures 9.29 / 52.23 ms. Opening the
buffer increased from 1.37 to 4.09 seconds because contiguous layout was
restored for reliable pointer geometry. The earlier run failed distant pointer
round-trip checks; current checks pass. Its scrolling measurement only included
layout, so it is not directly comparable to the new draw measurement.

Raw reports: [War and Peace](benchmarks/war-and-peace.json) and
[SICP](benchmarks/sicp.json) on TextKit 2; [War and Peace](benchmarks/war-and-peace-textkit1.json)
and [SICP](benchmarks/sicp-textkit1.json) on TextKit 1; and the
[earliest War and Peace run](benchmarks/war-and-peace-before.json).
Absolute timings vary with hardware, instrumentation, caches and background load.

## What changed

- Native text-storage edits carry a replacement range into the document metrics.
  Grapheme counts and UTF-16 line positions rescan neighboring lines and shift
  later offsets. Emoji, combining marks and CRLF boundaries are checked against
  full recomputation over 240 deterministic edit transactions.
- Swift strings backed by AppKit UTF-16 storage are materialized once for full
  grapheme scans. Frequent styling and UI reconciliation compare revisions,
  avoiding repeated multi-megabyte String equality on the UI thread.
- Semantic-token decoding runs off the main actor. Embedded-language analysis is
  cached and bounded; the offline Scheme grammar covers the real book's code.
  Nested highlight spans keep their specificity when their ranges coincide.
- TextKit 2 lays out only the viewport, so opening no longer lays out the
  whole book (TextKit 1 needed contiguous layout for reliable pointer
  geometry). Its estimated geometry is handled explicitly: jumps reveal their
  target precisely, the restored caret is revealed after the first layout pass
  (before it, TextKit lays out every paragraph above it and each keystroke pays
  for them), and the first visual plan is computed before layout, so it never
  invalidates a laid-out book.

## iPad

iPad Air (5th generation, M1), iPadOS 26.5, `TabletLargeDocumentTests` on the
production editor ([how to run it](visual-editing.md#reproduce-the-spike)):

| Book | Typing median / p95 (ms) | Jumps on target, tap error | Jump median / max (ms) | Memory after typing (MiB) |
|---|---:|---:|---:|---:|
| sicp, before | 870 / 945 | – | 143 / 276 | 322 |
| sicp | 33–48 / 34–49 | 6/6, 0 | 42–83 / 145–239 | 268–287 |
| war-and-peace, before | did not finish 80 keys in 15 minutes | – | – | – |
| war-and-peace | 96–101 / 97–151 | 6/6, 0 | 152–154 / 390–401 | 802–835 |

Ranges are over runs. The causes and what remains are in
[visual editing](visual-editing.md#large-documents-measured).

The native text storage remains authoritative; we did not introduce a second
rope buffer or a terminal editor with another selection/undo model. These fixes
address measured costs. Line-index suffix shifts are still O(number of lines),
not a claim of constant-time edits or unlimited document size. Full-document
semantic snapshots, synchronous save boundaries and background analysis can
still consume time and memory; see [editor foundations](editor-foundations.md).

## Reproduce and interpret

```sh
scripts/test.sh
scripts/benchmark-books.sh
```

The second script reuses the instrumented test binary. It runs on each PR in CI
and uploads `build/benchmarks` plus a job summary. No fixture download is required.
Each scenario uses production Workspace, NSTextView and real Tinymist:

1. Open a complete source and wait for semantic highlighting; assert a known
   built-in inside a fenced code block has the embedded-language color. Settle
   the pending native layout and paint the initial viewport before interaction
   timing starts; report this separately as `initial_presentation_ms` and the
   total opening-to-ready time as `editor_ready_seconds`.
2. Jump among six distant offsets, apply styles, force layout and draw the
   visible region into a bitmap. Require each target's glyph inside the visible
   rect, and map it back to a native insertion point with zero error, rather
   than only checking a selection integer.
3. Search later text and scroll through 60 frames with native visible-region
   layout and bitmap painting. Scrolling three screens down and back must show
   the first visible line at the same place in the viewport (TextKit 2 moves
   the clip origin when it replaces estimated heights, so positions are
   compared within the viewport).
4. Insert 80 mixed Latin/CJK/emoji characters through the native editor, include
   metric reads, then undo and verify the original source exactly.
5. For SICP, export through Tinymist and require more than 400 PDF pages.
6. Open the 448-page book in a 1920 × 1300 pt WebKit preview. Jump to pages
   1, 224, 448 and back to 1; require visible SVG glyphs and snapshots with
   actual painted text, with no canvas fallback surfaces. CI retains page
   snapshots alongside timing reports. Real-window acceptance also covers
   scrolling from the cover to page 448 and back to page 340.

The test uses a hidden native window and CPU bitmap rendering. It does not
measure physical display refresh, GPU compositing, human typing latency,
continuous wheel/trackpad events, or the full asynchronous autosave/preview cycle.
Typing samples time the synchronous editor/Workspace/metrics path. The first
input is included, with no warm-up discard or automatic retry. For 80 inputs,
CI requires wall-time p95 below 100 ms, every input below 250 ms wall time,
and every input below 100 ms of main-thread CPU work. Navigation still has a
200 ms maximum, including drawing. Thread CPU time helps distinguish work in
the synchronous input path from time when a shared runner does not schedule
that thread; it is not a substitute for the wall-time latency gates.

The earlier 16-input sample made p95 equal to max. Main run 36952826611 failed
on one 102.47 ms input, while its median was 12.23 ms. That report did not
record per-input CPU time, so it cannot prove the outlier was scheduler noise.
Reports now retain every input's wall, thread CPU, insert and metrics timing.
The policy rejects sustained slow input and severe individual stalls while
allowing an isolated short scheduling delay. These are instrumented-debug CI
regression budgets, not a hardware-independent performance SLA.

All book scenarios run even when one fails, and the script returns failure if
any fails. Stale reports are cleared first; the summary and artifacts retain
available evidence from the failing run. Real-window acceptance complements
these tests; it does not replace them.
