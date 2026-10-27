// Concept: finite attention leaks through many small interruptions.
// This is an editable scene scaffold, not a composition to reuse for every topic.
#import "illustration-kit.typ": *
#set page(width: 960pt, height: 540pt, margin: 0pt, fill: white)
#set text(font: ("PingFang SC", "Arial"), size: 18pt)

// The quiet upper third can accompany an external slide title.
// Uneven bucket sides and a slightly tilted water line keep the scene sketch-like.
#sketch(((443, 208), (643, 211), (623, 378), (468, 375), (443, 208)), closed: true, fill: white)
#sketch(((450, 234), (498, 232), (554, 235), (598, 233), (639, 235)), color: orange, weight: 1.3)
#sketch(((469, 208), (477, 183), (603, 184), (615, 210)), weight: 1.2)
#note(543, 278, "注意力", size: 20, anchor: "middle")

// Two remaining leaks; the left leak is actively blocked by the character's hand.
#dot(463, 344, 3.4)
#dot(628, 330, 2.9)
#dot(626, 353, 2.9)
#sketch(((632, 332), (654, 341), (666, 354)), color: orange, weight: 1.2)
#sketch(((630, 356), (646, 366), (655, 381)), color: orange, weight: 1.2)
#for (x, y) in ((669, 363), (658, 393), (672, 403)) { dot(x, y, 2.5, color: orange) }

// One hand braces the body; the other presses a patch against the hole.
#character(390, 304,
  arms: (((34, 28), (52, 34), (73, 40)), ((5, 31), (-8, 45), (-9, 62))),
  legs: (((13, 48), (4, 76), (-7, 76)), ((29, 49), (45, 70), (58, 72))),
  scale: 1.05)
#paper(456, 336, 16, 20, tilt: -1)
#dot(465, 345, 3.2)
#sketch(((368, 389), (441, 388)), weight: 0.8)

// Few short annotations; no generic decorative scene heading.
#note(222, 257, "小事不断", color: blue, size: 18)
#sketch(((306, 269), (333, 283), (354, 300)), color: blue, weight: 1)
#note(709, 316, "先堵漏洞", color: red, size: 20)
#sketch(((702, 329), (681, 338), (663, 343)), color: red, weight: 1)
#note(471, 430, "留给关键一步", color: blue, size: 17, anchor: "middle")
#sketch(((470, 410), (484, 388)), color: blue, weight: 1)
