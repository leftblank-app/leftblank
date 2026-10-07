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

    private static let names: Set = ["table", "image", "figure", "align"]
    private static let alignments: Set = ["left", "center", "right"]

    public static func at(_ selection: NSRange, in source: String) -> Self? {
        let text = source as NSString
        guard selection.location >= 0, selection.length >= 0, selection.location <= text.length,
              selection.length <= text.length - selection.location, let nodes = SyntaxTree(source)?.nodes()
        else {
            return nil
        }
        let syntax = ObjectSyntax(nodes, source: text)
        // Pre-order, so an enclosing object wins; a nested one is offered when it does not parse.
        for (index, node) in nodes.enumerated() where node.kind == .hash {
            guard let call = syntax.embeddedCall(after: index), let name = syntax.callee(call),
                  names.contains(name)
            else {
                continue
            }
            let range = NSRange(
                location: node.range.location,
                length: NSMaxRange(nodes[call].range) - node.range.location,
            )
            if selection.location >= range.location, NSMaxRange(selection) <= NSMaxRange(range),
               let object = parse(text.substring(with: range), range: range)
            {
                return object
            }
        }
        return nil
    }

    /// Parses `original`, which must be exactly one embedded `#call(…)`. An attached
    /// content block is one more argument, so such calls stay in source mode.
    private static func parse(_ original: String, range: NSRange) -> Self? {
        guard let nodes = SyntaxTree(original)?.nodes(), let root = nodes.first, !root.isErroneous else {
            return nil
        }
        let syntax = ObjectSyntax(nodes, source: original as NSString)
        guard syntax.tree.children[0].count == 2, let call = syntax.embeddedCall(after: 1),
              nodes[1].range.location == 0,
              NSMaxRange(nodes[call].range) == root.range.length, let name = syntax.callee(call),
              let args = syntax.arguments(call)
        else {
            return nil
        }
        if name == "table" {
            return table(args, syntax: syntax, range: range, original: original)
        }
        var result = Self(kind: .image, range: range, original: original)
        var imageCall = call, imageArgs = args
        if syntax.callee(imageCall) == "align" {
            guard imageArgs.count == 2, nodes[imageArgs[0]].kind == .ident,
                  alignments.contains(syntax.text(imageArgs[0])), let nested = syntax.arguments(imageArgs[1])
            else {
                return nil
            }
            result.alignment = syntax.text(imageArgs[0])
            (imageCall, imageArgs) = (imageArgs[1], nested)
        }
        if syntax.callee(imageCall) == "figure" {
            guard imageArgs.count == 2, let nested = syntax.arguments(imageArgs[0]),
                  let (key, value) = syntax.named(imageArgs[1]), key == "caption", nodes[value].kind == .str,
                  let caption = Presentation.decodeString(syntax.text(value))
            else {
                return nil
            }
            result.caption = caption
            (imageCall, imageArgs) = (imageArgs[0], nested)
        }
        guard syntax.callee(imageCall) == "image", (1 ... 2).contains(imageArgs.count),
              nodes[imageArgs[0]].kind == .str, let path = Presentation.decodeString(syntax.text(imageArgs[0]))
        else {
            return nil
        }
        result.path = path
        if imageArgs.count == 2 {
            guard let (key, value) = syntax.named(imageArgs[1]), key == "width", nodes[value].kind == .numeric,
                  scalar(syntax.text(value))
            else {
                return nil
            }
            result.width = syntax.text(value)
        }
        return result
    }

    private static func table(_ args: [Int], syntax: ObjectSyntax, range: NSRange, original: String) -> Self? {
        var result = Self(kind: .table, range: range, original: original)
        var columns: Int?, cells: [String] = [], names = Set<String>()
        for arg in args {
            if let content = syntax.content(arg) {
                cells.append(content)
                continue
            }
            if syntax.callee(arg) == "table.header" {
                guard !result.hasHeader, cells.isEmpty, let header = syntax.arguments(arg) else {
                    return nil
                }
                let contents = header.compactMap(syntax.content)
                // Header width must match the explicit column count.
                guard contents.count == header.count, let columns, contents.count == columns else {
                    return nil
                }
                result.hasHeader = true
                cells += contents
                continue
            }
            guard let (key, value) = syntax.named(arg), names.insert(key).inserted else {
                return nil
            }
            let kind = syntax.tree.nodes[value].kind, text = syntax.text(value)
            switch key {
            case "columns":
                guard kind == .int, let count = Int(text), (1 ... 20).contains(count) else {
                    return nil
                }
                columns = count
            case "align":
                guard kind == .ident, alignments.contains(text) else {
                    return nil
                }
                result.alignment = text
            case "inset", "gutter", "row-gutter", "column-gutter", "stroke", "fill":
                // These options stay byte-for-byte intact; they never depend on row/column indices.
                guard kind == .numeric && scalar(text) || kind == .noneKeyword || kind == .autoKeyword else {
                    return nil
                }
                result.options.append(syntax.text(arg))
            default: return nil
            }
        }
        guard let columns, !cells.isEmpty, cells.count.isMultiple(of: columns), cells.count / columns <= 100 else {
            return nil
        }
        result.rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0 ..< $0 + columns]) }
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
                  rows.allSatisfy({ $0.count == columns }),
                  alignment.isEmpty || Self.alignments.contains(alignment)
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
            guard !path.isEmpty, width.isEmpty || Self.scalar(width),
                  alignment.isEmpty || Self.alignments.contains(alignment)
            else {
                throw ObjectEditError.invalid
            }
            var call = "image(" + Presentation.encodeString(path) + (width.isEmpty ? "" : ", width: " + width) + ")"
            if let caption {
                call = "figure(\n  \(call),\n  caption: \(Presentation.encodeString(caption)),\n)"
            }
            if !alignment.isEmpty {
                call = "align(\(alignment), \(call))"
            }
            replacement = "#" + call
        }
        // Each cell must stay one balanced content block: the result reads back as this object.
        guard let written = Self.parse(replacement, range: range),
              (written.kind, written.rows, written.hasHeader, written.alignment) == (kind, rows, hasHeader, alignment),
              (written.path, written.width, written.caption, written.options) == (path, width, caption, options)
        else {
            throw ObjectEditError.invalid
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

    /// A plain length such as `80%` or `2.5em`.
    private static func scalar(_ text: String) -> Bool {
        text.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:%|pt|mm|cm|in|em)$"#, options: .regularExpression) != nil
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

/// Call and argument structure of literal objects, read from the typst-syntax tree.
private struct ObjectSyntax {
    /// Code that runs inside a cell. Such cells are generated, so they stay in source mode.
    static let statements: Set<SyntaxKind> = [
        .letBinding, .setRule, .showRule, .moduleImport, .moduleInclude, .conditional, .whileLoop, .forLoop,
        .contextual, .funcReturn, .loopBreak, .loopContinue, .destructAssignment,
    ]

    let tree: Presentation.Tree
    let source: NSString

    init(_ nodes: [SyntaxNode], source: NSString) {
        tree = Presentation.Tree(nodes)
        self.source = source
    }

    func text(_ index: Int) -> String {
        source.substring(with: tree.nodes[index].range)
    }

    /// The call that a markup `#` at `hash` embeds.
    func embeddedCall(after hash: Int) -> Int? {
        let nodes = tree.nodes, call = hash + 1
        guard nodes[hash].kind == .hash, call < nodes.count, nodes[call].kind == .funcCall,
              nodes[call].parent == nodes[hash].parent, nodes[call].range.location == NSMaxRange(nodes[hash].range)
        else {
            return nil
        }
        return call
    }

    /// The callee of a call: `name`, or `module.name` such as `table.header`.
    func callee(_ call: Int) -> String? {
        guard tree.nodes[call].kind == .funcCall, let callee = tree.children[call].first else {
            return nil
        }
        let parts = tree.children[callee].map { tree.nodes[$0].kind }
        switch tree.nodes[callee].kind {
        case .ident: return text(callee)
        case .fieldAccess where parts == [.ident, .dot, .ident]: return text(callee)
        default: return nil
        }
    }

    /// The arguments inside the parentheses of `call`. Nil for a call with an attached
    /// content block, a comment or a spread, which a rewrite could not keep.
    func arguments(_ call: Int) -> [Int]? {
        guard callee(call) != nil, let args = tree.children[call].last, tree.nodes[args].kind == .args,
              tree.children[call].count == 2
        else {
            return nil
        }
        let parts = tree.children[args]
        guard parts.count >= 2, let first = parts.first, let last = parts.last, tree.nodes[first].kind == .leftParen,
              tree.nodes[last].kind == .rightParen
        else {
            return nil
        }
        var result: [Int] = [], separated = true
        for part in parts.dropFirst().dropLast() {
            switch tree.nodes[part].kind {
            case .comma:
                guard !separated else {
                    return nil
                }
                separated = true
            case .lineComment, .blockComment, .spread, .error:
                return nil
            default:
                guard separated else {
                    return nil
                }
                result.append(part)
                separated = false
            }
        }
        return result
    }

    /// `key: value`, with the value's index.
    func named(_ index: Int) -> (String, Int)? {
        let parts = tree.children[index]
        guard tree.nodes[index].kind == .named, parts.count == 3, tree.nodes[parts[0]].kind == .ident,
              tree.nodes[parts[1]].kind == .colon
        else {
            return nil
        }
        return (text(parts[0]), parts[2])
    }

    /// The source between the brackets of a literal content block.
    func content(_ index: Int) -> String? {
        let nodes = tree.nodes, node = nodes[index]
        guard node.kind == .contentBlock, !node.isErroneous, node.range.length >= 2,
              tree.children[index].first.map({ nodes[$0].kind }) == .leftBracket,
              tree.children[index].last.map({ nodes[$0].kind }) == .rightBracket
        else {
            return nil
        }
        guard !runs(index) else {
            return nil
        }
        return source.substring(with: NSRange(location: node.range.location + 1, length: node.range.length - 2))
    }

    private func runs(_ index: Int) -> Bool {
        Self.statements.contains(tree.nodes[index].kind) || tree.children[index].contains(where: runs)
    }
}
