# Authoring guides for coding agents

LeftBlank's MCP exposes application-owned creative workflows as a discoverable,
read-only catalog. An agent can translate a vague document request into a brief,
select a suitable example, write editable Typst, and inspect the result using the
existing document tools. The server does not run a second language model or make
creative decisions for the client.

## Discovery and loading

`list_authoring_guides(query?, limit?, cursor?)` lists guide metadata. The query
accepts short descriptive terms, including the catalog's Chinese and English
keywords. Leave the query empty to browse. Use returned cursors rather than
constructing them. A query with no match returns an empty list; it does not claim
that an unsupported workflow is installed.

`read_authoring_guide(id, path?)` reads one file from a selected guide. Omitting
`path` selects `guide.md`. The response includes the guide metadata, the requested
logical path and text, and its available files. The file list's `entrypoint`
boolean identifies runnable examples; it is false for helper modules and prose.
File paths are exact catalog entries, not arbitrary filesystem access. The tools
are available even for read-only or document-scoped connections because bundled
guides contain no user document data.

Example sequence:

```text
list_authoring_guides(query: "工业 尺寸")
read_authoring_guide(id: "dimensional-drawing")
read_authoring_guide(id: "dimensional-drawing", path: "drawing-kit.typ")
read_authoring_guide(id: "dimensional-drawing", path: "main.typ")
read_authoring_guide(id: "dimensional-drawing", path: "license.txt")
```

The agent can then create a document using the example's text as `main.typ`, add
the helper file with `apply_patch`, and adapt both to the user's material. Existing
documents still require normal reads and expected revisions. Guides do not bypass
grants, revision checks, or write permissions.

Server instructions and tool descriptions direct visual creation tasks to the
catalog. They are guidance to the connected agent, not a guarantee that every
host automatically loads or follows the workflow. The user's explicit style and
scope take precedence. Simple text edits need not load an unrelated guide.

## Initial workflows

| Guide | Purpose | Runnable examples |
| --- | --- | --- |
| `dimensional-drawing` | Monochrome UI/product drawing sheets with dimensions, views, details, and assumptions | `main.typ`: component card; `product.typ`: physical enclosure |
| `xiaohei-illustrations` | White 16:9 explanatory scenes for articles and presentation inclusion | `main.typ`: attention leak; `feedback.typ`: reshaping a paper aircraft |

Each workflow includes its method, a small native Typst kit, two entry examples,
and source attribution/license text. The examples need no external package,
browser, image-generation API, or raster asset. The Xiaohei adaptation keeps
labels and geometry editable; its look is a native sketch approximation, and
quality still depends on adapting the visual action to the content.

The guide explains the limits of the output path. LeftBlank MCP does not thereby
gain image generation, arbitrary binary import, or PPTX export. A slide-sized
Typst document is not a PowerPoint deck. An agent may use separately available
capabilities when requested, but must describe what it actually delivered.

## Extending the catalog

Content lives in `Sources/LeftBlankCore/Resources/AuthoringGuides/`. SwiftPM's
existing `.process("Resources")` rule bundles the files. Because processing can
flatten resource directories, every physical resource basename must be unique.
Logical paths within a guide remain short and portable.

To add a capability such as mathematical presentations or arXiv paper authoring:

1. Add a guide explaining triggers, intended output, required input, treatment of
   uncertainty, a practical workflow, and actual verification/delivery limits.
2. Add reusable Typst source and at least one complete example. Declare only
   runnable example files as `entrypoint: true`. Relative imports use logical
   sibling paths, not bundle resource names.
3. Add attribution and applicable license information. Check the availability of
   fonts, packages, export formats, and external capabilities the workflow needs.
4. Append an entry to `authoring-guides.json` with a stable unique `id`, `title`,
   `summary`, `version`, bilingual `keywords`, and `files`. Each file descriptor
   contains `path`, `resource`, `description`, and optional `entrypoint`.
5. Verify all resource references, compile each entry example using its logical
   project filenames, inspect rendered pages, and cover discovery/read behavior.

No Swift switch over guide IDs, new domain-specific drawing tool, or transport
change is needed. A catalog descriptor looks like:

```json
{
  "id": "a-future-guide",
  "title": "A descriptive workflow title",
  "summary": "When an agent should choose this workflow.",
  "version": "1.0.0",
  "keywords": ["short discovery terms", "中文关键词"],
  "files": [
    {"path": "guide.md", "resource": "future-guide.md", "description": "Workflow."},
    {"path": "main.typ", "resource": "future-example.typ", "description": "Complete example.", "entrypoint": true},
    {"path": "license.txt", "resource": "future-license.txt", "description": "Source attribution and license."}
  ]
}
```

The mathematical-presentation and arXiv examples above describe future extension
directions; they are not shipped catalog entries. Paper guides should distinguish
research claims and verified citations from placeholders. Mathematics guides
should preserve editable equations and check the actual mathematical content,
in addition to page layout.

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

## Attribution

The first workflows adapt [dimensional-drawing](https://github.com/enesozturk/dimensional-drawing)
by Enes Ozturk and [ian-xiaohei-illustrations](https://github.com/helloianneo/ian-xiaohei-illustrations)
by Ian. Their pinned revisions and complete MIT notices are included in each
guide's `license.txt`. No upstream example image is bundled.
