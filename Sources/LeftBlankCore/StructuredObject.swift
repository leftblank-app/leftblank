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
        var index = 0
        while index < scanner.units.count {
            if let end = scanner.ignored(at: index) {
                index = end
                continue
            }
            guard scanner.units[index] == 35,
                  let call = scanner.call(at: index + 1),
                  ["table", "image", "figure", "align"].contains(call.name)
            else {
                index += 1
                continue
            }
            let range = NSRange(location: index, length: call.end - index)
            if selection.location >= index, NSMaxRange(selection) <= call.end,
               let object = parse(scanner.text(range), range: range)
            {
                return object
            }
            index = call.end
        }
        return nil
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

private struct ObjectScanner {
    struct Call { let name: String
        let args: [String]
        let end: Int
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

    func ignored(at index: Int) -> Int? {
        if units[index] == 92 {
            return min(index + 2, units.count)
        }
        if units[index] == 34 {
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
        let closing: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125]
        guard let first = closing[units[start]] else {
            return nil
        }
        var stack = [first], index = start + 1
        while index < units.count {
            if let end = ignored(at: index) {
                index = end
                continue
            }
            if let end = closing[units[index]] {
                stack.append(end)
            } else if [41, 93, 125].contains(units[index]) {
                guard stack.popLast() == units[index] else {
                    return nil
                }
                if stack.isEmpty {
                    return index + 1
                }
            }
            index += 1
        }
        return nil
    }

    func call(at start: Int) -> Call? {
        var index = start
        while index < units.count,
              (97 ... 122).contains(units[index]) || units[index] == 46 || units[index] == 45
        {
            index += 1
        }
        guard index > start, index < units.count, units[index] == 40, let end = balanced(at: index) else {
            return nil
        }
        let name = text(NSRange(location: start, length: index - start))
        var args: [String] = [], from = index + 1
        index += 1
        while index < end - 1 {
            if let ignored = ignored(at: index) {
                index = ignored
                continue
            }
            if [40, 91, 123].contains(units[index]), let nested = balanced(at: index) {
                index = nested
                continue
            }
            if units[index] == 44 {
                args
                    .append(text(NSRange(location: from, length: index - from))
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                from = index + 1
            }
            index += 1
        }
        let tail = text(NSRange(location: from, length: end - 1 - from)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            args.append(tail)
        }
        guard args.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return Call(name: name, args: args, end: end)
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
