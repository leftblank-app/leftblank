# Interaction and performance · 0.3

## Behavior

- Frequent actions have one-chord shortcuts. Which-key organizes discovery without requiring the complete path every time. The catalog supplies shared metadata to toolbar, command list, guide and native menus. Outline supports both `⌘4` and `⌘J → v → o`.
- The 0.3 catalog has 106 commands with individually assigned Phosphor Regular icons and 12 distinct category icons. Typesetting changes the document; Workspace changes the application interface; Editing & Code covers editing, syntax, modules and Universe.
- Compact actions show native hover help after 300 ms, with the name and shortest shortcut. The popover sizes to its content rather than expanding into a large card.
- The outline is an independent margin overlay that does not change text width. Fine marks expand on hover and collapse 180 ms after leaving. `⌘4` pins it; Esc or another `⌘4` dismisses it. The 0.3 design removed a separate border, shadow, full-row highlight and close control. Narrow windows use a subtle editor-color fade for readability.
- Command discovery occupies a fixed 320 pt bottom panel. Categories, search results, empty state and parameter forms share the same outer geometry. A fixed guide shows syntax and shortcuts. Pointer hover changes row background without moving keyboard selection or scrolling. Keyboard navigation only brings the target into view.
- Forms use two columns with internal scrolling, verified at an 820×540 pt window. The category grid supports directional navigation in three columns.

## Control design

The document title and writing actions explicitly disable the native toolbar
item border. On macOS 26, this also removes the automatically added Liquid Glass
capsule; a SwiftUI plain button style alone does not remove that container.
Traffic lights, toolbar positioning and native keyboard behavior remain AppKit's.

Toolbar glyphs use the same Phosphor Regular family at 16 pt inside 30 pt targets.
The library uses a pair of pages instead of detailed book spines. The selected
writing mode has an accent glyph and a fine underline, with no second box inside
the toolbar. Hover and press use a restrained neutral wash. The same interaction
style covers compact pane controls, outline header actions and document checks;
outline and preview controls use 14 pt glyphs inside 28 pt targets. Pin-to-close
crossfades without rotating the symbols. The compact pinned outline fits inside
the 36 pt source margin and has no opaque backing that could hide the first
character. Disabled zoom actions stop at the limits.

Command categories and command rows both mark keyboard selection at the leading
edge, avoiding a grid of competing borders. Diagnostic lists use a quiet flat
surface and hairline instead of a dark drop shadow. Light and dark colors come
from the shared dynamic palette. Learning hints, VoiceOver names and full-target
pointer clicks remain available in both appearances.

The broader audit covers the library, template and package discovery, Settings,
history comparison and insertion forms. Those surfaces retain their existing
layout and native form controls. Featured drawing, chart, code, table, glossary
and science packages have recognizable individual symbols; ordinary package
cards use category symbols in neutral ink, with accent reserved for selection.

## Performance work

- Phosphor PDF images are cached by name rather than repeatedly opened and parsed during view updates.
- Search uses a normalized index and reuses result sets while query/group remain unchanged. Examples and discovery paths are cached. Indexed row iteration removes repeated searches.
- Each source revision builds word metrics and a UTF-16 line index once. Caret positions use binary search. Query and selection changes do not rescan the whole document.
- Source highlighting retains source-style and reading-style snapshots. Movement within one paragraph does no attribute work; crossing paragraphs restores only the previous and current ranges. Source, font or styling changes rebuild snapshots. Regexes are compiled once and excluded ranges use binary search.
- The editor tracks its applied font separately instead of using a mixed attributed string's font property to decide whether to restyle everything. Native undo and marked-text protection remain intact.

No custom Metal renderer was added. The measured bottlenecks were repeated CPU work, file reads and unnecessary layout coupling.

## Benchmarks and regression checks

Measurements used the same Mac, a Swift Debug build, and a real `NSTextView` document of 100,500 UTF-16 units. One test performed 500 command selections while reading search results, word count and caret position. Another moved the caret across paragraphs 30 times and refreshed real attributed text. Service startup and initial cache construction are excluded; these are not frame-rate measurements.

| Path | Before | First measurement after changes |
|---|---:|---:|
| 500 command-selection computations | 17.549 s | 0.0035 s |
| 30 paragraph-style refreshes | 13.438 s | 0.189 s |

Functional tests assert identical manuscript frames/insets with the outline expanded or collapsed, stable editor geometry through search/selection/forms, equivalent native shortcuts and discovery paths, cache updates after insertion/undo/font/Unicode selection changes, loadable icons and hover content no taller than 48 pt. Loose 1 s / 3 s performance thresholds allow coverage instrumentation and shared CI runners.

## Identity

