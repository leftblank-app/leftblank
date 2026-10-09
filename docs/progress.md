# Implementation and verification record

Historical validation entries below describe testing before the LeftBlank rename. The renamed application identity and transferred repository require fresh signing/provisioning and CI validation before release.

Date: 2026-10-01. This record preserves evidence from each development iteration. New feature acceptance is recorded separately; historical counts and measurements refer to the stated version.

## 0.5.0 (9) follow-up · Real books and visual discovery

- Reproduced multi-megabyte input stalls and distant pointer errors with real books. Incremental metrics, revision-based reconciliation, off-main token decoding and stable contiguous text layout passed [the book benchmarks](large-document-performance.md). Current War and Peace typing median is 3.38 ms; SICP is 1.96 ms on the measured Mac. CPU draw measurements are explicitly separate from display FPS.
- The library opens a spacious visual template gallery using official thumbnails and complete project scaffolding. Package discovery has separate writing-intent collections and bilingual search.
- SICP is an on-demand example: a 1.9 MB verified download, independent editable copies, offline reuse, local imported typography and 84 illustrations. The complete books, original sources, PDFs and conversion/packaging code are committed with their own attribution and licenses.
- 108 enabled Swift tests passed (112 reported including four opt-in skips), plus three profile checks. Overall production line coverage is 86.91% (5440/6259). Both additional real-book benchmark scenarios passed, including a 448-page SICP export. Focused official-registry template/preview scenarios also passed during this iteration.
- Release-configuration build, strict development-signature verification and relocated cold-launch/resource/icon/Tinymist smoke checks passed. Version remains 0.5.0 (9); no release tag was created. Tests use checkout-local temporary directories because Xcode can override TMPDIR.
- Source-project migration is tested with an isolated cloud-container fixture. Two-Mac iCloud delivery remains unverified. See [document organization](library-and-sync.md) for entry-point semantics and current cross-file UI/search limits.

## 0.4.0 (8) · Trash controls, syntax colors and the Dock icon

- Trash has an Empty Trash action with a native confirmation and total document count, independent of search. Permanent removal coordinates the full document folder, including attachments. Confirmed identities and trash timestamps protect restored, newly trashed and re-trashed documents; a changed library location invalidates the confirmation. Partial failures preserve remaining files and report an error after refreshing the list. The operation log records counts without manuscript content.
- The editor now consumes real Tinymist semantic tokens. Fenced code uses the pinned offline Highlight.js common bundle on a background actor, with caching and size limits. Old revisions and document-switch responses are discarded. Equations still render in the page preview; inline equation widgets remain future work. See [editor rendering](editor-rendering.md).
- The bundled Sigma icon is assigned explicitly at launch, including when starting the app executable directly from a checkout. The relocated cold-launch gate requires successful icon loading.
- Local validation: **77 Swift tests passed**, plus **3 profile-validation checks**; production source-line coverage is **88.34% (4348/4922)**. New flows cover native confirmation cancellation and deletion, restore races, damaged metadata, Unicode token positions, real Tinymist highlighting, code grammars, undo and rapid document switching.
- The preceding build 7 release workflow completed Developer ID signing, provisioning-profile embedding, Apple notarization and Gatekeeper validation. Real two-Mac iCloud delivery is still unverified.


## 0.4.0 (7) · Trash without replacement drafts

Deleting the active document previously created a new Untitled as a safe landing document, so the list count did not decrease. The library now preserves pending edits, moves the document to recoverable trash and selects a remaining document. Deleting the last document shows the library itself, with no implicit draft; this state persists across relaunch. Import dialogs keep the parent window even when no editor is present. Local action logs record rename, trash and restore by document identity without titles or content.

## 0.4 acceptance follow-up · Direct document controls

