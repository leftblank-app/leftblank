# Tinymist capabilities for writing

This audit targets the bundled **Tinymist v0.15.8**, not an assumed latest server or the combined behavior of its VS Code extension. The server's [initialization response](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist/src/lsp/init.rs) is the capability inventory. Editor UI, text storage, accessibility and undo remain LeftBlank responsibilities.

## Existing integration

| Capability | How LeftBlank uses it |
| --- | --- |
| Document synchronization | Unsaved buffers are sent through `didOpen` and `didChange`; saving sends `didSave`. The preview sees the current buffer without overwriting the source file. |
| Diagnostics and compilation status | Compiler errors and warnings retain source locations; failed compilation keeps the last successful preview. Document checks expose these results. |
| Semantic tokens | Typst syntax colors use the negotiated token legend and validated UTF-16 positions. Responses for old revisions are discarded. |
| Completion | Explicit syntax completion uses `textDocument/completion`. The native editor inserts the chosen result. |
| Document symbols | The manuscript outline uses `textDocument/documentSymbol`. |
| Formatting | Explicit document formatting uses the server's formatter, followed by a native undoable replacement. |
| Syntax context | `tinymist.interactCodeContext` distinguishes markup, code, math and raw text for context-aware insertion. |
| Preview and source navigation | `tinymist.doStartPreview`, `tinymist.scrollPreview` and source-jump notifications connect the page and editor. Preview starts with partial rendering enabled; short documents are painted completely so scrolling never reveals blank pages. |
| PDF export | `tinymist.exportPdf` renders the current compilation entry and unsaved content. |

Semantic tokens do not replace embedded-language grammars. A real v0.15.8 probe classified a Rust raw block body as `text`, while the Typst `#let` outside it received keyword and number tokens. Typst itself still highlights language-tagged code in the rendered document. LeftBlank uses a local Highlight.js grammar bundle for foreign-language code in its editable source view. See [editor rendering](editor-rendering.md).

## Selected additions

The most useful immediate additions make unfamiliar syntax discoverable without interrupting typing:

| Capability | Interaction and scope |
| --- | --- |
| Hover documentation | An explicit contextual help action requests `textDocument/hover` at the caret. Show the readable signature and explanatory paragraphs in a compact panel. Convert Markdown to inert text; do not load hover images, HTML or remote resources. |
| Signature help | Request `textDocument/signatureHelp` with contextual help. Show the active parameter and its explanation as well as the function signature. Long function signatures belong in a constrained, scrollable help surface. |
| Code actions | An explicit contextual action menu shows complete, safe `textDocument/codeAction` edits. Examples verified against the real server include increasing/decreasing heading depth and converting inline equations to block or multiline equations. Apply all edits as a single undo operation, only if the original document URL and revision still match. |
| Go to definition and back | Use `textDocument/definition` for user functions, variables and references. Retain the originating location so inspecting a definition does not lose the writer's place. Local document and external-project boundaries must be handled explicitly by the app. |

These requests are demand-driven. Do not issue hover, signature and action requests for every keystroke or replace the native typing path with a server round trip. Existing typing, selection, IME and undo continue while a help request is pending. Both a late response and a clicked action need revision checks.

### Code-action compatibility boundary

`LanguageAssistance.codeActions` accepts only plain, local edits to the exact requested document. It validates LF, CRLF and CR line boundaries, UTF-16 scalar boundaries, declared versions, all ranges, ordering and overlap before returning an action. It rejects the entire action if any constituent edit is unsupported. It never silently applies just the local portion of a larger workspace edit.

Commands, file creation/rename/deletion, other documents, change annotations and snippet edits are not enabled. The pinned server marks heading and equation rewrites as plain text (`insertTextFormat: 1`), but some quick fixes use snippet format (`2`) even when the inserted string looks simple. Those are intentionally filtered until LeftBlank has a complete snippet transaction implementation. In particular, “Create missing file” requires resource operations and is outside this first integration. The app must not advertise support for resource operations or snippet actions it cannot faithfully execute.

Hover and signature decoding accepts LSP MarkupContent, MarkedString values/arrays and UTF-16 parameter-label offsets. Text stays inert and bounded in size. This does not claim a full Markdown renderer or inline equation widgets.

## Useful follow-ups

| Capability advertised by v0.15.8 | Decision |
| --- | --- |
| Selection ranges | A good next enhancement: expand selection from a token to its expression/block. Keep native selection and IME behavior intact. |
| Document highlights and references | Useful for labels and user-defined symbols. Add subtle occurrence highlighting and an explicit references list after definition navigation is established. |
| Prepare rename / rename | Valuable for variables and labels. Defer until LeftBlank can preview and atomically apply workspace edits across files, preserving unsaved buffers and undo. |
| Document colors / color presentations | Useful when choosing fills and text colors. Defer to a small contextual color control, not permanent visual clutter in prose. |
| Folding ranges | Potentially useful for lengthy setup blocks. Defer until hidden-text selection, source offsets, copy, accessibility and undo are reliable. The outline already handles navigation. |
| Inlay hints | Keep off by default; constant type/value annotations are distracting in a writing app. Consider an explicit assistance mode. |
| Document links | Useful for references and imports, but opening a returned target needs a deliberate local-file/URL policy and user gesture. |
| Workspace symbols | Useful for multi-file projects; current writing-first library search already covers titles and content. |
| Range formatting | Useful for selected setup code; a smaller follow-up to whole-document formatting. |
| Code lenses | Defer until there is a clear writing workflow for each action and command execution is explicitly supported. |
| Experimental on-enter | Defer; validate its interaction with native indentation and input methods first. |

Inline formula rendering remains a separate project. Server hover/periscope images are not a stable API for exact equation bounds, baselines or source-preserving AppKit attachments. Reuse the real Typst renderer when adding that layer; do not maintain a second approximate mathematical renderer.

## Verification

`LanguageAssistanceTests.swift` covers inert documentation extraction, parameter selection, Unicode/CRLF edits, stale document versions, malformed and overlapping ranges, cross-document edits, commands, annotations, snippets and mixed resource operations. Its real-server scenario opens an unsaved document, queries hover and signature help, requests heading and equation transformations, applies the returned edits and verifies that disk content is untouched.

Run only these scenarios during development with:

```sh
source scripts/environment.sh
LEFTBLANK_INTEGRATION=1 swift test --filter 'languageAssistance|realTinymistLanguageAssistance'
```

The focused run passed six tests against the pinned binary. Application-level acceptance still verifies UI placement, late-response handling, native undo and navigation.

## Primary sources

- [Advertised server capabilities](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist/src/lsp/init.rs)
- [Hover implementation](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/hover.rs)
- [Signature help implementation](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/signature_help.rs)
- [Code-action requests](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/code_action.rs), [transformations](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/analysis/code_action.rs) and [edit protocol](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/code_action/proto.rs)
- [Semantic-token implementation](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/analysis/semantic_tokens.rs)
- [Typst raw text and rendered code highlighting](https://typst.app/docs/reference/text/raw/)
