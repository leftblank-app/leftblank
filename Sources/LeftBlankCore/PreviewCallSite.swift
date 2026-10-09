import Foundation

/// The text under a preview click, reported by the shared preview script.
public struct PreviewClick: Equatable, Sendable {
    /// The clicked text run, without surrounding whitespace.
    public let text: String
    /// The text runs on the clicked line, which tell apart calls with an equal argument.
    public let line: String

    public init?(text: String, line: String = "") {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        self.text = text
        self.line = line
    }

    public init?(message: [String: Any]) {
        guard message["kind"] as? String == "click", let text = message["text"] as? String else {
            return nil
        }
        self.init(text: text, line: message["line"] as? String ?? "")
    }
}

/// Typst gives a string value no source span. Text that a function displays from its
/// parameter, as in `#let item(id) = [== #id]`, therefore jumps to the parameter in the
/// function body rather than to the `#item("LB-001")` call that supplied it. This moves
/// such a target to the call argument that contains the clicked text. It stays where it
/// is unless one call clearly matches. Offsets use UTF-16, like both native editors.
public enum PreviewCallSite {
    /// Function parameters forwarded to another function are followed up to this depth.
    static let forwardingLimit = 4

    public static func offset(_ offset: Int, in source: String, click: PreviewClick?) -> Int {
        let text = source as NSString
        guard offset >= 0, offset < text.length, source.contains("let"), let nodes = SyntaxTree(source)?.nodes() else {
            return offset
        }
        let index = Index(nodes, source: text)
        var offset = offset
        for _ in 0 ..< forwardingLimit {
            guard let (next, forwarded) = index.argument(for: offset, click: click) else {
                break
            }
            offset = next
            if !forwarded {
                break
            }
        }
        return offset
    }
}

private struct Definition {
    let name: String
    /// Where the function's name starts.
    let start: Int
    /// Positional parameter names in order; nil for destructuring or after a sink.
    let positional: [String?]
    let named: Set<String>
    let body: NSRange
}

private enum Slot: Equatable {
    case positional(Int)
    case named(String)
}

/// `#let name(…) = body` definitions and calls of named functions, from the syntax tree.
private struct Index {
    let tree: SyntaxChildren
    let source: NSString
    var definitions: [Definition] = []
    /// Call nodes by callee name, in document order.
    var calls: [String: [Int]] = [:]

    init(_ nodes: [SyntaxNode], source: NSString) {
        tree = SyntaxChildren(nodes)
        self.source = source
        for (index, node) in nodes.enumerated() {
            if node.kind == .letBinding, let definition = definition(index) {
                definitions.append(definition)
            } else if node.kind == .funcCall, let callee = tree.children[index].first, nodes[callee].kind == .ident {
                calls[text(callee), default: []].append(index)
            }
        }
    }

    func text(_ index: Int) -> String {
        source.substring(with: tree.nodes[index].range)
    }

    func definition(_ binding: Int) -> Definition? {
        let nodes = tree.nodes
        guard let closure = tree.children[binding].first(where: { nodes[$0].kind == .closure }),
              let name = tree.children[closure].first, nodes[name].kind == .ident,
              let params = tree.children[closure].first(where: { nodes[$0].kind == .params }),
              let eq = tree.children[closure].firstIndex(where: { nodes[$0].kind == .eq }),
              let body = tree.children[closure].last, eq < tree.children[closure].count - 1
        else {
            return nil
        }
        var positional: [String?] = [], named: Set<String> = [], sink = false
        for parameter in tree.children[params] {
            switch nodes[parameter].kind {
            case .leftParen, .rightParen, .comma, .lineComment, .blockComment:
                continue
            case .ident:
                positional.append(sink ? nil : text(parameter))
            case .named:
                if let key = tree.children[parameter].first, nodes[key].kind == .ident {
                    named.insert(text(key))
                }
            case .spread:
                sink = true
                positional.append(nil)
            default:
                // Destructuring and `_` bind no single name.
                positional.append(nil)
            }
        }
        return Definition(
            name: text(name),
            start: nodes[name].range.location,
            positional: positional,
            named: named,
            body: nodes[body].range,
        )
    }

