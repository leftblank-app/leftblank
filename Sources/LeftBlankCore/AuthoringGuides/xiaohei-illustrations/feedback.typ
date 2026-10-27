// Concept: feedback changes the next attempt instead of being filed away.
// A different physical action and composition from the attention-leak example.
#import "illustration-kit.typ": *
#set page(width: 960pt, height: 540pt, margin: 0pt, fill: white)
#set text(font: ("PingFang SC", "Arial"), size: 18pt)

// A paper aircraft rests on a narrow stand while one wing is being reshaped.
#sketch(((384, 292), (617, 206), (546, 322), (483, 285), (384, 292)), closed: true, fill: white)
#sketch(((384, 292), (534, 264), (617, 206)), weight: 1.2)
#sketch(((483, 285), (534, 264), (546, 322)), weight: 1.1)
#sketch(((500, 325), (500, 364), (454, 366)), weight: 1.2)
#sketch(((500, 364), (549, 367)), weight: 1.2)

// The small character bends a wing upward; hands touch the altered fold.
#character(346, 308,
  arms: (((31, 25), (48, 13), (58, -13)), ((8, 31), (29, 19), (42, -4))),
  legs: (((13, 48), (8, 73), (-3, 74)), ((29, 49), (42, 71), (54, 72))),
  scale: 1.05)
#sketch(((391, 291), (408, 279), (422, 281)), color: orange, weight: 2)

// A light observation arc links a previous flight trace to this local correction.
#sketch(((626, 224), (657, 210), (691, 211), (716, 225)), color: blue, weight: 1)
#sketch(((723, 235), (732, 256), (729, 276)), color: blue, weight: 1)
#sketch-arrow(((727, 290), (704, 322), (658, 342), (605, 345)), color: blue, weight: 1.2)
#note(695, 173, "看见偏差", color: blue, size: 18, anchor: "middle")
#note(249, 247, "改这一折", color: red, size: 20, anchor: "middle")
#sketch(((298, 259), (328, 273), (357, 286)), color: red, weight: 1)
#note(484, 425, "再试一次", color: orange, size: 18, anchor: "middle")
#sketch-arrow(((564, 416), (597, 403), (613, 380)), color: orange, weight: 1.2)
