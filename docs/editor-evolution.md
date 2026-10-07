# Writing features and engineering quality · 0.2

This iteration completed command discovery, feedback and recovery while establishing the public repository and repeatable testing and release processes.

## Product behavior

- `⌘J` remains the discovery entry point. Categories follow writing intent, with nested groups for mathematics. English and Chinese search show paths, purpose, examples and official references while retaining familiar direct shortcuts.
- Insertion uses structured parameters and Tab placeholders as one undoable edit. Markup, math and preamble placement follow context. A document or caret change during an asynchronous query cancels the insertion.
- Universe reads the official package index, searches names, purpose and categories, and shows versions and documentation. Imports pin versions. The index supports offline browsing; Tinymist obtains package code when compilation needs it.
- Preview supports original page colors and dark reading. Dark reading changes only the screen, not source or PDF output; images retain their colors.
- Tinymist explicitly renders visible regions. Pending or failed compilation keeps the last successful preview with a stale indicator. A first failure presents an actionable state. Visible-region rendering is not arbitrary partial compilation of invalid source.
- Optional editor styling handles headings, bold, italics and inline code conservatively. The active paragraph shows full source while other paragraphs soften syntax markers. Display attributes never rewrite source, clipboard content or undo records. Code, comments and math are excluded, and marked text defers style changes.
- Indent, outdent, comments and formatting complement native selection, find, undo and input methods.

## Architecture and acceptance

SwiftUI, AppKit/NSTextView, LeftBlankCore and pinned Tinymist remain the foundation. An importable app library and thin launcher let tests exercise the real workspace, native editor and language-service process. Filesystem and user state use isolated test directories.

The coverage target is at least 80% of all first-party core and app Swift lines, reported per file. UI files are not excluded to inflate results. Functional integration takes priority: discovery → parameters → insertion → placeholders → undo; file conflicts and recovery; real compilation, export and multiple files; preview failure and recovery. Small parsing and boundary tests complement these flows. Real app checks cover visuals and interaction.

GitHub Actions builds on macOS arm64, runs functional tests and coverage, and uploads reports and app artifacts. Matching version tags trigger Developer ID signing, Apple notarization and stapling before publishing a ZIP and checksum. Missing credentials or failed checks stop publication. Ordinary CI builds remain development-signed. Local temporary files stay on the SSD; CI uses runner storage.

## Scope

Arbitrary Typst functions and package templates are not converted into visual widgets. (Superseded for literal-argument calls with a visible `#let` signature by the [visual editing plan](visual-editing.md); content-bearing calls and templates still stay source.) Equations and diagrams appear in the real preview. Future embedded previews must retain document context and source mapping. This iteration does not change exported colors or introduce system-wide key recording.

References: [Tinymist preview configuration](https://myriad-dreamin.github.io/tinymist/config/vscode.html), [Typst packages](https://github.com/typst/packages), [Typst scripting and packages](https://typst.app/docs/reference/scripting/).