    /// Whether the identifier at `index` reads a variable, rather than naming a field, a key or a binding.
    func reads(_ index: Int) -> Bool {
        guard let parent = tree.nodes[index].parent else {
            return true
        }
        switch tree.nodes[parent].kind {
        case .fieldAccess, .named, .closure: return tree.children[parent].first != index
        case .letBinding, .params, .destructuring: return false
        default: return true
        }
    }

    /// The call argument for the parameter at `target`, and whether that argument is itself
    /// a parameter forwarded by an enclosing function.
    func argument(for target: Int, click: PreviewClick?) -> (Int, Bool)? {
        let nodes = tree.nodes
        var position = target
        if source.character(at: position) == 35, position + 1 < source.length {
            position += 1
        }
        guard let identifier = nodes.indices.first(where: {
            nodes[$0].kind == .ident && NSLocationInRange(position, nodes[$0].range)
        }), reads(identifier) else {
            return nil
        }
        let start = nodes[identifier].range.location, name = text(identifier)
        guard let definition = definitions.filter({ NSLocationInRange(start, $0.body) })
            .sorted(by: { $0.body.length < $1.body.length })
            .first(where: { slot(for: name, in: $0) != nil }),
            let slot = slot(for: name, in: definition)
        else {
            return nil
        }
        // A later definition with the same name shadows this one.
        let shadow = definitions.first { $0.name == definition.name && $0.start > definition.start }?.start ?? Int.max
        let sites = (calls[definition.name] ?? []).filter {
            nodes[$0].range.location > definition.start && nodes[$0].range.location < shadow
        }.compactMap(arguments)
        let values = sites.compactMap { $0.value(for: slot) }
        if let click {
            let scored = sites.compactMap { site -> (score: Int, context: Int, offset: Int)? in
                guard let value = site.value(for: slot), let match = match(click.text, in: value) else {
                    return nil
                }
                let context = site.all.filter { $0 != value }.flatMap(pieces)
                    .count { !$0.trimmed.isEmpty && click.line.contains($0.trimmed) }
                return (match.score, context, match.offset)
            }
            if let best = scored.max(by: { ($0.score, $0.context) < ($1.score, $1.context) }) {
                let ties = scored.count { $0.score == best.score && $0.context == best.context }
                return ties == 1 ? (best.offset, false) : nil
            }
        }
        // A single call is the only one that can have displayed this parameter.
        guard sites.count == 1, values.count == 1, let value = values.first else {
            return nil
        }
        let location = nodes[value].range.location
        if let piece = pieces(in: value).first, location == piece.start - 1 {
            return (piece.start, false)
        }
        return (location, nodes[value].kind == .ident)
    }

    func slot(for name: String, in definition: Definition) -> Slot? {
        if let index = definition.positional.firstIndex(of: name) {
            return .positional(index)
        }
        return definition.named.contains(name) ? .named(name) : nil
    }

    /// Positional, named and trailing content arguments of `call`.
    func arguments(_ call: Int) -> Call? {
        guard let args = tree.children[call].last, tree.nodes[args].kind == .args else {
            return nil
        }
        var result = Call()
        for part in tree.children[args] {
            switch tree.nodes[part].kind {
            case .leftParen, .rightParen, .comma, .lineComment, .blockComment:
                continue
            case .spread:
                result.spread = true
            case .named:
                if let key = tree.children[part].first, tree.nodes[key].kind == .ident,
                   let value = tree.children[part].last, value != key
                {
                    result.named[text(key)] = value
                }
            default:
                result.positional.append(result.spread ? nil : part)
            }
            result.all.append(part)
        }
        return result
    }

