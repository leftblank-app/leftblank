# Authoring guides for coding agents

LeftBlank's MCP exposes application-owned creative workflows as a discoverable,
read-only catalog. An agent can translate a vague document request into a brief,
select a suitable example, write editable Typst, and inspect the result using the
existing document tools. The server does not run a second language model or make
creative decisions for the client.

## MCP discovery and loading

Guides use the standard [MCP Resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources)
and [Prompts](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts)
interfaces. Document operations remain Tools; there are no guide-reading tools.

- `prompts/list` lists a prompt per guide, including a description, bilingual
  keywords, and the required string argument `request`.
- `prompts/get(name, arguments: {request})` returns messages containing the
  workflow as an embedded resource, supporting resource URIs, and the supplied
  request. It prepares context for the client's model; it does not run a model.
- `resources/list` exposes all bundled guide files with exact URIs, descriptions,
  and MIME types. `resources/read(uri)` returns bounded UTF-8 content.
- `tools/list` and `tools/call` expose actual document operations such as
  `create_document`, `apply_patch`, `compile_document`, and `render_page`.

`prompts/list` has no standard natural-language search argument. The client or
user selects a prompt from the returned descriptions, then passes the user's
request to `prompts/get`. MCP describes prompts as user-controlled, commonly
exposed as slash commands, while allowing other host interaction patterns.
Server instructions can suggest discovery, but cannot make a host automatically
select or execute a prompt. A client that only exposes Tools will not discover
these guides until it also supports Resources or Prompts.

An agent with resource access can alternatively read a workflow directly, without
invoking a prompt. The user's explicit requirements take precedence in either
path. Simple text edits need not load an unrelated workflow.

Example protocol sequence (JSON-RPC envelopes and transport metadata omitted):

```text
prompts/list
prompts/get {"name":"dimensional-drawing","arguments":{"request":"画一张设备外壳尺寸图，尺寸暂未提供"}}
resources/read {"uri":"leftblank://guides/dimensional-drawing/drawing-kit.typ"}
resources/read {"uri":"leftblank://guides/dimensional-drawing/product.typ"}
resources/read {"uri":"leftblank://guides/dimensional-drawing/license.txt"}
```

Each guide has one prompt. Each catalog file has one concrete URI of the form
`leftblank://guides/<id>/<path>`. Only exact catalog entries can be read: caller
URIs are never normalized into filesystem paths. There are no parameterized
resources, so `resources/templates/list` returns an empty list.

Namespaced `_meta` fields describe application semantics, not extra MCP methods:
`app.leftblank/authoringGuide` contains `id`, `version`, and `fallback`;
resource metadata also contains `app.leftblank/path` and `app.leftblank/entrypoint`.
When no specialized guide fits, the client can select the described general
fallback. Human-readable descriptions remain sufficient for selection.

All catalog lists fit in a single response; an unexpected cursor is rejected.
Resources and Prompts are immutable during a helper's lifetime, so their optional
change/subscription capabilities are not advertised. For protocol 2026-07-28,
list/read responses use `ttlMs: 0` and `cacheScope: private`, requiring a fresh
fetch after an app update. Legacy clients retain their version's response shape.
Unknown resources, unknown prompts, and invalid prompt arguments return JSON-RPC
InvalidParams errors rather than tool error payloads.

These bundled resources contain no user documents and remain available with
read-only or document-scoped grants. Creating/editing their copied source still
uses normal Tools permissions and expected revisions. Prompt retrieval does not
grant access to a document or authorize a write.

## Initial workflows

| Guide | Purpose | Runnable examples |
| --- | --- | --- |
| `dimensional-drawing` | Monochrome UI/product drawing sheets with dimensions, views, details, and assumptions | `main.typ`: component card; `product.typ`: physical enclosure |
| `xiaohei-illustrations` | White 16:9 explanatory scenes for articles and presentation inclusion | `main.typ`: attention leak; `feedback.typ`: reshaping a paper aircraft |
| `general-authoring` (fallback) | Research official Typst documentation, Universe packages and versioned examples; prove an approach before expanding | `main.typ`: package-free experiment with actual compiler version; `research-notes.md`: provenance/review record |

The two visual workflows include a method, a small native Typst kit, two entry
examples, and source attribution/license text. The fallback adds a package-free
probe and research record. All bundled examples need no external package,
browser, image-generation API, or raster asset. The Xiaohei adaptation keeps
labels and geometry editable; its look is a native sketch approximation, and
quality still depends on adapting the visual action to the content.

The guide explains the limits of the output path. LeftBlank MCP does not thereby
gain image generation, arbitrary binary import, or PPTX export. A slide-sized
Typst document is not a PowerPoint deck. An agent may use separately available
capabilities when requested, but must describe what it actually delivered.

## Extending the catalog

