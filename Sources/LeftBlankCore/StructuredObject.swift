import Foundation

/// A deliberately small editor for literal objects. Generated cells, spans, comments,
/// and expressions remain in the source editor. Ranges use UTF-16 like both native editors.
public struct StructuredObject: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case table, image }
    public let kind: Kind
    public let range: NSRange
    public let original: String
    public var rows: [[String]] = []
    public var hasHeader = false
    public var alignment = ""
    public var path = ""
    public var width = ""
    public var caption: String?
    private var options: [String] = []

    public static func at(_ selection: NSRange, in source: String) -> Self? {
        let scanner = ObjectScanner(source)
        guard selection.location >= 0, selection.length >= 0, selection.location <= scanner.units.count,
              selection.length <= scanner.units.count - selection.location
        else {
            return nil
        }
        var found: Self?
        _ = scanner.scan(from: 0, frames: []) { index in
            guard let call = scanner.call(at: index + 1), ["table", "image", "figure", "align"].contains(call.name)
            else {
                return nil
            }
            let range = NSRange(location: index, length: call.end - index)
            // An attached content block is one more argument. Keep such calls in source mode.
            if call.end == scanner.units.count || scanner.units[call.end] != 91,
               selection.location >= index, NSMaxRange(selection) <= call.end,
               let object = parse(scanner.text(range), range: range)
            {
                found = object
                return scanner.units.count
            }
            return call.end
        }
        return found
    }

    private static func parse(_ original: String, range: NSRange) -> Self? {
        // Comments/raw blocks have distinct lexical rules. Keep them entirely in source mode.
        guard !original.contains("//"), !original.contains("/*"), !original.contains("`") else {
            return nil
        }
        let scanner = ObjectScanner(String(original.dropFirst()))
        guard let call = scanner.call(at: 0), call.end == scanner.units.count else {
            return nil
        }
        if call.name == "table" {
            var result = Self(kind: .table, range: range, original: original)
            var columns: Int?, cells: [String] = [], names = Set<String>()
            for arg in call.args {
                if let content = ObjectScanner.content(arg) {
                    cells.append(content)
                    continue
                }
                let nested = ObjectScanner(arg)
                if let header = nested.call(at: 0), header.name == "table.header", header.end == nested.units.count {
                    guard !result.hasHeader, cells.isEmpty else {
                        return nil
                    }
                    let contents = header.args.compactMap(ObjectScanner.content)
                    guard contents.count == header.args.count else {
                        return nil
                    }
                    result.hasHeader = true
                    cells += contents
                    // Header width must match the explicit column count.
                    guard let columns, contents.count == columns else {
                        return nil
                    }
                    continue
                }
                guard let (key, value) = ObjectScanner.named(arg), names.insert(key).inserted else {
                    return nil
                }
                switch key {
                case "columns":
                    guard let count = Int(value), (1 ... 20).contains(count) else {
                        return nil
                    }
                    columns = count
                case "align":
                    guard ["left", "center", "right"].contains(value) else {
                        return nil
                    }
                    result.alignment = value
                case "inset", "gutter", "row-gutter", "column-gutter", "stroke", "fill":
                    // These options stay byte-for-byte intact; they never depend on row/column indices.
                    guard ObjectScanner.scalar(value) || ["none", "auto"].contains(value) else {
                        return nil
                    }
                    result.options.append(arg)
                default: return nil
                }
            }
            guard let columns, !cells.isEmpty, cells.count.isMultiple(of: columns),
                  cells.count / columns <= 100
            else {
                return nil
            }
            result.rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0 ..< $0 + columns]) }
            return result
        }
        var result = Self(kind: .image, range: range, original: original)
        var imageCall = call
        if imageCall.name == "align" {
            guard imageCall.args.count == 2, ["left", "center", "right"].contains(imageCall.args[0]),
                  let nested = ObjectScanner.exactCall(imageCall.args[1])
            else {
                return nil
            }
            result.alignment = imageCall.args[0]
            imageCall = nested
        }
        if imageCall.name == "figure" {
            guard imageCall.args.count == 2, let nested = ObjectScanner.exactCall(imageCall.args[0]),
                  let (key, value) = ObjectScanner.named(imageCall.args[1]), key == "caption",
                  let caption = ObjectScanner.string(value)
            else {
                return nil
            }
            result.caption = caption
            imageCall = nested
        }
        guard imageCall.name == "image", (1 ... 2).contains(imageCall.args.count),
              let path = imageCall.args.first.flatMap(ObjectScanner.string)
        else {
            return nil
        }
        result.path = path
        if imageCall.args.count == 2 {
            guard let (key, value) = ObjectScanner.named(imageCall.args[1]), key == "width",
                  ObjectScanner.scalar(value)
            else {
                return nil
            }
            result.width = value
        }
        return result
    }

    public func replacement(in source: String) throws -> TextReplacement {
        guard range.location >= 0, NSMaxRange(range) <= source.utf16.count,
              (source as NSString).substring(with: range) == original
        else {
            throw ObjectEditError.changed
        }
        if let initial = Self.parse(original, range: range), self == initial {
            return TextReplacement(range: range, text: original)
        }
        let replacement: String
        switch kind {
        case .table:
            guard let columns = rows.first?.count, (1 ... 20).contains(columns), (1 ... 100).contains(rows.count),
                  rows.allSatisfy({ $0.count == columns }), !hasHeader || rows.count >= 1,
                  alignment.isEmpty || ["left", "center", "right"].contains(alignment),
                  rows.joined().allSatisfy({ ObjectScanner.content("[" + $0 + "]") == $0 })
            else {
                throw ObjectEditError.invalid
            }
            var args = ["columns: \(columns)"] + options
            if !alignment.isEmpty {
                args.append("align: " + alignment)
            }
            for (index, row) in rows.enumerated() {
                let cells = row.map { "[" + $0 + "]" }.joined(separator: ", ")
                args.append(index == 0 && hasHeader ? "table.header(\(cells))" : cells)
            }
            replacement = "#table(\n  " + args.joined(separator: ",\n  ") + ",\n)"
        case .image:
            guard !path.isEmpty, width.isEmpty || ObjectScanner.scalar(width),
                  alignment.isEmpty || ["left", "center", "right"].contains(alignment)
            else {
                throw ObjectEditError.invalid
            }
            var call = "image(" + ObjectScanner.quote(path) + (width.isEmpty ? "" : ", width: " + width) + ")"
            if let caption {
                call = "figure(\n  \(call),\n  caption: \(ObjectScanner.quote(caption)),\n)"
            }
            if !alignment.isEmpty {
                call = "align(\(alignment), \(call))"
            }
            replacement = "#" + call
        }
        return TextReplacement(range: range, text: replacement)
    }

    /// Paste TSV as literal content, never as executable Typst. The first pasted row is
    /// the header when the existing table has one. Reject ragged or excessive input.
    public mutating func pasteTable(_ text: String) throws {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let cells = lines.map { $0.components(separatedBy: "\t") }
        guard let count = cells.first?.count, (1 ... 20).contains(count), (1 ... 100).contains(cells.count),
              cells.allSatisfy({ $0.count == count })
        else {
            throw ObjectEditError.invalid
        }
        rows = cells.map { $0.map { value in
            value.reduce(into: "") { output, character in
                if "\\[]#*$@<>_`=+-/~.\"".contains(character) {
                    output.append("\\")
                }
                output.append(character)
            }
        } }
    }
}

