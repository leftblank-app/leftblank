import Foundation

public enum LineAction: Sendable { case indent, outdent, comment }

public struct TextReplacement: Equatable, Sendable {
    public let range: NSRange
    public let text: String
    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

public enum TextEditing {
    public static func lines(_ action: LineAction, text: String, selection: NSRange) -> TextReplacement {
        let source = text as NSString
        let location = min(max(0, selection.location), source.length)
        var length = min(max(0, selection.length), source.length - location)
        // A selection ending exactly at the next line's beginning does not include it.
        if length > 0,
           source.substring(with: NSRange(location: location + length - 1, length: 1)) == "\n"
        {
            length -= 1
        }
        let range = source.lineRange(for: NSRange(location: location, length: length))
        let original = source.substring(with: range)
        var lines = original.components(separatedBy: "\n")
        let trailingNewline = original.hasSuffix("\n")
        if trailingNewline {
            lines.removeLast()
        }
        let uncomment = !lines.isEmpty && lines
            .allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") || $0.trimmingCharacters(in: .whitespaces)
                    .isEmpty
            }
        lines = lines.map { line in
            switch action {
            case .indent: return "  " + line
            case .outdent:
                if line.hasPrefix("\t") {
                    return String(line.dropFirst())
                }
                return String(line.dropFirst(line.prefix(2).prefix(while: { $0 == " " }).count))
            case .comment:
                let prefix = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let rest = String(line.dropFirst(prefix.count))
                if uncomment {
                    guard rest.hasPrefix("//") else {
                        return line
                    }
                    let content = rest.dropFirst(2)
                    return prefix + (content.hasPrefix(" ") ? String(content.dropFirst()) : String(content))
                }
                return prefix + "// " + rest
            }
        }
        return .init(range: range, text: lines.joined(separator: "\n") + (trailingNewline ? "\n" : ""))
    }

    public static func applying(_ edits: [TextReplacement], to text: String) throws -> String {
        let result = NSMutableString(string: text)
        var boundary = result.length
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.location >= 0, edit.range.length >= 0, edit.range.location <= boundary,
                  edit.range.length <= boundary - edit.range.location
            else {
                throw CommandError.invalid("排版服务返回了无效或重叠的编辑范围。")
            }
            result.replaceCharacters(in: edit.range, with: edit.text)
            boundary = edit.range.location
        }
        return result as String
    }
}

/// Literal text equality for whole documents. Swift's `==` compares Unicode
/// canonical equivalence, which for a 3 MB book bridged from a text view takes
/// tens of milliseconds; editors only need the same UTF-16 sequence.
public enum TextIdentity {
    public static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs as NSString
        return left.length == (rhs as NSString).length && left.isEqual(to: rhs)
    }
}
