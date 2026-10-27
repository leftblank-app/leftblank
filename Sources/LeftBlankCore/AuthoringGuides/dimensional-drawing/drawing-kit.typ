// Native Typst drawing mechanics. See license.txt for upstream method attribution.
#let ink = rgb("181818")
#let muted = rgb("606060")
#let object-stroke = (paint: ink, thickness: 1.25pt)
#let fine-stroke = (paint: ink, thickness: 0.6pt)
#let hidden-stroke = (paint: muted, thickness: 0.6pt, dash: (4pt, 3pt))
#let center-stroke = (paint: muted, thickness: 0.5pt, dash: (12pt, 3pt, 2pt, 3pt))
#let put(x, y, body) = place(top + left, dx: x * 1pt, dy: y * 1pt, body)
#let label(x, y, value, size: 9, anchor: "start", color: ink, knockout: false) = context {
  let body = box(
    inset: if knockout { (x: 2pt, y: 1pt) } else { 0pt },
    fill: if knockout { white } else { none },
    text(size: size * 1pt, fill: color, tracking: 0.2pt, value),
  )
  let measured = measure(body)
  let offset = if anchor == "middle" { measured.width / 2 } else if anchor == "end" { measured.width } else { 0pt }
  place(top + left, dx: x * 1pt - offset, dy: y * 1pt - measured.height / 2, body)
}
#let segment(x1, y1, x2, y2, stroke: fine-stroke) = {
  let x = calc.min(x1, x2)
  let y = calc.min(y1, y2)
  put(x, y, line(start: ((x1 - x) * 1pt, (y1 - y) * 1pt),
    end: ((x2 - x) * 1pt, (y2 - y) * 1pt), stroke: stroke))
}
#let frame(x, y, width, height, radius: 0, fill: none, stroke: object-stroke) = put(x, y,
  rect(width: width * 1pt, height: height * 1pt, radius: radius * 1pt, fill: fill, stroke: stroke))
#let arrowhead(x, y, angle, size: 5) = {
  let point(a, b) = ((x + a * calc.cos(angle) - b * calc.sin(angle)) * 1pt,
    (y + a * calc.sin(angle) + b * calc.cos(angle)) * 1pt)
  put(0, 0, polygon(point(0, 0), point(-size, size * 0.32), point(-size, -size * 0.32), fill: ink, stroke: none))
}
#let dimension-h(x1, x2, y, code, from: none, size: 9) = {
  if from != none {
    let direction = if y > from { 1 } else { -1 }
    for x in (x1, x2) { segment(x, from + direction * 3, x, y + direction * 5) }
  }
  segment(x1, y, x2, y)
  if x2 - x1 >= 25 {
    arrowhead(x1, y, 180deg); arrowhead(x2, y, 0deg)
  } else {
    segment(x1 - 11, y, x1, y); segment(x2, y, x2 + 11, y)
    arrowhead(x1, y, 0deg); arrowhead(x2, y, 180deg)
  }
  label((x1 + x2) / 2, y - 9, code, size: size, anchor: "middle", knockout: true)
}
#let dimension-v(y1, y2, x, code, from: none, side: "right") = {
  if from != none {
    let direction = if x > from { 1 } else { -1 }
    for y in (y1, y2) { segment(from + direction * 3, y, x + direction * 5, y) }
  }
  segment(x, y1, x, y2)
  if y2 - y1 >= 25 {
    arrowhead(x, y1, 270deg); arrowhead(x, y2, 90deg)
  } else {
    segment(x, y1 - 11, x, y1); segment(x, y2, x, y2 + 11)
    arrowhead(x, y1, 90deg); arrowhead(x, y2, 270deg)
  }
  label(x + if side == "right" { 10 } else { -10 }, (y1 + y2) / 2, code,
    anchor: if side == "right" { "start" } else { "end" }, knockout: true)
}
#let leader(x1, y1, x2, y2, code, leftward: false) = {
  let direction = if leftward { -1 } else { 1 }
  put(x1 - 1.5, y1 - 1.5, circle(radius: 1.5pt, fill: ink, stroke: none))
  segment(x1, y1, x2, y2); segment(x2, y2, x2 + direction * 12, y2)
  label(x2 + direction * 16, y2, code, anchor: if leftward { "end" } else { "start" }, knockout: true)
}
#let detail-circle(x, y, radius, code) = {
  put(x - radius, y - radius, circle(radius: radius * 1pt, stroke: hidden-stroke))
  label(x + radius + 10, y - radius - 10, code, size: 8, knockout: true)
  segment(x + radius * 0.7071, y - radius * 0.7071, x + radius + 6, y - radius - 6)
}
#let view-title(x, y, title, subtitle) = {
  label(x, y, upper(title), size: 10, anchor: "middle")
  label(x, y + 15, subtitle, size: 8, anchor: "middle", color: muted)
}
#let variable-table(x, y, rows, widths: (40, 104, 122)) = {
  let all = (("CODE", "VARIABLE", "VALUE / UNIT"),) + rows
  for (index, row) in all.enumerate() {
    let cursor = x
    for (column, value) in row.enumerate() {
      frame(cursor, y + index * 20, widths.at(column), 20,
        fill: if index == 0 { rgb("eeeeee") } else { none }, stroke: fine-stroke)
      label(cursor + 6, y + index * 20 + 10, value, size: 8)
      cursor += widths.at(column)
    }
  }
}
#let title-block(title, identifier, unit, source) = {
  frame(20, 20, 920, 83, radius: 10, stroke: fine-stroke)
  label(36, 40, "DIMENSIONAL DRAWING / CONCEPT EXAMPLE", size: 8, color: muted)
  label(36, 70, title, size: 27)
  segment(620, 20, 620, 103)
  label(638, 39, identifier + " / REV A", size: 11)
  label(638, 60, "UNITS: " + unit + " / READ DIMENSIONS", size: 9)
  label(638, 81, source, size: 8)
}