Content lives in `Sources/LeftBlankCore/AuthoringGuides/`, one directory per guide:

```text
AuthoringGuides/
  catalog.json
  dimensional-drawing/
    guide.md
    drawing-kit.typ
    main.typ
    product.typ
    license.txt
  xiaohei-illustrations/
    guide.md
    illustration-kit.typ
    main.typ
    feedback.typ
    license.txt
  general-authoring/
    guide.md
    research-notes.md
    main.typ
    license.txt
```

Both package manifests use `.copy("AuthoringGuides")` to preserve that hierarchy
inside the shared resource bundle. Guides can reuse filenames such as `guide.md`
and `main.typ`; catalog paths are relative to the directory named by the guide ID.

To add a capability such as mathematical presentations or arXiv paper authoring:

1. Add a guide explaining triggers, intended output, required input, treatment of
   uncertainty, a practical workflow, and actual verification/delivery limits.
2. Add reusable Typst source and at least one complete example. Declare only
   runnable example files as `entrypoint: true`. Relative imports use logical
   sibling paths, not bundle resource names.
3. Add attribution and applicable license information. Check the availability of
   fonts, packages, export formats, and external capabilities the workflow needs.
4. Append an entry to `catalog.json` with a stable unique `id`, `title`,
   `summary`, `version`, bilingual `keywords`, and `files`. Each file descriptor
   contains `path`, `description`, and optional `entrypoint`. Mark a general
   fallback guide with `fallback: true`; specialized guides default to false.
5. Verify all resource references, compile each entry example using its logical
   project filenames, inspect rendered pages, and cover discovery/read behavior.

Resource and prompt descriptors are generated from the same catalog in the
shared Swift layer. No Swift switch over guide IDs, new domain-specific drawing
tool, or transport change is needed. A catalog descriptor looks like:

```json
{
  "id": "a-future-guide",
  "title": "A descriptive workflow title",
  "summary": "When an agent should choose this workflow.",
  "version": "1.0.0",
  "keywords": ["short discovery terms", "中文关键词"],
  "files": [
    {"path": "guide.md", "description": "Workflow."},
    {"path": "main.typ", "description": "Complete example.", "entrypoint": true},
    {"path": "license.txt", "description": "Source attribution and license."}
  ]
}
```

The mathematical-presentation and arXiv examples above describe future extension
directions; they are not shipped catalog entries. Paper guides should distinguish
research claims and verified citations from placeholders. Mathematics guides
should preserve editable equations and check the actual mathematical content,
in addition to page layout.

## General fallback and package research

The fallback teaches an agent to turn an unfamiliar request into a brief, search
[Typst Universe](https://typst.app/universe/) using its available network tools,
read the candidate's versioned documentation and minimal example, check compiler
requirements and licensing, then test one representative page in LeftBlank's
actual engine. It records source URLs, selected versions, unresolved dependencies,
and visual review. Package imports pin the version that was actually inspected.

LeftBlank currently exposes document tools rather than MCP package-search or
package-source-reading tools. The guide relies on the client's existing web/HTTP
capabilities for research and the application's engine for package resolution.
Without those research tools, it uses supplied/project examples or native Typst
and states what could not be verified. A local CLI's successful compile does not
establish that the app engine can resolve the same packages, fonts, or assets.

## Verification and acceptance

The normal loop is brief -> source -> `compile_document` -> `render_page` ->
inspection -> revision. Compilation checks syntax and available inputs, while
rendering reveals collisions and readability. Tool output can report incomplete
or unverified results; the agent must retain those limits. If rendering fails,
the result has not passed visual inspection.

Automated tests can materialize catalog files under their logical names and
discover entry examples from the metadata, so new guides receive the same engine
checks. Run Hurl MCP contract scenarios in GitHub CI under the repository's
existing test policy. Do not test against private user documents.

For behavior acceptance, connect a client with no separately installed authoring
skill and use a vague request such as "画一张工业尺寸图" or "给这一页做张小黑配图".
Check that it discovers a suitable guide, identifies the takeaway and unknowns,
adapts a source example, and inspects the rendered result. These prompts test the
complete agent experience; schema and compilation tests alone cannot establish
creative quality or client-side guide selection.

Also try a request with no dedicated guide, such as a mathematical presentation.
Check that the client browses to the fallback, reads authoritative documentation
for a suitable package if needed, pins an inspected version, and tests one page
before expanding. Without network tools, it should state that research limit
and use available material instead of inventing package APIs.

## Attribution

The first workflows adapt [dimensional-drawing](https://github.com/enesozturk/dimensional-drawing)
by Enes Ozturk and [ian-xiaohei-illustrations](https://github.com/helloianneo/ian-xiaohei-illustrations)
by Ian. Their pinned revisions and complete MIT notices are included in each
guide's `license.txt`. No upstream example image is bundled.
