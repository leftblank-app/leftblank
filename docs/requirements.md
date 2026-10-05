# LeftBlank product requirements

Established 2026-10-01. This document records the first release's product contract; later enhancements are documented separately.

## Purpose

Build a macOS writing app that can be used every day. Writers can concentrate on their words, discover common actions through one entry point, generate correct source with a few interactions, and see the actual finished pages as they write.

The initial acceptance document is an article containing headings, lists, images, code, equations, tables and cross-references. Users must be able to save it reliably, reopen it and export it as PDF. Both English and Chinese writing matter.

## Product choices

1. Edit and save Typst directly, without a Markdown conversion layer.
2. Use Swift, SwiftUI for interface composition, AppKit for text editing, and Tinymist for language and typesetting services.
3. Begin with a dark theme inspired by Nano Emacs: generous space, a fine status bar, restrained color and assistance that appears when needed.
4. Keep familiar macOS editing, input-method behavior and ordinary spaces.
5. Use `⌘J` for hierarchical command discovery, with a configurable entry shortcut. Users should not have to memorize every command.
6. Preserve source access, with restrained highlighting and structural assistance. The writing surface need not look exactly like the paginated output.
7. Keep ordinary `.typ` source and relative assets compatible with external tools. A managed library may simplify how documents are presented without locking away their source.
8. Use Phosphor Regular consistently for app actions, while retaining native system window controls.
   CI enforces this with the `phosphor_icons_only` SwiftLint rule: use `PhosphorIcon` on macOS and `TabletIcon` on iPad. SF Symbols initializers (`systemName`, `systemImage`, `systemSymbolName`) are rejected in application sources. `scripts/test-icon-policy.py` verifies both rejected calls and allowed comments, strings and shared components using the pinned linter.

## Main workflow

The app opens a welcome document or the previous session. The writing is the visual center; the title and save status remain quiet, with lightweight statistics and command discovery below.

`⌘J` opens a panel with categories such as Insert, Text Style, Page Setup, Workspace and Documents. Users enter a category by letter or search for a command. A short explanation and, when needed, a small parameter form lead to an insertion with editable placeholders.

Users can switch between writing, side-by-side preview and full preview. Unsaved edits update the preview. Compilation errors do not prevent editing and can reveal their source position. PDF export uses the same compilation environment.

## Acceptance criteria

### Documents

- Create, open, save and save copies of UTF-8 documents, including Unicode paths.
- Save existing files atomically and preserve recovery copies for untitled drafts.
- Restore the recent document after relaunch. Clearly report write failures; never claim that failed writes were saved.
- Preserve local edits when another application changes the same file. Offer reload or save-as without silently overwriting.
- Resolve relative images and included documents from the document's directory; support a main compilation entry.
- Show headings in an outline with source navigation. Keep standard menus and shortcuts for common document actions.

### Editing

- Support native typing, selection, clipboard, undo/redo, find/replace and soft wrapping.
- Avoid replacing the buffer or applying disruptive styling while an input method has marked text.
- Apply highlighting through display attributes only, without changing source or polluting undo.
- Provide a comfortable line width, adjustable text size, line spacing and margins, including in small windows.
- Distinguish headings, comments, strings, code and equations with a limited palette.
- Keep all source editable and accurately mapped before adding folding or visual editing features.

### Discoverable commands

- Toggle the panel with `⌘J`; use `Esc` to return through levels and restore editor focus on dismissal.
- Include Insert, Text Style, Page Setup, Workspace, Documents and command search.
- Show available keys and localized names; support keyboard and pointer navigation.
- Search English and Chinese names and keywords, regardless of the interface language.
- Insert headings, lists, links, images, code blocks, inline/display equations, tables, labels, references and footnotes.
- Wrap selected text or insert editable examples when nothing is selected.
- Validate concise forms such as table dimensions and image paths.
- Treat each insertion as one undoable edit. Move through placeholders with Tab and Shift-Tab.

### Preview and language feedback

- Use real typesetting output, including unsaved changes.
- Preserve the last successful preview during temporary errors, clearly identifying stale output.
- Provide diagnostics with source navigation, explicit completion and an outline.
- Keep writing and saving available when the language service stops, with a visible reconnect action.
- Support source-to-preview and preview-to-source navigation, including included files.

### Export

- Export the latest requested document version as PDF.
- Fail clearly on compilation errors; do not copy a stale PDF and report success.
- Preserve document colors regardless of the preview's reading theme.

### Appearance and accessibility

- Use charcoal surfaces, comfortable high-contrast text and a restrained warm accent.
- Keep spacing, fine separators and icon sizes consistent, without ornamental cards or large gradients.
- Give icon-only actions accessibility labels and compact learning hints.
- Support full keyboard operation and visible focus. Do not communicate state through color alone.
- Inspect writing, split preview, command categories, search, forms, diagnostics and a narrow window in the running app.

## First-release boundaries

The initial release excludes collaborative accounts, hosted cloud services, built-in AI authorship, a plugin marketplace, Vim emulation, arbitrary visual editing of typeset pages, Markdown round-tripping and App Store distribution. These historical boundaries do not prevent later iCloud enhancements.

Compatibility follows the bundled Tinymist/Typst version. Command forms cover common features, while direct source editing remains available for everything else. Deliverables include a working app, source, reproducible scripts, dependency licenses, documentation and an honest verification record.

## Completion criteria

1. The build and automated tests pass, including significant failure paths.
2. Real app interactions cover typing, command insertion, save/reopen, preview updates and PDF export.
3. Real Tinymist verifies language services and unsaved-buffer preview.
4. Actual screenshots are inspected and obvious layout problems are fixed.
5. Documentation distinguishes verified behavior from unverified limitations.

References: [Nano Emacs](https://github.com/rougier/nano-emacs), [Spacemacs which-key](https://www.spacemacs.org/doc/DOCUMENTATION.html#which-key), [Typst](https://typst.app/docs/), [Tinymist](https://myriad-dreamin.github.io/tinymist/), [Phosphor](https://github.com/phosphor-icons/core).
