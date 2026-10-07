import Foundation

/// Source text to insert with Tab placeholders, applied as one native edit.
public struct ChipInsertion: Equatable, Sendable {
    public let range: NSRange
    /// Placeholder selections are relative to the start of the snippet text.
    public let snippet: Snippet

    public init(range: NSRange, snippet: Snippet) {
        self.range = range
        self.snippet = snippet
    }
}

/// Edits that write a chip's form back to source as a single replacement, so
/// one undo restores the call.
public enum ChipEditing {
    public enum Failure: Error, Equatable {
        /// The signature has no parameter with this name.
        case unknownParameter(String)
        /// A number, boolean, `none` or `auto` argument received another kind of value.
        case invalidLiteral(parameter: String, value: String)
        /// A positional value needs every earlier positional argument.
        case missingArgument(String)
    }

    /// Replaces changed argument values and adds missing ones.
    ///
    /// `values` maps parameter names to values: the contents of a string, or
    /// the source of a number, boolean, `none` or `auto`. An argument keeps its
    /// literal kind. A missing parameter becomes a string, unless its default
    /// is another kind of literal. Spacing and comments between arguments are
    /// preserved. Returns nil when nothing changes.
    public static func edit(
        _ chip: Chip,
        values: [String: String],
        signature: FunctionSignature,
        source: NSString,
    ) throws -> TextReplacement? {
        var changes: [(range: NSRange, text: String, order: Int)] = []
        let presentPositional = chip.arguments.count(where: \.isPositional)
        var missingPositional: [(index: Int, text: String)] = []
        var missingNamed: [String] = []
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            if let argument = chip.arguments.first(where: { $0.name == name }) {
                guard argument.literal != value else {
                    continue
                }
                try changes.append((argument.valueRange, literal(value, string: argument.isString, name: name), 0))
                continue
            }
            guard let index = signature.parameters.firstIndex(where: { $0.name == name }) else {
                throw Failure.unknownParameter(name)
            }
            let parameter = signature.parameters[index]
            let string = parameter.defaultSource.map { $0.hasPrefix("\"") } ?? true
            let text = try literal(value, string: string, name: name)
            if parameter.isPositional {
                let position = signature.positional.firstIndex { $0.name == name } ?? 0
                missingPositional.append((position, text))
            } else {
                missingNamed.append("\(name): \(text)")
            }
        }
        missingPositional.sort { $0.index < $1.index }
        for (offset, entry) in missingPositional.enumerated() where entry.index != presentPositional + offset {
            throw Failure.missingArgument(signature.positional[presentPositional + offset].name)
        }
        let open = chip.range.location + 1 + (chip.callee as NSString).length + 1
        if !missingPositional.isEmpty {
            let texts = missingPositional.map(\.text).joined(separator: ", ")
            if let last = chip.arguments.last(where: \.isPositional) {
                changes.append((NSRange(location: NSMaxRange(last.valueRange), length: 0), ", " + texts, 1))
            } else {
                // Existing named arguments follow; new named ones get their own separator.
                changes.append((NSRange(location: open, length: 0), texts + (chip.arguments.isEmpty ? "" : ", "), 1))
            }
        }
        if !missingNamed.isEmpty {
            let before = source.substring(with: NSRange(location: open, length: chip.closingParenthesis - open))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = before.isEmpty && missingPositional.isEmpty ? "" : before.hasSuffix(",") ? " " : ", "
            let text = prefix + missingNamed.joined(separator: ", ")
            changes.append((NSRange(location: chip.closingParenthesis, length: 0), text, 2))
        }
        guard !changes.isEmpty else {
            return nil
        }
        changes.sort { ($0.range.location, $0.order) < ($1.range.location, $1.order) }
        let start = changes[0].range.location
        var text = "", cursor = start
        for change in changes {
            let between = NSRange(location: cursor, length: change.range.location - cursor)
            text += source.substring(with: between) + change.text
            cursor = NSMaxRange(change.range)
        }
        return TextReplacement(range: NSRange(location: start, length: cursor - start), text: text)
    }

    /// "Repeat previous call": inserts a copy of the nearest earlier chip's
    /// call at `location`. Values with display labels (enumerations) are
    /// kept; strings become empty placeholders and other values selected
    /// placeholders, in argument order.
    public static func repeatPrevious(
        before location: Int,
        chips: [Chip],
        formatter: ChipFormatter,
    ) -> ChipInsertion? {
        guard let previous = chips.last(where: { NSMaxRange($0.range) <= location }) else {
            return nil
        }
        var text = "#\(previous.callee)("
        var placeholders: [NSRange] = []
        for (index, argument) in previous.arguments.enumerated() {
            if index > 0 {
                text += ", "
            }
            if !argument.isPositional, let name = argument.name {
                text += "\(name): "
            }
            let value = argument.isString ? Presentation.encodeString(argument.literal) : argument.literal
            if let name = argument.name, formatter.valueLabels[name] != nil {
                text += value
            } else if argument.isString {
                placeholders.append(NSRange(location: (text as NSString).length + 1, length: 0))
                text += "\"\""
            } else {
                placeholders.append(NSRange(location: (text as NSString).length, length: (value as NSString).length))
                text += value
            }
        }
        text += ")"
        return ChipInsertion(
            range: NSRange(location: location, length: 0),
            snippet: Snippet(text: text, selections: placeholders),
        )
    }

    /// The source for one value, checking that a non-string value is a literal
    /// the chip model accepts.
    static func literal(_ value: String, string: Bool, name: String) throws -> String {
        if string {
            return Presentation.encodeString(value)
        }
        let code = "#(" + value + ")"
        guard let nodes = SyntaxTree(code)?.nodes(), nodes.count == 6, !nodes[0].isErroneous,
              nodes[2].kind == .parenthesized, Presentation.literal(nodes[4], source: code as NSString) != nil,
              nodes[4].kind != .str, nodes[4].range == NSRange(location: 2, length: (value as NSString).length)
        else {
            throw Failure.invalidLiteral(parameter: name, value: value)
        }
        return value
    }
}
