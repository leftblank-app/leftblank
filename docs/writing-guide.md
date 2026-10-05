# Writing with LeftBlank

LeftBlank is a development preview for Macs with an Apple M-series chip, running macOS 14 or later.

Open LeftBlank from your Applications folder. The app includes its typesetting service; no separate installation of Typst, Rust or Homebrew is needed to use it. Try the [welcome document](../Examples/Welcome.typ).

The app supports English and Simplified Chinese, with the localized name **留白** and tagline **此中有真意，欲辨已忘言**. Choose **Settings → App Language** to follow your system or use either language immediately. Changing the interface language never translates or rewrites your documents.

| Action | Shortcut |
|---|---|
| Discover commands | `⌘J`, configurable as `⌘K` |
| Browse categories | `i` Insert, `s` Text Style, `p` Page Setup, `m` Mathematics, `l` Typesetting, `r` References, `c` Editing & Code, `v` Workspace, `f` Documents |
| Search commands | `/` inside the command panel; English and Chinese queries work in either interface language |
| Go back or dismiss | `Esc` |
| Move between inserted placeholders | `Tab` / `⇧Tab`; `Esc` to finish |
| Writing / side-by-side / preview | `⌘1` / `⌘2` / `⌘3` |
| Outline / document checks | `⌘4` / `⌘5` |
| New / library / save | `⌘N` / `⌘O` / `⌘S` |
| Import a document | `⇧⌘O` |
| Save as / export PDF | `⇧⌘S` / `⇧⌘E` |
| Completion / find | `⌃.` / `⌘F` |
| Go to definition | `⌘`-click, `F12` (or `fn-F12`), or `⌃⌘J` |
| Return to previous source position | `⌃⌘[` |
| Universe packages | `⇧⌘U` |

For example, `⌘J → i → t` opens the table form. Choose the row and column counts, insert, then move between cells with Tab. Select text and press `⌘J → s → b` to make it bold. Each insertion is one undoable edit. You can always write Typst directly.

The command catalog has 110 discoverable commands, including 74 insertion actions. Mathematics has nested categories for basic operations, equation structures and symbols. `⌘J → m → b → f` inserts a fraction, using the appropriate syntax inside an existing equation. Commands show their purpose, example, direct shortcut, discovery path and official reference.

Frequent actions have direct shortcuts as well as discoverable paths. `⌘]` / `⌘[` indent and outdent, `⌘/` toggles comments, and `⌥⇧F` formats the source. Hovering a toolbar button shows a compact action name and shortcut.

Command-click a variable, function, module member, label reference, or the path in an `import` / `include` to go to its definition. **Go to Definition** is also in the editor's context menu and **Editing & Code** commands. Navigation uses Typst's language service, including local modules, import aliases and external packages. Built-in functions without Typst source show contextual help instead.

Rest the pointer on a function or symbol for 400 ms to see its signature and available documentation. The compact card follows the app's light/dark appearance and never moves the caret or takes keyboard focus. Move into the card to scroll longer explanations; move away, type, scroll the editor or press Esc to dismiss it. Built-in types that only provide an official documentation link show that link. Symbols with no help produce no popup. Hover also works in read-only package source; `⌃⌥H` still opens explicit help at the caret.

When documentation includes a Typst example, the hover card opens an **Example** tab with code above its rendered result; **Explanation** shows the signature and full description. An embedded SVG or PNG is preferred. Otherwise the first example is compiled separately, including hidden documentation setup lines. The paper preview stays white in both themes. Results are cached, rendering is cancelled when the card closes, and examples never change the manuscript's preview. Examples that require unavailable files or context keep their source and a documentation link. On Mac, preview compilation uses an isolated directory, cached packages only, a three-second limit and the first output page. On iPad, touch users open **Writing Assistance → Explain at Cursor**; a mouse or trackpad also shows the hover card. Examples render in a separate embedded engine session with a five-second session timeout. Both platforms keep longer examples and explanations scrollable.

**Go Back** restores the previous file and caret, including nested jumps. `⌘W` closes the current file and returns to the previous document; `⌘Q` quits the Mac app. On iPad, `⌘W` returns from a module to the original document, or closes the main document to the library. The original document remains the compilation entry while you inspect dependencies. Your own modules stay editable; package sources display a lock and **Read-only** badge and cannot be overwritten.

The outline appears in the left margin without moving the text. Hover to explore headings, then use the small pin to keep them visible; hovering the pinned control reveals its close action. `⌘4` also pins or dismisses it. The command panel keeps a stable height through searching, selection and parameter entry; its guide stays in the same place.

## Completion and existing objects

On Mac and iPad, code completion appears after a short pause while you type.
The editor keeps focus. Use the arrow keys and Tab to accept a candidate, or tap
one on iPad. Escape dismisses the suggestions. Function calls also show parameter
help, including calls that span multiple lines. Completion preserves snippet
placeholders and creates one undo step. Chinese input composition defers these
suggestions until composition finishes. Manual completion remains available.

