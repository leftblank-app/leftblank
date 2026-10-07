# Editor foundations review

Reviewed October 1, 2026. This work keeps version 0.5.0 (9). Bug fixes do not automatically create a new version or release tag.

## Decision

Keep AppKit's native text system as the default editor while separating input, presentation, document indexing and service transport. The observed flicker came from LeftBlank's whole-document styling and palette switching, not evidence that NSTextView itself must be replaced. A replacement must pass the same behavioral tests and show a measured benefit before migration.

The current implementation is not a rope editor and does not claim constant-time editing of arbitrarily large files. Native NSTextStorage owns the editable attributed buffer and undo operations. Workspace holds a plain value snapshot for services and persistence; syntax and presentation retain revision-specific snapshots too. These can occupy multiple document-sized allocations. Adding a rope beside them would add another owner unless these consumers are redesigned together.

## Changes in this revision

| Boundary | Implementation and contract |
| --- | --- |
| Native input | TextKit 2 (`NSTextContentStorage` and `NSTextLayoutManager`) on both platforms; AppKit and UIKit own selection, composition, clipboard, find and undo. No custom character insertion pipeline. `layoutManager` is never touched (it would switch the view to TextKit 1); SwiftLint rejects it. Placeholder Escape handling yields to marked text. |
| Syntax | TextKit 2 rendering attributes, separate from the source's font and paragraph attributes. Pending semantic results retain prior colors; native edits move those ranges. Matching replies write changed runs only. Syntax never changes fonts or layout. |
| Reading presentation | The visual layer's display paragraphs ([visual editing](visual-editing.md#e-the-delivered-editor)). Parsing and planning run on an actor; the main thread rebases the last plan across each edit and invalidates only paragraphs whose display changed. Plans wait while text is marked. |
| Layout | Viewport layout only; no full-layout pass. Jumps reveal targets precisely rather than through `scrollRangeToVisible`; hit tests after a jump use laid-out viewport fragments. Color responses do not force layout. |
| Position index | A reusable UTF-16 line index holds offsets, not another string. LF, CRLF and CR share consistent conversions. Outline batches reuse one revision index instead of scanning the document for each heading. |
| Language transport | JSON encoding, pipe writes, framing and decoding run on dedicated serial queues. FIFO preserves edit/request ordering; service generations reject old deliveries. Outgoing queued snapshots are capped by count and estimated bytes, disconnecting a stalled service rather than blocking typing or growing indefinitely. |