- Single-click managed-document titles to rename inline; Return commits and Escape cancels. Double-click the toolbar title for the library, or a library title to open its document. Library rows provide direct trash/restore icons.
- Preview color controls retain a centered, fixed-size hit target in both states. Native menu icons use a compact intrinsic size.
- All native interface scenarios now run in a shared serialized suite, avoiding cross-test interference from AppKit's process-wide focus, menus and sheet presentation.
- Local acceptance: **70 Swift tests passed**, three profile-validation checks passed, and production source-line coverage reached **88.13% (4048/4593)**. A relocated app launched with build resources hidden, loaded its Chinese welcome document and connected to Tinymist.
- The packaged app explicitly finds localization resources in Contents/Resources. CI includes an isolated cold-launch check with diagnostic artifacts to detect checkout-dependent builds.

## 0.4.0 · Library and languages

- The title opens a searchable document library with templates, renaming, recoverable trash, source/project import and export. Stable document identities hide implementation filenames from normal writing.
- Optional iCloud Drive storage uses native file coordination, change discovery, download states and conflict protection. Independent incoming source edits merge against the editor's saved baseline with native undo, selection and focus preservation. Settings reconcile per field before publishing local changes.
- The dedicated App ID, iCloud container and Developer ID provisioning profile were configured. The release workflow now validates and embeds the profile before signing. A newly provisioned signed release and real two-Mac delivery have **not** yet been verified; isolated tests do not establish Notes-like sync performance.
- Native English and Simplified Chinese resources switch without recreating the editor. Public documentation and brand materials are English. The outline's pin lives in the left margin, becomes a close mark on hover and stays within the margin when pinned.
- An explicit Code Notes template bundles pinned Codly packages for styled code blocks. It compiles without a first-use package download. Executing code blocks is documented as a separate future feature, not enabled by the template.
- **69 Swift tests passed**, plus **3 provisioning-profile checks**. Production source-line coverage was **87.33% (3907/4474)** with an 80% gate. Tests include real Tinymist compilation, native editing/undo and PDF/page content.
- Native app acceptance checked document creation, Code Notes rendering, language/menu changes and outline placement. The final release-configuration development build is 0.4.0 (6).
- Research records cover [three-way merge and Forked](merge-evaluation.md).

### 0.4 acceptance follow-up

Real-window checks covered command search and table insertion, undo/redo, Unicode, library content search, rename, trash/restore, retained preview after a syntax error and PDF export. The exported PDF was independently opened with PDFKit and checked for the document title, table and Chinese text. Visual inspection found oversized native menu icons; their intrinsic PDF size is now bounded. Managed exports suggest the document's title.

Hosted CI exposed a Swift 6.2.4 compiler crash and a case-sensitive localized-resource lookup difference. Both were fixed. A fixed-delay form assertion was replaced with a wait for the expected accessible fields; existing text fields also refresh their localized labels. The complete **69-test** suite passed locally under both build systems, with **88.07% (3951/4486)** production coverage in the instrumented run. See [the testing strategy](testing-strategy.md) for current checks and proposed UI/screenshot layers.

## 0.3.0 · Interaction, performance and identity