The approved monochrome Sigma uses an ivory continuous stroke on charcoal, suggesting separate thoughts coming together into writing. A golden-ratio skeleton and sine pressure envelope generate ICNS, SVG, social previews and favicons from one source. ICNS includes 16–1024 pixel representations, with optical correction at small sizes. See [construction](../design/sigma/README.md) and [brand assets](../Brand/README.md).

## Context and document checks

Document Checks lives at the bottom right. Its compact status distinguishes successful compilation, pending changes, warnings/errors and a disconnected service. Clicking it or pressing Command-5 opens a bounded floating list above the footer; it never changes the manuscript's width. Clicking an issue reveals its source and dismisses the list. Escape and an outside click also dismiss it. A successful document gets a short, quiet confirmation instead of an empty sidebar.

Four commands are available from Editing & Code, the Edit menu and the native editor context menu:

- Explain at Cursor: Control-Option-H, or leader `c h`.
- Actions at Cursor: Command-period, or leader `c q`.
- Go to Definition: Control-Command-J, or leader `c d`.
- Go Back: Control-Command-[, or leader `c b`.

Explanations combine Tinymist documentation and active function parameters. Actions include heading depth and equation layout transformations. Requests are explicit, operate on unsaved writing and never block text input; moving the cursor, typing or switching documents invalidates pending help. Applied actions are one native undo operation. Help and action surfaces have bounded widths and scroll when necessary.

## Reading long documents

Outlines with at most 24 headings initially show every section. Longer outlines
start with top-level headings and the ancestors of the current editing section.
A chevron folds an individual branch; clicking its title navigates. One small
header action expands all headings when any branch is folded; once fully expanded,
its icon and action switch to collapse all. Both commands are discoverable through
`⌘J → v → e` and `⌘J → v → c`. Manual folds are saved locally per document using
ancestry/title identities, so prose edits and reopening preserve them. Renaming a
heading or moving it to a different parent gives that branch a new identity.

The margin minimap divides the **entire** heading list into at most 18 marks.
Scrolling away from the caret tracks the first visible source text; the active
bucket stays gold even at the end of a book. The open outline highlights the
nearest visible ancestor when the active section is folded. Scrolling never
moves the insertion caret or silently reopens a manually folded branch.

The writing surface has no header or styling control; reading styles are configured
in Settings and remain discoverable through `⌘J → v → t`. Preview controls sit in a
small overlay without a reserved header row. Hovering or activating its label reveals
controls; hovering away fades them back. Light/Dark colors, zoom, retained-preview notices and return-to-main actions
never reduce the page viewport. The native document title measures its text and
uses available toolbar width before truncating, preserving click-to-rename and
double-click-to-open-library behavior.

Explicit source jumps (outline, definition, previous location) also reveal the
corresponding preview position when the preview is visible. Requests wait for both
a successful compile and a rendered preview, and are discarded after document or
source revision changes. Ordinary selection and scrolling do not move the preview.
Clicks originating in the preview do not trigger a reverse navigation loop.

The SICP fixture has natural prose wrapping; its original code newlines remain.
The editor uses a centered, adaptive writing column with 36 pt minimum margins.
Ordinary panes retain the familiar 740 pt column; wider panes grow to 70% of the
editor pane, capped at 1080 pt. A 1440 pt editor pane therefore provides 1008 pt
for writing, while a 1920 pt pane provides 1080 pt. Split layouts use the editor
pane's width rather than the full window. The outline shares the same margin
calculation, so pinning it never changes the text width. Width changes reflow
prose rather than inserting source hard wraps.

In side-by-side layout, dragging the divider sets the editor's share of the
window; its 10 pt target shows a resize pointer, and double-clicking restores
equal panes. Each pane keeps at least 280 pt and at most 80% of the area, and the
ratio, not the width, follows window resizing. The ratio is stored in local
defaults rather than synced preferences because screens differ between devices.
iPad uses the same shared `SplitLayout` model with a 44 pt touch target,
double-tap reset and its own `iPadSplitFraction` value. Both expose the divider
to VoiceOver as an adjustable control. The preview stays mounted while it is
resized, and its reading anchor is kept across repeated resize events.

This default follows the distinction between readable line length and available
screen space. [Bear](https://bear.app/faq/typography-options/) and
[Ulysses](https://help.ulysses.app/dive-into-editing/editor-customization-guide)
offer line-width preferences;
[Obsidian](https://obsidian.md/help/settings) offers a readable-line-length
toggle; [Typora](https://support.typora.io/Width-of-Writing-Area/) supports custom
writing and source-mode widths. LeftBlank's 70% proportion and 1080 pt cap are
its own design choices, not measured defaults from those editors. This change
improves the default layout without introducing another preference.