public enum ObjectEditError: LocalizedError {
    case changed
    case invalid
    public var errorDescription: String? {
        switch self {
        case .changed: "The document changed. Open the object editor again."
        case .invalid: "Use a rectangular table, balanced cell content, and a numeric image width such as 80%."
        }
    }
}

/// Mode-aware Typst source scanning shared by object editing and preview navigation.
struct ObjectScanner {
    struct Call { let name: String
        let args: [String]
        let end: Int
    }

    enum Mode { case markup, code, math }
    struct Frame { let closer: UInt16
        let mode: Mode
    }

    let units: [UInt16]
    init(_ text: String) {
        units = Array(text.utf16)
    }

    func text(_ range: NSRange)
        -> String
    {
        String(decoding: units[range.location ..< NSMaxRange(range)], as: UTF16.self)
    }

    /// Escapes, raw text, comments, and (outside markup) strings, which hide every delimiter.
    func ignored(at index: Int, mode: Mode) -> Int? {
        if units[index] == 92 {
            return min(index + 2, units.count)
        }
        if units[index] == 34, mode != .markup {
            var end = index + 1
            while end < units.count {
                if units[end] == 92 {
                    end += 2
                    continue
                }
                if units[end] == 34 {
                    return end + 1
                }
                end += 1
            }
            return units.count
        }
        if units[index] == 96 {
            var start = index
            while start < units.count, units[start] == 96 {
                start += 1
            }
            let count = start - index
            var end = start
            while end < units.count {
                if end + count <= units.count,
                   units[end ..< end + count].allSatisfy({ $0 == 96 })
                {
                    return end + count
                }
                end += 1
            }
            return units.count
        }
        if index + 1 < units.count, units[index] == 47 {
            if units[index + 1] == 47 {
                return units[index...].firstIndex(of: 10) ?? units.count
            }
            if units[index + 1] == 42 {
                var end = index + 2, depth = 1
                while end + 1 < units.count {
                    if units[end] == 47, units[end + 1] == 42 {
                        depth += 1
                        end += 2
                    } else if units[end] == 42, units[end + 1] == 47 {
                        depth -= 1
                        end += 2
                        if depth == 0 {
                            return end
                        }
                    } else {
                        end += 1
                    }
                }
                return units.count
            }
        }
        return nil
    }