CotEditor demonstrates the separation of syntax colors into drawing-only layout attributes. Neon provides a useful model for versioned ranges, deferred invalidation and layered token providers. This change independently implements a small native boundary; it does not copy their editor cores. Sources: [CotEditor syntax application](https://github.com/coteditor/CotEditor/blob/828e325ba369393be016090976c3b956b4497e85/CotEditor/Sources/Models/Syntax/NSLayoutManager%2BSyntaxHighlight.swift), [Neon](https://github.com/slsrepo/Neon).

## Reusable components evaluated

| Candidate | Fit for LeftBlank |
| --- | --- |
| [xi-editor](https://github.com/xi-editor/xi-editor) | Persistent ropes, cheap snapshots, deltas and asynchronous expensive work are relevant design references. The project explicitly declares development discontinued. Do not adopt its core as a newly maintained dependency. |
| [VimR](https://github.com/qvacua/vimr) | A credible route to an optional Neovim backend, with a reusable Cocoa view and Swift API. Detailed evaluation below. |
| [STTextView](https://github.com/krzyzanowskim/STTextView) | A native TextKit 2 replacement candidate with an editor feature set. Its current [license](https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md) offers GPLv3 or a commercial license. Evaluate both distribution fit and input/accessibility behavior before adoption. |
| [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) | MIT, focused on line-oriented code editing. Its README explicitly excludes complete system text-view feature parity and directs RTL/custom-layout use elsewhere. A less direct fit for general writing and mixed typography. |
| [Neon](https://github.com/slsrepo/Neon) | BSD-3-Clause and text-system independent; useful incremental styling machinery. Its README says current main is not release-ready. A pinned, bounded prototype is preferable to adding an unpinned core dependency. |
| [TextStory](https://github.com/johnrbent/TextStory) | BSD-3-Clause NSTextStorage helpers and mutation buffering. Worth evaluating if precise edit transactions become necessary, without replacing native input. |

## VimR and Neovim

Source review uses VimR revision `ad069d307c57656f4225a8f4e0090e95679b0e66`. This is a source/API evaluation, not a completed integration benchmark.

VimR's MIT-licensed `NvimView` wraps an NSView, input-method integration, grid drawing and Neovim startup. `NvimApi` exposes synchronous/asynchronous RPC. This removes substantial work compared with building a macOS Neovim frontend ourselves. Its current implementation launches a bundled child process with `--embed --listen`; it does not link Neovim into LeftBlank's process. References: [package](https://github.com/qvacua/vimr/blob/ad069d307c57656f4225a8f4e0090e95679b0e66/NvimView/Package.swift), [process startup](https://github.com/qvacua/vimr/blob/ad069d307c57656f4225a8f4e0090e95679b0e66/NvimView/Sources/NvimView/NvimProcess.swift).

The package uses sibling local packages (`Commons`, `Tabs`, `NvimApi`) and generated/copied Neovim executable/runtime resources. Reuse requires a pinned source/build integration; a single remote SwiftPM dependency is not sufficient as the tree stands. The component README is still a placeholder, so source-level maintenance is part of the cost.

Its renderer consumes Neovim's line grid and draws dirty cell regions. Different fonts and arbitrary block heights within a paragraph, such as large reading headings or inline typeset equations, are not supplied by that grid contract. Its `NSTextInputClient` implementation is valuable, but is not equivalent to inheriting the whole NSTextView accessibility/selection stack. References: [drawing](https://github.com/qvacua/vimr/blob/ad069d307c57656f4225a8f4e0090e95679b0e66/NvimView/Sources/NvimView/NvimView%2BDraw.swift), [input integration](https://github.com/qvacua/vimr/blob/ad069d307c57656f4225a8f4e0090e95679b0e66/NvimView/Sources/NvimView/NvimView%2BKey.swift).

"Neovim takes over" means ownership, not a requirement to expose modal keys to everyone. An insert/select-oriented configuration is possible. However, buffers, undo, text selections, edits and service attachment still need one authoritative owner. Using NvimApi headlessly behind an independently editable NSTextView would require a reliable bidirectional edit/selection/undo bridge; two independently authoritative buffers are not a shortcut.

If prototyped, use NvimView as an isolated, optional source editor. LeftBlank would continue to own the library, coordinated saving, iCloud, preview and agent permissions; Neovim would own the editing buffer and undo. Configure isolated runtime/init paths rather than loading arbitrary user configuration by default. Route edits through the buffer API, consume revisioned change events, choose one Tinymist/LSP owner and explicitly mediate `:write` with LeftBlank's persistence. Neovim's official [API documentation](https://github.com/neovim/neovim/blob/master/runtime/doc/api.txt) documents subprocess embedding and libnvim as separate integration choices.

Acceptance gates before enabling an alternate backend: Chinese/Japanese/Korean composition; combining marks, emoji and bidirectional text; pointer/drag selection across wrapped lines; clipboard and native shortcuts; VoiceOver; undo across snippets, formatting and agent edits; clean restart/recovery; 100 KB/1 MB/10 MB typing and paste measurements; memory after repeated document switches; preview, library and cloud conflict preservation. Grid-based source editing may be a good optional mode even if mixed reading typography remains native.

## Remaining work found by the audit

These are explicit limits, not claims of completed fixes:

1. **Persistence:** autosave is debounced but coordinated file/recovery writes still run on the main actor. Move all save paths through one serialized persistence owner, with revision acknowledgments and transition barriers. Moving only the timer closure to a detached task risks stale overwrites, resurrection after Trash and incorrect saved-state reporting. Existing external-edit/recovery/cloud tests must remain the acceptance gates.
2. **Per-edit document work:** native character transactions now update the affected lines and grapheme counts incrementally, including adjacent boundaries. Full replacements and grouped storage mutations that lack one reliable transaction rebuild the index. Presentation analysis still scans full source in the background, and suffix line offsets shift linearly with the line count. A rope or indexed tree is not required by the measured 1.45–3.3 MB cases, but larger files need a separate benchmark. See [real-book measurements](large-document-performance.md).
3. **Transport volume:** full didChange snapshots remain. Move to ordered UTF-16 edit transactions only after native undo and composition all produce the same validated deltas. Queueing and encoding now avoid UI-thread pipe stalls, but do not make payloads incremental.
4. **Diagnostic logging:** per-key records still use small synchronous disk writes to preserve crash evidence. A bounded queued logger needs an explicit flush policy and truthful timestamps/drop accounting before replacing that behavior.
5. **Large files and accessibility:** current integration benchmarks do not establish a universal latency/memory bound or complete VoiceOver compatibility. Profile retained snapshots and native layout before selecting rope/piece-table storage or a replacement view. Metal does not fix redundant scans, cross-thread ownership or blocked I/O.

## Regression evidence

The new continuous-typing scenario failed on the old implementation with 23 assertions: whole-document attribute rewrites and semantic colors reverting while a response was pending. It now verifies unchanged syntax colors, zero unrelated storage edits, stable selection/viewport and real Tinymist responses.

Additional checks cover native grouped undo/redo during long-document typing, stale document switches, font-size and reading-mode changes, CJK/emoji fallback, pointer geometry, marked text, mixed newline indexing and a genuinely blocked OS pipe. Tests use production text views, real pipes and the real language server rather than a separate mock editor.

Local debug measurements are recorded in progress notes. CI uses broader timing bounds to tolerate instrumentation/shared runners; passing them is not a claim that every operation meets a 16 ms frame budget.

## Real-book follow-up

The 3.3 MB fixture exposed whole-string equality in caret styling and a complete grapheme count on every native input. Revision IDs now guard style plans, semantic snapshots and SwiftUI editor reconciliation. Native text-storage transactions update metrics locally, and semantic token position decoding runs outside the UI actor.

TextKit 1 noncontiguous layout was also reproduced shifting a rendered line by 27 points during the first pointer hit after a distant jump; the TextKit 2 editors avoid the analogous estimated-geometry errors with precise reveal and viewport hit tests, and the book benchmarks gate on landing every jump with zero hit error. Measurements and limits are in [large-document-performance.md](large-document-performance.md); this is not a claim about arbitrary file sizes.