    /// Where `text` appears in a string or content literal of the argument `value`.
    /// An exact literal scores 3, a literal containing it 2, and a literal it contains 1.
    func match(_ text: String, in value: Int) -> (score: Int, offset: Int)? {
        let needle = Array(text.utf16)
        var best: (score: Int, offset: Int)?
        for piece in pieces(in: value) {
            let candidate: (score: Int, offset: Int)? = if piece.trimmed == text {
                (3, piece.offsets[piece.units.firstIndex(where: { !Self.space($0) }) ?? 0])
            } else if let found = Self.find(needle, in: piece.units) {
                (2, piece.offsets[found])
            } else if !piece.trimmed.isEmpty, text.contains(piece.trimmed) {
                (1, piece.start)
            } else {
                nil
            }
            if let candidate, candidate.score > best?.score ?? 0 {
                best = candidate
            }
        }
        return best
    }

    /// String and content literals in an argument, such as its value or the fields of a
    /// dictionary, with each decoded UTF-16 unit's source offset. Content is not searched
    /// for nested literals: its source is the piece.
    func pieces(in index: Int) -> [Piece] {
        let node = tree.nodes[index], range = node.range
        switch node.kind {
        case .str:
            let closed = range.length >= 2 && source.character(at: NSMaxRange(range) - 1) == 34
            return [decoded(from: range.location + 1, to: NSMaxRange(range) - (closed ? 1 : 0))]
        case .contentBlock:
            let closed = tree.children[index].last.map { tree.nodes[$0].kind == .rightBracket } ?? false
            let inner = range.location + 1 ..< max(range.location + 1, NSMaxRange(range) - (closed ? 1 : 0))
            return [Piece(units: inner.map(source.character), offsets: Array(inner), start: range.location + 1)]
        default:
            return tree.children[index].flatMap(pieces)
        }
    }

    /// Typst string escapes, mapping each decoded unit to the escape that produced it.
    func decoded(from start: Int, to end: Int) -> Piece {
        var decoded: [UInt16] = [], offsets: [Int] = [], index = start
        while index < end {
            let unit = source.character(at: index)
            var produced: [UInt16] = [unit], next = index + 1
            if unit == 92, index + 1 < end {
                next = index + 2
                switch source.character(at: index + 1) {
                case 110: produced = [10]
                case 114: produced = [13]
                case 116: produced = [9]
                case 117 where index + 2 < end && source.character(at: index + 2) == 123:
                    let tail = NSRange(location: index + 3, length: end - index - 3)
                    let close = source.range(of: "}", options: .literal, range: tail).location
                    if close != NSNotFound,
                       let value = UInt32(
                           source.substring(with: NSRange(location: index + 3, length: close - index - 3)),
                           radix: 16,
                       ),
                       let scalar = Unicode.Scalar(value)
                    {
                        produced = Array(String(scalar).utf16)
                        next = close + 1
                    } else {
                        produced = [117]
                    }
                case let escaped: produced = [escaped]
                }
            }
            decoded += produced
            offsets += Array(repeating: index, count: produced.count)
            index = next
        }
        return Piece(units: decoded, offsets: offsets, start: start)
    }

    static func space(_ unit: UInt16) -> Bool {
        [9, 10, 13, 32].contains(unit)
    }

    static func find(_ needle: [UInt16], in units: [UInt16]) -> Int? {
        guard !needle.isEmpty, needle.count <= units.count else {
            return nil
        }
        return (0 ... units.count - needle.count).first { units[$0 ..< $0 + needle.count].elementsEqual(needle) }
    }
}

private struct Call {
    /// Every argument node, including spreads and trailing content blocks.
    var all: [Int] = []
    /// Positional arguments in order; nil after a spread, whose position is unknown.
    var positional: [Int?] = []
    var named: [String: Int] = [:]
    var spread = false

    func value(for slot: Slot) -> Int? {
        switch slot {
        case let .positional(index): index < positional.count ? positional[index] : nil
        case let .named(name): named[name]
        }
    }
}

private struct Piece {
    let units: [UInt16]
    let offsets: [Int]
    /// The source offset where the literal's text starts.
    let start: Int
    var trimmed: String {
        String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
