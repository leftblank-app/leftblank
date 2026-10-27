# Xiaohei explanatory illustrations

Use this guide when a user wants a white-background sketch illustration, a visual metaphor for a paragraph, or a memorable 16:9 image to include in a presentation. This adapts Ian's Xiaohei illustration method to editable Typst assets. It creates a slide-sized illustration, not an editable PowerPoint deck or an entire presentation by itself. Follow the user's stated format, style, and language.

## From a vague request to a visual idea

Start with the reader's intended takeaway. If the user supplies a whole article or talk, identify its turning points rather than illustrating every paragraph. If the user only asks for suggestions, return a short shot list. If they ask for the actual image and the meaning is clear, form the brief internally and continue without an extra approval round.

For each proposed image, determine:

```text
Reader / placement: a product talk, beside a specific paragraph, or standalone
Single takeaway: the sentence a viewer should remember
Mode: concept metaphor or factual relationship diagram
Visual action: a physical verb that embodies the takeaway
Object: one or two ordinary objects transformed by that action
Character role: what Xiaohei must do for the scene to make sense
Composition: one scene, comparison, states, or a short sequence
Labels: a few short phrases, in the user's language
Facts / assumptions: which details come from the material, which are invented metaphors
Output: editable Typst illustration, requested frame size, preview
```

For example, "there is too much to do" is broad. A usable brief is "show that many small interruptions drain a finite attention budget; Xiaohei physically plugs one leak; one bucket, a few leaks, three short annotations." The example is a planning demonstration, not a mandatory composition for every productivity topic.

Ask a focused question only when the central takeaway or audience cannot be inferred and competing interpretations would produce different images. Do not ask the user to choose technical drawing coordinates or enumerate all decorative details.

## Choose the right semantic mode

- **Concept metaphor:** turn an abstract verb into a physical action, choose an ordinary low-tech object, and make the character perform the action. Invent a fresh combination from the current material. Do not relabel an old scene and call it a new idea.
- **Factual relationship diagram:** when the question is who calls whom, how data moves, what a boundary contains, or how a state changes, extract the actual elements and directed relationships first. Preserve a source for each relationship; mark assumptions. The character may illustrate an actor's burden or a real constraint but must not become an invented service, database, or protocol. Split a complicated system into overview and detail views.

Keep metaphor and fact distinguishable. A fanciful prop can explain an idea; it is not evidence of a physical mechanism or a real software dependency.

## Visual defaults

- Default to a 16:9 white frame with a generous quiet region that can sit beside or below slide text. User-provided aspect ratios override the default.
- Thin, slightly irregular black strokes, restrained geometry, and substantial whitespace. Keep the main scene around 40-60% of the frame. Avoid gradients, paper texture, drop shadows, busy backgrounds, and dashboard-style card grids.
- Xiaohei has a dark solid body, small white eyes, thin limbs, and a calm expression. The character participates in the key action. It is not a decorative mascot in the corner.
- Use a few short annotations, usually 2-8 Chinese characters or comparably short labels. Keep labels as editable Typst text; avoid long prose inside the scene.
- Use color sparingly: red for a problem or emphasis, orange for a primary movement, blue for a supplementary state or explanation. There is no requirement to use all three.
- For a standalone factual diagram, use an informative scope caption and a small legend. For an illustration next to a slide title, let the slide carry the title; do not add a generic "workflow" or "system diagram" heading inside the picture.

The native kit supplies useful drawing mechanics, not an automatic aesthetic guarantee. Design the action, silhouette, and whitespace for each subject. Preserve the user's intended visual tone when it differs from these defaults.

## Read and use the starter files

Read `illustration-kit.typ`, a relevant entry example, and `license.txt` with `resources/read` at the exact URIs from `resources/list`: `leftblank://guides/xiaohei-illustrations/<filename>`. `main.typ` shows an attention leak; `feedback.typ` shows a character reshaping an aircraft in response to its flight. They are different composition demonstrations, not a fixed scene library.

Create a document using the selected entry as `main.typ` and add `illustration-kit.typ` and the attribution text with the normal versioned editing tools. Both examples import `illustration-kit.typ` as a sibling. Preserve separate entry files if keeping both in one project. For an existing project, read current files and revisions before changing them.

The kit provides sketch strokes, arrowheads, labels, and a body silhouette. The caller supplies arm and leg paths so the pose can fit the new scene; do not reuse a generic pose when the topic calls for another action. Keep labels, character, props, and relationships editable. The native route uses no external package, raster image, or image-generation service.

If the agent separately has an image-generation capability and the user wants a richer bitmap illustration, it may use that capability for the visual pass. LeftBlank MCP does not itself provide image generation or arbitrary binary upload. Do not promise those tools, silently replace technical structure with a generated image, or claim a raster image is editable vector content. Keep technical labels and factual relationships under deterministic control when their accuracy matters.

## Visual QA and delivery

1. Compile the captured current project using `compile_document`; resolve source errors.
2. Use `render_page` and inspect the returned page at both full-frame and reading size. If image rendering fails, disclose that visual inspection could not be completed.
3. Check that the scene conveys its single takeaway quickly, the character is visibly performing the intended action, and removing it would weaken the metaphor.
4. Check frame size, white background, quiet space, label spelling/readability, restrained colors, and object/limb overlaps. Avoid accidental smiles, decorative character placement, and unreadably small labels.
5. For factual diagrams, compare every node, boundary, label, and arrow direction against the brief. Do not invent missing relationships to make a balanced composition.
6. Revise the source and render again. If the scene is ordinary, change the object/action pair rather than adding decoration. If it is crowded, remove elements or split the image.
7. Deliver the image's intended use, its editable Typst document, and any material assumptions or limits. Report the actual supported export; do not label a PDF page as a PPTX.

See `license.txt` for upstream attribution and adaptation notes.
