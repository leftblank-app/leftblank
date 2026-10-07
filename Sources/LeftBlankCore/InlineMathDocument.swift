import Foundation

/// The synthetic Typst file that renders one batch: the document's rules, then each equation
/// alone on a page fitted to it, with a probe that records its size and baseline.
struct MathDocument: Equatable {
    struct Placement: Equatable {
        /// 1-based line of the equation's first character.
        let line: Int
        /// Characters before the equation on that line.
        let column: Int
    }

    static let probeLabel = "lb-math-probe"

    let source: String
    let placements: [Placement]
    /// Lines up to and including the document's rules.
    let preambleLines: Int

    init(_ equations: [String], style: MathRenderStyle, preamble: String) {
        var text = ""
        var line = 1
        func append(_ chunk: String) {
            text += chunk + "\n"
            line += Self.lineBreaks(in: chunk) + 1
        }
        if !preamble.isEmpty {
            append(preamble)
        }
        preambleLines = line - 1
        // Later rules win: no page furniture, nothing between the box and the page edge, no numbers,
        // and the editor's colour even over the document's equation colour.
        append("""
        #set page(width: auto, height: auto, margin: 0pt, fill: none, header: none, footer: none, \
        background: none, foreground: none, numbering: none, columns: 1)
        #set par(first-line-indent: 0pt, hanging-indent: 0pt)
        #set math.equation(numbering: none)
        #set text(fill: \(style.color.typst))
        #show math.equation: set text(fill: \(style.color.typst))
        """)
        // A box keeps the equation inline and gives a display equation its first line's baseline.
        // Inline equations may overhang into half the leading, which a fitted page would clip, so
        // their leading is 0; display equations keep the document's leading between their lines.
        // A strut taller than the box makes the line's height the box's descent plus the strut.
        append("""
        #let \(Self.probeLabel)(i, eq) = { let b = box(if eq.at("block", default: false) { eq } else { \
        set par(leading: 0pt); eq }); b; context { let m = measure(b); \
        let s = measure([#box(width: 0pt, height: m.height + 10pt)#b]); \
        [#metadata((i: i, w: m.width.pt(), h: m.height.pt(), d: s.height.pt() - m.height.pt() - 10, \
        size: text.size.pt(), page: here().page()))<\(Self.probeLabel)>] } }
        """)
        append("#{")
        var placements: [Placement] = []
        for (index, equation) in equations.enumerated() {
            if index > 0 {
                append("pagebreak(weak: true)")
            }
            let prefix = "\(Self.probeLabel)(\(index), "
            placements.append(Placement(line: line, column: prefix.unicodeScalars.count))
            append(prefix + equation + ")")
        }
        append("}")
        source = text
        self.placements = placements
    }

    /// Typst's line terminators; CR LF counts once.
    static func lineBreaks(in text: String) -> Int {
        var count = 0, carriageReturn = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n" where carriageReturn: break
            case "\n", "\u{0B}", "\u{0C}", "\r", "\u{85}", "\u{2028}", "\u{2029}": count += 1
            default: break
            }
            carriageReturn = scalar == "\r"
        }
        return count
    }

    struct EngineError: Equatable {
        let message: String
        let path: String?
        /// 1-based line.
        let line: Int?
        /// 0-based character column.
        let column: Int?
    }

    /// The errors in an export failure. Tinymist quotes Typst's report as a Rust string literal:
    /// `error: message\n  ┌─ path:line:column\n …\n  = hint: …`.
    static func errors(in message: String) -> [EngineError] {
        let report = unescape(message)
        var errors: [EngineError] = []
        let blocks = report.components(separatedBy: "error: ").dropFirst()
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            let hints = lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("= hint: ") ? String(trimmed.dropFirst(8)) : nil
            }
            let text = ([lines[0].trimmingCharacters(in: .whitespaces)] + hints)
                .joined(separator: "\n")
            var path: String?, line: Int?, column: Int?
            if let location = lines.dropFirst().first(where: { $0.contains("┌─ ") }) {
                let parts = location.components(separatedBy: "┌─ ")[1].split(
                    separator: ":",
                    omittingEmptySubsequences: false,
                )
                if parts.count >= 3, let parsedLine = Int(parts[parts.count - 2]),
                   let parsedColumn = Int(parts[parts.count - 1])
                {
                    path = parts.dropLast(2).joined(separator: ":")
                    line = parsedLine
                    column = parsedColumn
                }
            }
            errors.append(EngineError(message: text, path: path, line: line, column: column))
        }
        return errors
    }

    /// Undoes Rust's `{:?}` escapes for the characters Typst reports contain.
    static func unescape(_ text: String) -> String {
        var result = "", escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// The equation an error points into, with its UTF-16 location in that equation's source.
    func locate(_ error: EngineError, file: String, equations: [String]) -> (index: Int, offset: Int)? {
        guard let path = error.path, path == file || path.hasSuffix("/" + file), let line = error.line,
              let column = error.column, line > preambleLines
        else {
            return nil
        }
        guard let index = placements.lastIndex(where: { $0.line <= line }) else {
            return nil
        }
        let equation = equations[index], placement = placements[index]
        var scalars = Array(equation.unicodeScalars)
        // Characters from the start of the equation to the error.
        var characters = line == placement.line ? column - placement.column : column
        var skippedLines = line - placement.line, position = 0
        while skippedLines > 0, position < scalars.count {
            let scalar = scalars[position]
            position += 1
            if Self.lineBreaks(in: String(scalar)) > 0 {
                if scalar == "\r", position < scalars.count, scalars[position] == "\n" {
                    position += 1
                }
                skippedLines -= 1
            }
        }
        guard skippedLines == 0, characters >= 0 else {
            return nil
        }
        characters = min(position + characters, scalars.count)
        // A location after the equation (its closing parenthesis) still belongs to it.
        scalars = Array(scalars[..<characters])
        return (index, String(String.UnicodeScalarView(scalars)).utf16.count)
    }
}