- The outline became an independent left-margin overlay: fine marks at rest, gradual hover expansion, `⌘4` to pin and Esc to dismiss. The separate border, shadow, full-row highlight and close button were removed.
- Toolbar help shrank to the action name and shortcut. Direct shortcuts coexist with discovery paths: 25 frequent actions, 106 discoverable commands and distinct command/category icons.
- A fixed command-panel height and guide position keep the editor stable through search, keyboard selection and parameter forms. Hover no longer causes a selection/scroll feedback loop.
- Repeated whole-document metrics, icon decoding, queries and full-buffer style refreshes were removed from command navigation. A roughly 100,000-character benchmark is documented in [interaction and performance](interaction.md).
- **43 tests passed**: 23 core and 20 app functional tests. Production line coverage was **88.97% (2404/2702)**. Added checks cover native window geometry, narrow forms, icon resources, shortcut aliases, tooltip size, Unicode caches and long-document performance.
- The signing workflow passed real Apple notarization and Gatekeeper verification. Codecov uses GitHub OIDC, a main badge, numeric PR comments and 80% project/patch checks. See [PR #2's coverage report](https://github.com/leftblank-app/leftblank/pull/2#issuecomment-5926250299).
- The approved identity is a continuous Sigma generated from a golden-ratio skeleton and sine pressure envelope. App icons, README, social previews and favicons share its source and documented generation process. Development build 5 includes the icon.

## 0.2.0 · Discovery, reading and engineering

- 97 commands across nine root groups and nested mathematics paths. All 74 insertions and 18 math-context uses compiled with real Tinymist, including image, bibliography and multiple-file fixtures.
- The native Universe browser supports official-index search, categories, versions, documentation, pinned imports, compiler compatibility, a 24-hour cache and offline fallback. A live index smoke check found 1,636 packages, including 216 visualization packages; automated tests use isolated fixed indexes.
- Visible-region rendering, retained successful pages and explicit stale status support uninterrupted writing. Dark reading preserves exported colors. Compilation errors cannot export an old PDF as current.
- Reading styles for headings, emphasis and inline code reveal source in the active paragraph. Indentation, comments, formatting and native undo are available. Integration testing found and fixed a workspace/editor mismatch after insertion undo.
- **36 tests passed**: 22 core/protocol/compilation cases and 14 native app flows. They use `NSTextView`, Workspace, `WKWebView`, Tinymist and PDF content checks. Hidden WebKit windows drive animation frames with a timer while still running the real WASM renderer and asserting retained pages and page-count changes.
- Production line coverage was **88.65% (2163/2440)**. CI requires 80% without excluding interface files and retains LCOV, LLVM JSON and HTML.
- The public repository is [leftblank-app/leftblank](https://github.com/leftblank-app/leftblank). Release publication requires Developer ID, notarization, stapling and Gatekeeper success. Configuration and real release validation are documented in [signing](signing.md).

User edits to an existing local example were preserved and excluded from implementation commits.

## 0.1.1 · Crash-path removal and diagnostic logs

A user reported a crash after command search and insertion. The supplied stack entered an `AppDelegate` keyboard-monitor closure on the main thread and failed an executor check through `MainActor.assumeIsolated`, producing `EXC_BAD_ACCESS`. Testing table and equation paths in the old package did not reproduce the intermittent crash reliably; it was not attributed to a particular Typst command or claimed as a proven operating-system defect.

Changes:

- Removed the application-wide `NSEvent` monitor and `MainActor.assumeIsolated`. Commands now use `WritingWindow.sendEvent`, with menu shortcuts recorded through `performKeyEquivalent`. File dialogs suspend main-window command handling.
- Unified the document title and actions in `NSToolbar.unifiedCompact`, retaining system traffic lights and removing the second branding row.
- Added rotating local JSONL logs for sessions, control keys, commands, insertion, saving, export and service failures. A menu item and searchable command reveal the logs.
- Logs rotate around 1 MiB with three archives. They omit source, clipboard, search terms and parameters. Ordinary typing is only `text`; system errors can include paths.

The release build and development signature passed. **13 automated tests passed**, including persistence, cross-session append, timestamps and line-by-line JSON checks after rotation. Real UI checks searched for a table, edited parameters, inserted with Return, moved through Chinese placeholders with Tab, used undo/redo, and searched for bold and display equations without terminating the app. Logs captured `command.selected → command.execute → insertion.begin → insertion.finished` without search terms or manuscript text. Searching for the log action revealed `events.jsonl` in Finder.

The evidence supports removal of the failing execution path and regression coverage of important actions. The original intermittent crash was not reproduced reliably, so ongoing use and local logs remain relevant.

## 0.1.0 · Initial delivery

The implementation delivered a native dark writing interface, Phosphor actions, original icon, source editing, highlighting, undo, find, placeholders, 34 commands including 20 insertions, bilingual search, forms, atomic autosave, conflict protection, draft recovery, session restoration, diagnostics, completion, outline, reconnect, real unsaved preview, resizing, zoom, source/page navigation, PDF export and multiple-file compilation.

Verification used macOS 27, Xcode Swift 6.4 and an arm64 Mac, targeting macOS 14. Build and test temporary files stayed on the SSD. No database, Hurl or containers were used.

| Check | Result |
|---|---|
| `scripts/build.sh release` | Passed; app includes arm64 Tinymist |
| `scripts/test.sh` | 11 tests passed, none failed |
| `codesign --verify --deep --strict --verbose=2 build/LeftBlank.app` | Development signature passed |
| `git diff --check` | No whitespace errors |

Ten core tests covered UTF-16/emoji/CRLF positions, byte-boundary framing, malformed headers, parameter validation, string escaping, literal preservation, code fences, paragraph separation, preamble order, external modification/deletion protection, discovery and recovery data.

One real integration flow launched the production `TinymistClient` and verified:

- Local preview served the real frontend. Unsaved text compiled into PDF, including Unicode, without overwriting the source file on disk.
- Markup, math, raw and code contexts, document symbols, completion and preview navigation worked.
- Invalid source produced diagnostics and `compileError`; export failed instead of copying stale output.
- All 20 initial insertion/style/page commands compiled, including a real SVG and numbered cross-reference targets.
- Stop/restart restored synchronization, and unsaved edits to an included document appeared in the main PDF.

## Real app acceptance

The initial native UI checks covered launch, writing/split/preview views, command categories/search/forms, fast search typing isolated from the manuscript, tables, selection wrapping, placeholders, single-step undo, rejected body commands inside math, Unicode save paths, relaunch restoration, PDF export, deliberate compilation errors and recovery, double-click preview navigation, 100%→110% zoom, split resizing and a compact window around 961×526 pt.

Historical app screenshots remain in `docs/screenshots/`. They record the running application, including its then-selected Chinese interface; they are not current marketing mockups. The purple corner indicator came from macOS screen-control status. The current public sample is [Welcome.typ](../Examples/Welcome.typ).

## Known limits and unverified areas

- Complete Pinyin candidate selection and third-party input methods still need manual checks. Marked-text protection, Chinese paste, selection transformations, saving and compilation have tests.
- A physical Mac running macOS 14 and a complete VoiceOver workflow have not been verified. Benchmarks cover roughly 100,000 UTF-16 units; sustained typing/typesetting in substantially larger documents remains unverified. Intel builds are not supplied.
- One active editor buffer preserves the main compilation entry when navigating included files. General project configuration and arbitrary main-file switching remain limited.
- Page commands handle contiguous initial `#set` rules, not arbitrary functions or `#show` scopes; later rules may override earlier settings.
- Source highlighting is a visual aid. Context checks at selection endpoints are conservative, not semantic refactoring.
- Some Tinymist diagnostics lack document versions and can briefly trail fast typing.
- The release pipeline is signed and notarized as recorded separately. App Store distribution and automatic updating are not implemented.
- Preferences and document-management behavior evolve after 0.3; consult current feature documentation instead of assuming historical limits still apply.

## 0.5.0 (9): contextual assistance and unobtrusive checks

Audited the pinned Tinymist capabilities in `docs/tinymist-capabilities.md`. Added explicit documentation with active parameter help, local heading/equation code actions, and definition navigation with a return stack. New commands are discoverable through the command palette, native Edit/context menus and direct shortcuts. Actions are validated against the original URL/revision and applied as one native undo operation; unsupported cross-file/resource/snippet actions are not partially executed.

Document Checks now opens above the bottom-right status, with bounded scrolling, source navigation and quiet healthy/pending/disconnected states. It no longer consumes a sidebar or changes manuscript geometry.

Fixed a reproducible mismatch between character rectangles and insertion hit testing after reading/source attribute changes. The editor resolves visible glyph layout before pointer handling and after styling, postpones styling during native mouse tracking, and restores I-beam cursor rectangles. Regression coverage exercises multiple widths, writing/split layouts, wrapping, Chinese, emoji and composition.

Validation: 88 Swift tests and three provisioning-profile checks passed. Local source-line coverage is 88.73% (4,785/5,393), including application UI code. Real-server cases verify hover, signature parameters, heading/equation rewrites, undo/redo, stale-response rejection, cross-file definition/back and diagnostic recovery. Native geometry tests verify that a character rectangle maps back to the same insertion position and that window hit testing reaches the editor.

The 0.5.0 (9) development bundle passed strict signature verification and the relocated cold-launch smoke with its development resource bundle hidden. The updated running app was checked through the native UI: Command-5 opens the healthy popup at the bottom right, Escape dismisses it, Control-Option-H displays real Tinymist documentation, and pointer clicks inside two separate source lines place the caret at the corresponding interior columns. The user's current document was saved before restart and left unchanged.

## Editor stability and foundations (version unchanged)

Kept 0.5.0 (9), with no release tag. Reproduced typing flicker with a failing real-server regression: 23 assertions detected whole-document attribute edits and loss of semantic colors between responses. Syntax now uses differential temporary drawing attributes; reading styles have separate, source-checked background analysis and preserve AppKit's CJK/emoji fallback fonts. Explicit TextKit 1 keeps native input, selection and undo. Font/reading-mode changes are covered, including the rule that drawing invalidation must run outside storage edit batches.

Added a reusable line-boundary index for revision-based position conversion and outline batches. Moved language-service encoding, pipe writing, framing and JSON decoding off the main actor, with FIFO ordering, bounded outgoing queues and generation checks. Marked-text Escape no longer enters placeholder handling.

Validation: 94 Swift tests plus three provisioning-profile checks passed; application source-line coverage is 89.09% (5,008/5,621). Local instrumented measurements: 12,000 outline positions in a 588,000-unit document took 16.6 ms; 30 caret style transitions in a 100,500-unit manuscript took 351 ms total; native continuous typing including document metrics had a 19.8 ms P95 at 100,513 UTF-16 units. A 1 MB outgoing message enqueued while the OS pipe was deliberately blocked returned in under 0.2 ms. These are measured scenarios, not universal frame-time guarantees.

The component and ownership review is in `docs/editor-foundations.md`, including xi, VimR/NvimView, Neovim, STTextView, CodeEditTextView, Neon and TextStory. Persistence, per-revision scans, full didChange payloads and synchronous diagnostic logging remain explicit follow-up architecture work; this revision does not claim to have replaced the complete editor core.

## Visual editing on TextKit 2 (LB-019)

Both editors moved to TextKit 2 with one visual layer from `LeftBlankCore`: concealed markup with reveal at the caret, chips with a shared SwiftUI form, value labels read from the document, Repeat Previous Call with Tab placeholders, inline images and engine-typeset equations. TextKit 1, the 0.1 pt marker font, `SourcePresentation` and `ObjectScanner` were removed; code-block highlighting, object editing and preview call sites read `SyntaxTree`. Parsing and planning run on an actor; typing never waits for them.

Validation: the Mac app and Core suites (including a shared behaviour suite that also runs in the iPad test plan), the book benchmarks with jump, hit-test and scroll-drift gates, and an opt-in device benchmark on an iPad Air (M1). Measurements and the remaining War and Peace typing cost on iPad are in [visual editing](visual-editing.md#large-documents-measured).

## Attribute-only editor styles (LB-019, 2026-10-09)

The visual layer was removed on 2026-10-09 because the result was not good enough: some constructs rendered and others did not, AppKit's and UIKit's placeholder icon appeared over equations, and the styling was not pretty. Concealment, chips and their forms, Repeat Previous Call, inline equations and their engine session, inline images, list bullets and every attachment path are gone on both platforms. The editor styles the source with attributes only, the same on the Mac and the iPad: larger bold headings by level, bold strong text, italic emphasis, monospaced raw text and Tinymist's colours, with every marker visible. TextKit 2, the parser bridge and the large-document work stay. See [visual editing](visual-editing.md).
