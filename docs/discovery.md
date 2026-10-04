# Template and package discovery

LeftBlank treats a template as a starting document and a package as a tool for the current document. The two intents share the official catalog, but have separate collections and actions.

## Starting a document

**Command-N**, the New Document menu item and the matching discovery command open Templates. The library has one **Browse templates** action. Templates and the library use the same sheet; opening discovery while the library is already visible changes its contents without stacking another sheet. The blank page remains one explicit choice, always available offline, independent of old template preferences.

The gallery begins without a selected community item or a detail pane. **Ink for your thoughts** and SICP share a compact opening row when space allows, with **Blank page** beside the section title. These three starters appear only in All templates. Narrow windows stack these starting points. The community grid follows under its own heading. Selecting a community card opens its details and keeps that card visible as the grid changes width. Back to results closes the details while preserving the browsing position; changing the query, collection or intent clears the selection. An unseen first result is never selected automatically.

Two built-in choices lead the gallery: **Ink for your thoughts**, LeftBlank's original editable guide, and **Blank page**. A first launch starts with the guide in the selected app language and a side-by-side preview. Choosing the guide again also opens its preview. Switching languages never replaces existing writing, and recovery always wins over new welcome content. The guide combines prose, headings, inline and display equations, a table, a CeTZ diagram and a Codly code block. It introduces the outline, command discovery, preview, library and export with ordinary writing examples. Both English and Simplified Chinese versions have centered page numbers and the approved LeftBlank sigma mark in the opening header. The cover follows the app language. The source is a normal Typst document with explicit pinned imports and a relative `leftblank-mark.svg` asset. The mark is copied into the document project, retained by source-project export, and generated from the same geometry as the app icon. Existing manuscripts and their assets are never replaced by a language or app update. CeTZ 0.5.2, its oxifmt 1.0.0 dependency and Codly 1.3.0 ship as source with their licenses, so both built-in choices compile without a network request. Other Universe templates may download package code on first creation. Built-in choices remain visible when the catalog cannot be reached.

The original guide is in `Sources/LeftBlankCore/Resources/Templates`, with an English copy in `Examples/Welcome.typ` and a generated first-page thumbnail. To regenerate its thumbnail with the pinned engine, run:

```sh
source scripts/environment.sh
scripts/bootstrap.sh
mkdir -p build/welcome-check
.tools/tinymist compile --package-path Resources/Packages Sources/LeftBlankCore/Resources/Templates/Welcome.typ build/welcome-check/welcome.pdf
pdftoppm -f 1 -singlefile -scale-to 520 -png build/welcome-check/welcome.pdf Sources/LeftBlankCore/Resources/Templates/welcome-cover
```

The guide follows the official tutorial's progression from text to notation and reusable tools; examples and prose are original. These are editorial choices for usefulness, not a claimed popularity ranking. Mode controls and collection chips use their full visible bounds as hit targets.

The template gallery uses actual versioned thumbnails from Typst Universe. Missing images have a clearly labeled typographic placeholder, not a fabricated document preview. Selecting a template reveals its description, license, version, author, documentation, and a **Create document** action. In wider windows the details remain beside the grid. Below 850 points the selected detail replaces the grid, with an explicit Back to results action. The sheet fits the writing window and grows to 1040 by 720 points; the ordinary library grows to 980 by 680 points.

Collections combine the official technical categories into writing tasks:

- Research and study: papers and theses.
- Work and reports: reports, letters, invoices, and office documents.
- CVs and applications.
- Slides and posters.
- Books and writing.

Creating a template runs the bundled Tinymist `tinymist.doInitTemplate` command through a separate short-lived service. This reuses the official package resolver, versioned download cache, and TOML parser without stopping the current document's service. The result is validated and imported as an independent managed project, preserving images, bibliography files, and subdirectories. The staging directory is removed afterward. The previous writing stays open until the new project is available. Browsing alone creates no documents and downloads no package code.

## Downloadable example books

The template gallery's All templates collection includes a SICP card with an
original typographic cover, source/license link and **Add to my writing** action.
It also matches SICP and bilingual book searches. No book is downloaded at app
launch. Adding it downloads about 1.9 MB, verifies the pinned SHA-256 and byte
count, and imports a complete editable copy with all 84 illustrations and local
styles. The archive is cached for offline reuse. Each addition has a new library
identity; editing one copy cannot change another or the cached original.

The ZIP has a content-addressed filename in `Examples/Books/SICP`, published via
the public repository. `scripts/package-sicp.py` reproducibly builds it from the
reviewed sources. The app's size and digest constants must be reviewed together
when updating an example. The source PDF and upstream Texinfo are committed for
inspection but omitted from this download. Attribution and CC BY-SA 4.0 travel
with every copy. Download errors stay in the discovery surface and can be
retried; failed or cancelled downloads never replace the current writing.

## Finding tools while writing

The existing Universe command opens the Packages intent. Its collections are diagrams and charts, math and science, code and algorithms, layout and typography, tables and data, and writing tools. Templates are excluded from this list.

