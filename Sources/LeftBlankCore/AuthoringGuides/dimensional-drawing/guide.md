# Dimensional drawings

Use this guide for an industrial-looking drawing sheet, UI anatomy, redline, or product dimensional reference. User instructions about style, language, format, and scope take precedence. The sheet is a communication artifact; its precision comes from the input evidence, not its visual appearance.

## Start with the purpose

Read the available source: a component file, screenshot, product specification, sketch, or the user's description. Choose one mode:

- **Reference drawing:** document an existing object. Record each dimension's source. Use `[TBD]` for unavailable measurements, tolerances, materials, or behavior. A screenshot permits proportional estimates only when clearly marked as estimates.
- **Concept design:** propose a new object. Explicitly label chosen dimensions as design assumptions. Keep those assumptions together so the user can change them.

Ask only about missing information that changes the subject, required accuracy, or major views. A request for a rough concept can proceed with stated assumptions. Do not repeatedly ask about line weights, fonts, or annotation positions; use this guide's defaults. Do not silently convert a rough concept into a supposedly measured or manufacturing-ready drawing.

Write a short brief before drawing, internally when the user asked for direct generation:

```text
Subject: reusable settings card
Reader question: how do its regions, insets, and corners fit together?
Mode: reference / concept (choose one)
Input evidence: component source, published values, screenshot, or user brief
Known dimensions: name, value, unit, source
Derived values: formula and result
Assumptions / TBD: list explicitly
Views: plan + corner detail + parameter table
Output: one editable Typst sheet and a rendered preview
```

For a physical product, replace the views with aligned front/top/right views and only the sections needed to explain its shape. Add an exploded view when assembly or layers are the question. For a dialog, include viewport placement and scrim behavior only if known. Avoid filling the sheet with irrelevant views.

## Drawing language

- White page, black outlines, grayscale fills. Distinguish object, dimension, hidden, and center lines by weight and dash pattern.
- Keep the title block compact: subject, drawing identifier, revision, units, source, and stated scale. All raster/display previews can be resized; dimensions are authoritative.
- Use dimension codes on the views and put names, values, units, and formulas in a nearby table. Useful prefixes: `S` spacing, `H` heights, `W` width, `D` depth, `R` radii, `B` border, and `E` shadow/clearance envelope. Do not label dimensions with unrelated content widths.
- For UI, describe layout slots such as TITLE / FLEX, CONTENT / FILL, and ACTION / HUG. Distinguish drawn control height from any specified touch target.
- Use short leaders and circular detail references. Enlargement should show something the plan cannot explain clearly.
- Derived dimensions must agree with the view and the table. A nested UI corner uses `R-inner = R-outer - B - inset`; retain a common center when that is the intended geometry.
- Give annotations room. Short spans need external arrowheads or an offset label. Reduce detail count or split a sheet rather than shrinking everything until unreadable.
- Keep names neutral unless the user requests branding. Preserve user-provided terminology and language.

## Read and use the starter files

`resources/read` returns one bundled file at a time. Discover exact URIs with `resources/list`; all files in this guide use `leftblank://guides/dimensional-drawing/<filename>`. Read `drawing-kit.typ`, one relevant example, and `license.txt` through those URIs. `main.typ` is a component card; `product.typ` is a physical enclosure. Their numbers define illustrative example designs and are not measurements of a user's product.

Create a new document with the selected example as `main.typ`, then add `drawing-kit.typ` and the attribution text using the normal versioned editing tools. Both entry examples import `drawing-kit.typ` as a sibling. If preserving both examples in one project, keep `main.typ` and `product.typ` as separate compilation entries; do not concatenate their page setup. For an existing document, inspect its files and revisions first and avoid overwriting user work.

The kit contains native Typst functions for frames, dimensions, leaders, detail circles, and tables. Modify a small `spec` dictionary and redraw the geometry from it; do not update only the table while leaving old geometry. The examples intentionally demonstrate two different subjects. Select views for the new subject rather than copying every example panel.

No external package, browser, image generator, or binary import is required. Font availability can still vary. `create_document` and `apply_patch` accept Typst text; they do not generate a PPTX file. Use the formats actually available in the application and report any unsupported requested export.

## Compile, inspect, revise

1. Read the current project revision and call `compile_document`. Fix actual source errors before continuing.
2. Call `render_page` for the drawing page and inspect the returned image. Check the complete page, not only the central object.
3. Check that every visible dimension code has a table entry, formulas close, units agree, and assumed/TBD values remain identifiable.
4. Check arrowheads, extension lines, corner centers, aligned views, text legibility, collisions, and page boundaries. Inspect derived geometry after parameter changes.
5. Fix the Typst source and render again. A successful compile does not prove the drawing is readable. If rendering fails, report that visual QA is incomplete; never claim to have inspected an unavailable preview.
6. Deliver a brief description of what was drawn, the source assumptions/TBD items, and the editable document. Describe actual verification status without upgrading `unverified` to strict reproducibility.

This workflow adapts the dimensional-drawing skill by Enes Ozturk to native Typst. See `license.txt` for source revision and license.