    func balanced(at start: Int) -> Int? {
        guard let frame = Self.frame(units[start], in: .code) else {
            return nil
        }
        return scan(from: start + 1, frames: [frame])
    }

    /// Walks the source with each open delimiter's lexical mode: `"` starts a string only in code
    /// and math, and `#` starts embedded code in markup and math. With open `frames`, returns the
    /// index after the outermost one closes, or nil for unbalanced or unsupported input. Without
    /// frames it leniently scans a whole document and offers each embedded `#` to `visit`, which
    /// may return the index to continue from.
    /// A `lenient` scan with open frames also returns where the outermost one closes, but accepts
    /// statements and stray closers as a whole-document scan does. `code` sees each code-mode index.
    func scan(
        from start: Int,
        frames initial: [Frame],
        lenient: Bool = false,
        visit: (Int) -> Int? = { _ in nil },
        code: (Int) -> Void = { _ in },
    ) -> Int? {
        let strict = !initial.isEmpty && !lenient
        var frames = initial, index = start
        while index < units.count {
            let mode = frames.last?.mode ?? .markup, unit = units[index]
            if let end = ignored(at: index, mode: mode) {
                index = end
                continue
            }
            if unit == frames.last?.closer || unit == 59 && frames.last?.closer == 10 {
                frames.removeLast()
                index += 1
                if !initial.isEmpty, frames.isEmpty {
                    return index
                }
                continue
            }
            if mode == .code {
                code(index)
            }
            if mode != .code, unit == 35 {
                if let end = visit(index) {
                    index = end
                    continue
                }
                guard let end = embedded(at: index + 1, frames: &frames, strict: strict) else {
                    return nil
                }
                index = end
                continue
            }
            if let frame = Self.frame(unit, in: mode) {
                frames.append(frame)
            } else if [41, 93, 125].contains(unit) {
                guard !strict else {
                    return nil
                }
                // Recover from prose such as "1)" by closing back to the matching delimiter.
                if let match = frames.lastIndex(where: { $0.closer == unit }) {
                    frames.removeSubrange(match...)
                    if !initial.isEmpty, frames.isEmpty {
                        return index + 1
                    }
                }
            }
            index += 1
        }
        return initial.isEmpty ? units.count : nil
    }

