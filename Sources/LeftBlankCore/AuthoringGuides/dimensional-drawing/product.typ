// Illustrative enclosure dimensions chosen for this concept, not published product facts.
#import "drawing-kit.typ": *
#set page(width: 960pt, height: 680pt, margin: 0pt, fill: white)
#set text(font: "Arial", size: 9pt)
#let spec = (width: 120, height: 72, depth: 48, radius: 8)
#let k = 2.1
#let front-x = 150
#let front-y = 380
#let top-y = 205
#let side-x = 480
#title-block("SENSOR ENCLOSURE", "PRODUCT-001", "MM", "SOURCE: EXAMPLE CONCEPT / NOT MEASURED")
#label(34, 131, "ALIGNED ORTHOGRAPHIC VIEWS", size: 11)
#label(34, 150, "Top above front; right-side view to the right. Only exterior concept geometry is defined.", size: 8.5)

// All views derive from one spec. Dashed projection lines connect aligned edges.
#segment(front-x, top-y - 15, front-x, front-y + spec.height * k + 15, stroke: center-stroke)
#segment(front-x + spec.width * k, top-y - 15, front-x + spec.width * k,
  front-y + spec.height * k + 15, stroke: center-stroke)
#segment(front-x - 15, front-y, side-x + spec.depth * k + 15, front-y, stroke: center-stroke)
#segment(front-x - 15, front-y + spec.height * k, side-x + spec.depth * k + 15,
  front-y + spec.height * k, stroke: center-stroke)
#frame(front-x, top-y, spec.width * k, spec.depth * k, radius: spec.radius * k, fill: white)
#frame(front-x, front-y, spec.width * k, spec.height * k, radius: spec.radius * k, fill: white)
#frame(side-x, front-y, spec.depth * k, spec.height * k, radius: spec.radius * k, fill: white)
#dimension-h(front-x, front-x + spec.width * k, top-y - 26, "W", from: top-y)
#dimension-v(top-y, top-y + spec.depth * k, front-x - 29, "D", from: front-x, side: "left")
#dimension-v(front-y, front-y + spec.height * k, front-x - 29, "H", from: front-x, side: "left")
#dimension-h(side-x, side-x + spec.depth * k, front-y + spec.height * k + 30, "D", from: front-y + spec.height * k)
#leader(front-x + 5, front-y + 5, front-x + 26, front-y - 20, "R1")
#view-title(front-x + spec.width * k / 2, top-y + spec.depth * k + 27, "Top", "W X D / CONCEPT EXTERIOR")
#view-title(front-x + spec.width * k / 2, front-y + spec.height * k + 57, "Front", "W X H / CONCEPT EXTERIOR")
#view-title(side-x + spec.depth * k / 2, front-y + spec.height * k + 57, "Right side", "D X H / CONCEPT EXTERIOR")
#label(650, 180, "DIMENSIONS", size: 11)
#variable-table(650, 201, (
  ("W", "width", str(spec.width) + " mm"),
  ("H", "height", str(spec.height) + " mm"),
  ("D", "depth", str(spec.depth) + " mm"),
  ("R1", "edge radius", str(spec.radius) + " mm"),
), widths: (40, 95, 120))
#label(650, 325, "DESIGN ASSUMPTIONS", size: 11)
#for (i, note) in (
  "Exterior overall dimensions and edge radii",
  "are proposed for this illustration only.",
  "No screw boss, port, seam, or cavity is",
  "drawn without a corresponding design brief.",
).enumerate() { label(650, 348 + i * 19, note, size: 8.5) }
#label(650, 450, "UNRESOLVED / [TBD]", size: 11)
#for (i, note) in (
  "Material, process, wall thickness",
  "Tolerances, clearances, mounting details",
  "Connector locations, ingress rating",
).enumerate() { label(650, 473 + i * 21, note, size: 8.5) }
#label(34, 626, "REFERENCE SIZE: " + str(spec.width) + " X " + str(spec.height) + " X " + str(spec.depth) + " MM", size: 10)
#label(34, 652, "CONCEPT EXAMPLE / READ THE DIMENSIONS / DISPLAY SCALE IS NOT A MEASUREMENT", size: 8, color: muted)
