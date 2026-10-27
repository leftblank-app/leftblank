// Editable native-Typst sketch mechanics. Each scene supplies its own action and pose.
// Method and character concept adapted from Ian; see license.txt.
#let ink = rgb("181818")
#let red = rgb("bf423b")
#let orange = rgb("d17a35")
#let blue = rgb("527d9d")
#let put(x, y, body) = place(top + left, dx: x * 1pt, dy: y * 1pt, body)
#let sketch(points, color: ink, weight: 1.6, closed: false, fill: none) = {
  assert(points.len() >= 2, message: "A sketch needs at least two points.")
  let x = calc.min(..points.map(p => p.at(0)))
  let y = calc.min(..points.map(p => p.at(1)))
  let point(p) = ((p.at(0) - x) * 1pt, (p.at(1) - y) * 1pt)
  let parts = points.slice(1).map(p => curve.line(point(p)))
  if closed { parts.push(curve.close()) }
  put(x, y, curve(curve.move(point(points.first())), ..parts,
    fill: fill, stroke: (paint: color, thickness: weight * 1pt, cap: "round", join: "round")))
}
#let note(x, y, value, color: ink, size: 18, anchor: "start") = context {
  let body = text(size: size * 1pt, fill: color, tracking: 0.4pt, value)
  let measured = measure(body)
  let shift = if anchor == "middle" { measured.width / 2 } else if anchor == "end" { measured.width } else { 0pt }
  place(top + left, dx: x * 1pt - shift, dy: y * 1pt - measured.height / 2, body)
}
#let dot(x, y, radius, color: ink) = put(x - radius, y - radius,
  circle(radius: radius * 1pt, fill: color, stroke: none))
#let sketch-arrow(points, color: orange, weight: 1.6) = {
  sketch(points, color: color, weight: weight)
  let tip = points.last()
  let previous = points.at(points.len() - 2)
  let angle = calc.atan2(tip.at(1) - previous.at(1), tip.at(0) - previous.at(0))
  let wing(offset) = (tip.at(0) - 9 * calc.cos(angle + offset), tip.at(1) - 9 * calc.sin(angle + offset))
  sketch((wing(24deg), tip, wing(-24deg)), color: color, weight: weight)
}
#let character(x, y, arms: (), legs: (), scale: 1) = {
  let p(a, b) = (a * scale * 1pt, b * scale * 1pt)
  let local(points) = points.map(v => (x + v.at(0) * scale, y + v.at(1) * scale))
  // An intentionally uneven bean silhouette, quiet eyes, no decorative costume.
  put(x, y, curve(fill: ink, stroke: none,
    curve.move(p(9, 1)),
    curve.cubic(p(31, -3), p(40, 10), p(37, 30)),
    curve.cubic(p(40, 48), p(27, 53), p(11, 48)),
    curve.cubic(p(-4, 46), p(-3, 11), p(9, 1)), curve.close()))
  for eye in ((15, 17), (25, 17)) {
    dot(x + eye.at(0) * scale, y + eye.at(1) * scale, 1.8 * scale, color: white)
  }
  for arm in arms { sketch(local(arm), weight: 1.7 * scale) }
  for leg in legs { sketch(local(leg), weight: 1.6 * scale) }
}
#let paper(x, y, width, height, tilt: 3, color: ink) = {
  sketch(((x, y), (x + width, y + tilt), (x + width - 2, y + height),
    (x + 1, y + height - tilt)), color: color, closed: true, fill: white)
  sketch(((x + width * 0.2, y + height * 0.4), (x + width * 0.7, y + height * 0.4 + 1)),
    color: color, weight: 0.9)
}