    /// Consumes the start of the code after a markup `#`: a string, an identifier chain, and an
    /// attached delimiter. Statements such as `#let` run to the end of the line; inside content
    /// they stay in source mode.
    private func embedded(at start: Int, frames: inout [Frame], strict: Bool) -> Int? {
        guard start < units.count else {
            return start
        }
        if units[start] == 34 {
            return ignored(at: start, mode: .code)
        }
        var index = start
        while index < units.count, (48 ... 57).contains(units[index]) || (65 ... 90).contains(units[index])
            || (97 ... 122).contains(units[index]) || [45, 46, 95].contains(units[index])
        {
            index += 1
        }
        let name = text(NSRange(location: start, length: index - start))
        if ["let", "set", "show", "import", "include", "if", "for", "while", "return", "context"].contains(name) {
            guard !strict else {
                return nil
            }
            frames.append(Frame(closer: 10, mode: .code))
            return index
        }
        if index < units.count, [40, 91, 123].contains(units[index]), let frame = Self.frame(units[index], in: .code) {
            frames.append(frame)
            return index + 1
        }
        return index
    }

    /// Parentheses and braces keep the surrounding mode; brackets hold markup and `$` math.
    static func frame(_ unit: UInt16, in mode: Mode) -> Frame? {
        switch unit {
        case 40: Frame(closer: 41, mode: mode)
        case 91: Frame(closer: 93, mode: .markup)
        case 123: Frame(closer: 125, mode: mode)
        case 36: Frame(closer: 36, mode: .math)
        default: nil
        }
    }

    func call(at start: Int) -> Call? {
        var index = start
        while index < units.count,
              (97 ... 122).contains(units[index]) || units[index] == 46 || units[index] == 45
        {
            index += 1
        }
        guard index > start, index < units.count, units[index] == 40,
              let (ranges, end) = arguments(at: index), ranges.allSatisfy({ $0.length > 0 })
        else {
            return nil
        }
        return Call(name: text(NSRange(location: start, length: index - start)), args: ranges.map(text), end: end)
    }

    /// Trimmed ranges of the comma-separated arguments in the parentheses at `open`, and the
    /// index after them. A trailing comma adds no argument; an empty middle one has length 0.
    func arguments(at open: Int) -> ([NSRange], Int)? {
        guard units[open] == 40, let end = balanced(at: open) else {
            return nil
        }
        var ranges: [NSRange] = [], from = open + 1, index = open + 1
        while index < end - 1 {
            if let ignored = ignored(at: index, mode: .code) {
                index = ignored
                continue
            }
            if [36, 40, 91, 123].contains(units[index]), let nested = balanced(at: index) {
                index = nested
                continue
            }
            if units[index] == 44 {
                ranges.append(trimmed(from, index))
                from = index + 1
            }
            index += 1
        }
        let tail = trimmed(from, end - 1)
        if tail.length > 0 {
            ranges.append(tail)
        }
        return (ranges, end)
    }

    func trimmed(_ start: Int, _ end: Int) -> NSRange {
        var start = start, end = end
        while start < end, Self.space(units[start]) {
            start += 1
        }
        while end > start, Self.space(units[end - 1]) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    static func space(_ unit: UInt16) -> Bool {
        [9, 10, 13, 32].contains(unit)
    }

    static func exactCall(_ text: String) -> Call? {
        let scanner = Self(text)
        guard let call = scanner.call(at: 0), call.end == scanner.units.count else {
            return nil
        }
        return call
    }

    static func content(_ text: String) -> String? {
        let scanner = Self(text)
        guard scanner.units.first == 91, scanner.balanced(at: 0) == scanner.units.count else {
            return nil
        }
        return String(text.dropFirst().dropLast())
    }

    static func named(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else {
            return nil
        }
        return (
            String(text[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    static func scalar(_ text: String) -> Bool {
        text.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:%|pt|mm|cm|in|em)$"#, options: .regularExpression) != nil
    }

    static func string(_ text: String) -> String? {
        // JSON shares this conservative quoted-string subset with Typst.
        guard text.first == "\"", let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        else {
            return nil
        }
        return value
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}