Place the cursor inside a table or image and choose **Edit Table or Image…**
(`⌘J → c → e` on Mac; the document actions menu on iPad). Both apps use the same
form. Tables support cells, rows, columns, a header row, cell alignment, and
rectangular tab-separated data. Image editing supports existing document
resources, a path, a numeric width, a plain caption, and alignment. Apply changes
only the selected object and creates one undo step. Cancel leaves the source
unchanged. A draft cannot overwrite a newer document revision.

This form supports literal objects, including those inserted by LeftBlank.
Generated tables, merged cells, expression-based dimensions, rich captions,
and unsupported options stay in source editing. The form does not convert
arbitrary Typst programs into visual objects.

## Images and document resources

Use `⌘J → i → i` to choose an existing image from **Document Resources** or **Import File…** to bring in a new one. Add a caption and insert. You can also drop one or more image files at a position in the editor, or paste a screenshot with `⌘V`. Ordinary text paste and text dragging keep their normal behavior.

LeftBlank saves its own copy with the document and inserts the reference for you. Moving or deleting the original file does not break the image. Images travel with the library document, iCloud sync and source-project export. Undo removes the insertion; the resource remains available for redo, document history and reuse.

PNG, JPEG, GIF, SVG, PDF and WebP keep their original format. Other macOS-readable image formats, such as HEIC and TIFF, are converted to PNG. Audio and video are not embedded in typeset pages; dropping them shows an explanation and leaves the text unchanged.

Bibliography, Include Document and Import Local Module use the same resource picker. You can also drop or paste bibliography files and self-contained `.typ` documents. For a Typst document with relative dependencies, import its whole project through the library first.

To assemble a book, open a library document, choose **Include Document → Library Documents**, and select a chapter. LeftBlank inserts a standard Typst `#include` pointing to the original article. The chapter keeps its own images and modules; changes to it appear in the book, and renaming its library title preserves the reference. **Import Local Module → Library Documents** works the same way for shared Typst definitions. Each insertion is undoable.

PDF export compiles the whole book. Source-project export currently exports only the selected article's directory; it does not bundle other library articles referenced by the book.

## Writing and preview

Editor styling gently emphasizes headings, bold, italics and inline code. Moving the caret into a paragraph reveals its full source. Copying, saving and undo always use the original text. Change editor styling in Settings.

The preview shows real typeset pages. Double-click a page to reveal the source; source selection can locate the corresponding preview position. Zoom is relative to the preview pane's fitted width. Dark preview changes screen colors only; images retain their colors and exported PDFs are unchanged.

Both platforms offer **Follow Writing** and **Return to Reading** beside the
preview controls. Follow Writing tracks the caret in side-by-side mode after a
short pause. Scrolling the preview pauses it. A preview-to-source jump remembers
your reading position; Return to Reading restores it. Zoom, window resizing and
preview reloads preserve a page-relative position. This geometric anchor does
not guarantee the same paragraph after substantial document reflow. iPad also
offers preview zoom from 50% to 200%.

While syntax is incomplete or invalid, LeftBlank retains the last successful preview and marks it as out of date. Rendering only visible page regions reduces display work; it does not mean every invalid document can compile partially. Export fails on a compilation error instead of silently exporting an old PDF.

**Universe** searches the official package index by name, purpose and category. Browse drawing or diagram packages, check their documentation, and insert a pinned version. The index is cached for 24 hours and remains available offline. Packages that need a newer typesetting engine cannot be imported through the browser.

The library presents document titles and searchable content without requiring you to manage source filenames. Import a document or an entire project folder, rename it, or move it to the recoverable Trash. Source projects remain exportable. Command-N opens Templates, with an offline blank page and an original LeftBlank guide featuring equations, a diagram, a table and numbered code. The guide’s pinned packages are included; code is displayed, not executed. New writing and existing files autosave after a short pause and retain a local recovery copy. LeftBlank preserves the current draft before switching documents, and refuses to silently overwrite a file changed by another application. **Documents → Recover Draft Copy** reopens preserved drafts.

**Documents → Document History** compares and restores the latest seven source snapshots. Edited documents create checkpoints hourly by default, or daily in Settings; unchanged documents create none. Restoration first preserves current writing and remains undoable. History stays on this Mac and covers the current source file. See [document history](document-history.md).

iCloud support is under development. It requires a properly provisioned release and an iCloud Drive account; local development builds clearly report when unavailable. Real two-Mac delivery and conflict recovery remain release checks. See [sync status and limitations](library-and-sync.md).

## Diagnostic logs

Use **View → Open Diagnostic Logs** or `⌘J → v → g` to reveal `~/Library/Application Support/LeftBlank/Logs/events.jsonl`. The current log rotates at about 1 MiB and retains three archives.

Logs record sessions, versions, event order, command/navigation keys, insertion and save/export outcomes, selection ranges and service failures. Ordinary typing is recorded only as a `text` event. Document text, clipboard contents, search terms and field values are not logged. System error messages may contain file paths. Logs stay on the Mac; keep them alongside a macOS crash report when investigating a problem.