Search matches package names, descriptions, keywords, categories, disciplines, and bilingual intent synonyms. Exact name and literal query matches take precedence over broader synonyms. A small explicit editorial list gives useful packages a starting position in the unfiltered catalog; this is not a popularity or quality score. Search remains available offline from the saved index. Incompatible engine versions remain visible for discovery, with the create/import action disabled and a reason shown.

**Insert import** preserves the existing native, undoable insertion path and pins the chosen version. Package documentation remains the authority for setup and examples. An empty library can browse packages, but must open a document before inserting one.

## Responsiveness and storage

The catalog store constructs the searchable index once off the UI actor. The browser computes results when its query, collection, intent, or snapshot changes, rather than searching again for every card render. Lazy grids keep view creation proportional to visible cards.

Thumbnails load asynchronously from the official versioned `packages.typst.org/preview/thumbnails/` endpoints. Responses are bounded to 5 MiB and images are downsampled to at most 600 pixels before display. The decoded image cache is limited to 32 MiB / 60 entries, the URL cache to 48 MiB on disk, and concurrent connections to four per host. A normal URL session persists that cache across launches; cookies and credential storage are disabled. Duplicate in-flight requests share a task; once the last requesting view leaves the screen, its download is canceled. Cancellation does not count as a failure. Failed images have a five-minute cooldown, and explicit Refresh clears it so a restored connection can retry immediately. Missing previews never block a search or document creation.

The app includes a metadata-only catalog snapshot for first-launch offline discovery. The network disk cache takes precedence and appears before a background refresh. Search, collection changes and switching Templates/Packages operate on the same local index; tab changes do not request the index again. A fresh cache is valid for 24 hours. Refresh requests have an eight-second inactivity limit and a fifteen-second total transfer limit, with a 12 MiB streaming size cap. A failed refresh preserves the displayed catalog, and closing discovery cancels its request. See the [snapshot provenance](../Sources/LeftBlankCore/Resources/Universe/README.txt) and [update script](../scripts/update-universe-snapshot.py).

Community template creation and the first SICP download still require a connection unless already cached; the welcome guide and blank page are fully included. An explicit Cancel action interrupts pending downloads and leaves the current writing open. Browsing package metadata does not download or execute package code.

Discovery uses the package catalog and bilingual search. No document text, click history, or query is uploaded to a recommendation service.

## Verification

Functional tests use controlled slow/error/canceled transports to check stale-index search while a refresh is pending, repeated tab changes without additional requests, first-launch bundled search, and cancellation/retry of offscreen thumbnail downloads. They also cover cached/offline catalog behavior, bilingual search and mode switching, narrow/wide native rendering, no document changes while browsing, source/asset validation, and an opt-in network path through the official registry and real Tinymist to a managed document and PDF. The app-level network scenario also verifies that creation opens the new managed document, preserves the previous writing, and cleans the staging directory.

```sh
source scripts/environment.sh
LEFTBLANK_INTEGRATION=1 LEFTBLANK_UNIVERSE_NETWORK=1 swift test --filter 'universe|Universe|templateGallery|templateCreationOpens|cachedPackageBrowser|discoveryModel'
```

The network scenarios are opt-in so ordinary CI is deterministic. Set `LEFTBLANK_DISCOVERY_ARTIFACTS` to an SSD-backed directory to save the 620- and 1040-point gallery renders for visual inspection.

Native-window acceptance also checks selection while the gallery reflows: select
`basic-resume` from All templates, confirm its outlined card stays visible beside
its matching details, then return to the full-width list without losing the row.
Repeat after scrolling several rows down, and verify the grid has no horizontal
offset after returning. This checks actual on-screen geometry, beyond rendering
an unselected hosted view.

## Primary references

- [Typst tutorial](https://typst.app/docs/tutorial/)
- [CeTZ documentation and examples](https://typst.app/universe/package/cetz/)
- [Codly documentation and examples](https://typst.app/universe/package/codly/)
- [Official Typst package catalog](https://packages.typst.org/preview/index.json)
- [Typst packages repository and template manifest documentation](https://github.com/typst/packages)
- [Tinymist template scaffolding implementation](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist/src/cmd.rs)

## A future Chinese book sample

The strongest next candidate is [Dive into Deep Learning in Chinese](https://github.com/d2l-ai/d2l-zh): an extensive Chinese technical book with equations, illustrations, and executable Python examples. It complements SICP with a modern applied subject. Its chapter-based Markdown sources also fit LeftBlank's existing source-project model. This is a recommendation, not a bundled or converted book in this release.

Use the book's own attribution and licensing, rather than inferring everything from the repository badge: its [publication configuration](https://github.com/d2l-ai/d2l-zh/blob/master/config.ini) identifies CC-BY-SA-4.0 and MIT-0, while the repository also includes an Apache-2.0 license. A conversion should preserve notices, credit the authors, identify modifications, and check externally sourced figures.

[Hello Algo](https://github.com/krahets/hello-algo) is more approachable and visually rich, but its [CC-BY-NC-SA-4.0 license](https://github.com/krahets/hello-algo/blob/main/LICENSE) makes it a less suitable default distribution candidate without separate permission. Keep the discovery interface ready for another sample without promising a complete Chinese book until conversion quality and redistribution details have been reviewed.
