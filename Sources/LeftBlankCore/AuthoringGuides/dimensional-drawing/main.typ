// Illustrative design assumptions, not measurements of an existing component.
#import "drawing-kit.typ": *
#set page(width: 960pt, height: 680pt, margin: 0pt, fill: white)
#set text(font: "Arial", size: 9pt)
#let spec = (width: 360, height: 200, header: 60, footer: 52, inset: 5,
  border: 1, radius: 18, pad: 16, action: 32)
#let inner-radius = spec.radius - spec.border - spec.inset
#let body-height = spec.height - spec.header - spec.footer
#title-block("CARD", "UI-CARD-001", "CSS PX", "SOURCE: EXAMPLE DESIGN ASSUMPTIONS")
#label(34, 135, "DESIGN NOTES", size: 11)
#for (i, note) in (
  "1  Header and footer hug their content.",
  "2  Dashed areas are layout slots.",
  "3  The well uses a shared corner center.",
  "4  All shown values are concept assumptions.",
  "5  Viewport and overflow policy: [TBD].",
).enumerate() { label(34, 160 + i * 22, note, size: 8.5) }
#let x = 350
#let y = 210
#frame(x, y, spec.width, spec.height, radius: spec.radius, fill: white)
#frame(x + spec.border + spec.inset, y + spec.border + spec.inset,
  spec.width - 2 * (spec.border + spec.inset), spec.height - 2 * (spec.border + spec.inset),
  radius: inner-radius, fill: rgb("f3f3f3"), stroke: fine-stroke)
#for offset in (spec.header, spec.height - spec.footer) {
  segment(x + spec.border + spec.inset, y + offset,
    x + spec.width - spec.border - spec.inset, y + offset, stroke: hidden-stroke)
}
#frame(x + spec.pad, y + 22, 230, 18, stroke: hidden-stroke)
#label(x + spec.pad + 8, y + 31, "TITLE SLOT / FLEX", size: 8, color: muted)
#frame(x + spec.width - 92, y + 19, 76, 24, radius: 12, fill: rgb("e6e6e6"), stroke: fine-stroke)
#label(x + spec.width - 54, y + 31, "TRAIL / HUG", size: 7, anchor: "middle")
#for (offset, height) in ((74, 30), (116, 18)) {
  frame(x + 18, y + offset, spec.width - 36, height, stroke: hidden-stroke)
  label(x + spec.width / 2, y + offset + height / 2, "CONTENT SLOT / FILL", size: 8, anchor: "middle", color: muted)
}
#frame(x + spec.pad, y + spec.height - 37, 202, 20, stroke: hidden-stroke)
#label(x + spec.pad + 8, y + spec.height - 27, "META / FLEX / WRAPS", size: 8, color: muted)
#frame(x + spec.width - 116, y + spec.height - 42, 100, spec.action, radius: spec.action / 2,
  fill: rgb("e6e6e6"), stroke: fine-stroke)
#label(x + spec.width - 66, y + spec.height - 26, "ACTION / HUG", size: 8, anchor: "middle")
#segment(x - 15, y + 31, x + spec.width + 15, y + 31, stroke: center-stroke)
#segment(x - 15, y + spec.height - 26, x + spec.width + 15, y + spec.height - 26, stroke: center-stroke)
#dimension-h(x, x + spec.width, y - 42, "W", from: y)
#dimension-v(y, y + spec.height, x - 70, "H", from: x, side: "left")
#dimension-v(y, y + spec.header, x - 20, "H1", from: x, side: "left")
#dimension-v(y + spec.header, y + spec.height - spec.footer, x - 20, "H-body", side: "left")
#dimension-v(y + spec.height - spec.footer, y + spec.height, x - 20, "H2", from: x, side: "left")
#dimension-h(x, x + spec.pad, y + spec.height + 32, "S1", from: y + spec.height)
#dimension-v(y + spec.height - 42, y + spec.height - 10, x + spec.width + 25, "H3", from: x + spec.width)
#leader(x + 5, y + 5, x - 2, y - 10, "R1", leftward: true)
#detail-circle(x + 8, y + 8, 15, "DETAIL A")
#view-title(x + spec.width / 2, y + spec.height + 68, "Plan view", "REFERENCE GEOMETRY / DISPLAY SCALE MAY VARY")
#label(760, 135, "VARIABLES", size: 11)
#variable-table(760, 155, (
  ("W", "width", str(spec.width) + " px"),
  ("H", "height", str(spec.height) + " px"),
  ("H1", "header", str(spec.header) + " px"),
  ("H2", "footer", str(spec.footer) + " px"),
  ("H-body", "body", str(body-height) + " px"),
  ("H3", "action-h", str(spec.action) + " px"),
  ("S1", "pad", str(spec.pad) + " px"),
  ("S2", "well-inset", str(spec.inset) + " px"),
  ("B", "border", str(spec.border) + " px"),
  ("R1", "outer-radius", str(spec.radius) + " px"),
  ("R2", "well-radius", "R1 - B - S2 = " + str(inner-radius)),
), widths: (32, 70, 78))

// Enlarged bottom-left corner: outer, border-inner and inset share one center.
#let corner-x = 100
#let corner-y = 590
#let scale = 4
#let corner(offset, radius) = {
  let p(a, b) = ((corner-x + a * scale) * 1pt, (corner-y - b * scale) * 1pt)
  let c = 0.55228475
  put(0, 0, curve(stroke: fine-stroke,
    curve.move(p(offset, 32)), curve.line(p(offset, spec.radius)),
    curve.cubic(p(offset, spec.radius - c * radius), p(spec.radius - c * radius, offset), p(spec.radius, offset)),
    curve.line(p(42, offset))))
}
#corner(0, spec.radius)
#corner(spec.border, spec.radius - spec.border)
#corner(spec.border + spec.inset, inner-radius)
#let center = (corner-x + spec.radius * scale, corner-y - spec.radius * scale)
#segment(center.at(0) - 6, center.at(1), center.at(0) + 6, center.at(1))
#segment(center.at(0), center.at(1) - 6, center.at(0), center.at(1) + 6)
#leader(center.at(0), center.at(1), center.at(0) + 48, center.at(1) - 24, "SHARED CENTER")
#dimension-h(corner-x + spec.border * scale, corner-x + (spec.border + spec.inset) * scale,
  corner-y - 144, "S2", from: corner-y - 128)
#label(295, 560, "R2 = R1 - B - S2 = " + str(inner-radius), size: 11)
#label(295, 582, "H = " + str(spec.header) + " + " + str(body-height) + " + " + str(spec.footer) + " = " + str(spec.height), size: 9)
#view-title(185, 625, "Detail A / nested corner", "ENLARGED 4X / ALL THREE ARCS ARE CONCENTRIC")
#label(34, 657, "CONCEPT EXAMPLE / CHANGE THE SPEC AND REDRAW ALL RELATED GEOMETRY", size: 8, color: muted)
