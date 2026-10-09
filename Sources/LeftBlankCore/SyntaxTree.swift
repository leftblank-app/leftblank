internal import LeftBlankSyntaxFFI
import Foundation
import os

/// Stable LeftBlank kind codes from `Engine/SyntaxBridge` (`kinds!`). Append only;
/// never renumber. Names follow typst-syntax, with a `Keyword` suffix for keywords.
public enum SyntaxKind: UInt16, Sendable, CaseIterable {
    /// A code this build does not know, from a newer parser.
    case other = 0
    case markup = 1
    case text = 2
    case space = 3
    case linebreak = 4
    case parbreak = 5
    case escape = 6
    case shorthand = 7
    case smartQuote = 8
    case strong = 9
    case emph = 10
    case raw = 11
    case rawLang = 12
    case rawDelim = 13
    case rawTrimmed = 14
    case link = 15
    case label = 16
    case ref = 17
    case refMarker = 18
    case heading = 19
    case headingMarker = 20
    case listItem = 21
    case listMarker = 22
    case enumItem = 23
    case enumMarker = 24
    case termItem = 25
    case termMarker = 26
    case equation = 27
    case math = 28
    case hash = 30
    case leftBrace = 31
    case rightBrace = 32
    case leftBracket = 33
    case rightBracket = 34
    case leftParen = 35
    case rightParen = 36
    case comma = 37
    case colon = 38
    case star = 39
    case underscore = 40
    case dollar = 41
    case semicolon = 42
    case eq = 43
    case dot = 44
    case dots = 45
    case code = 50
    case ident = 51
    case bool = 52
    case int = 53
    case float = 54
    case numeric = 55
    case str = 56
    case codeBlock = 57
    case contentBlock = 58
    case parenthesized = 59
    case array = 60
    case dict = 61
    case named = 62
    case keyed = 63
    case fieldAccess = 64
    case funcCall = 65
    case args = 66
    case spread = 67
    case closure = 68
    case params = 69
    case letBinding = 70
    case setRule = 71
    case showRule = 72
    case moduleImport = 73
    case moduleInclude = 74
    case conditional = 75
    case whileLoop = 76
    case forLoop = 77
    case contextual = 78
    case unary = 79
    case binary = 80
    case lineComment = 81
    case blockComment = 82
    case error = 83
    case noneKeyword = 84
    case autoKeyword = 85
    case destructuring = 86
    case letKeyword = 87
    case setKeyword = 88
    case showKeyword = 89
    case importKeyword = 90
    case includeKeyword = 91
    case end = 92
    case shebang = 93
    case mathText = 94
    case mathIdent = 95
    case mathFieldAccess = 96
    case mathShorthand = 97
    case mathAlignPoint = 98
    case mathCall = 99
    case mathArgs = 100
    case mathDelimited = 101
    case mathAttach = 102
    case mathPrimes = 103
    case mathFrac = 104
    case mathRoot = 105
    case plus = 106
    case minus = 107
    case slash = 108
    case hat = 109
    case eqEq = 110
    case exclEq = 111
    case lt = 112
    case ltEq = 113
    case gt = 114
    case gtEq = 115
    case plusEq = 116
    case hyphEq = 117
    case starEq = 118
    case slashEq = 119
    case arrow = 120
    case root = 121
    case bang = 122
    case notKeyword = 123
    case andKeyword = 124
    case orKeyword = 125
    case contextKeyword = 126
    case ifKeyword = 127
    case elseKeyword = 128
    case forKeyword = 129
    case inKeyword = 130
    case whileKeyword = 131
    case breakKeyword = 132
    case continueKeyword = 133
    case returnKeyword = 134
    case asKeyword = 135
    case importItems = 136
    case importItemPath = 137
    case renamedImportItem = 138
    case loopBreak = 139
    case loopContinue = 140
    case funcReturn = 141
    case destructAssignment = 142

    /// typst-syntax's name for this code, as reported by the parser library.
    public var bridgeName: String? {
        Self.bridgeName(code: rawValue)
    }

    static func bridgeName(code: UInt16) -> String? {
        SyntaxEngine.current.flatMap { $0.kindName(code) }
    }
}

/// One node of a flattened pre-order tree. Ranges are UTF-16 (`NSRange`).
/// Text and Space leaves are omitted, and Math nodes have no children.
public struct SyntaxNode: Equatable, Sendable {
    public let kind: SyntaxKind
    public let range: NSRange
    /// Index of the parent in the same array; nil for the root.
    public let parent: Int?
    /// Depth below the root, saturating at 255.
    public let depth: Int
    /// The node or a descendant contains a syntax error.
    public let isErroneous: Bool

    public init(kind: SyntaxKind, range: NSRange, parent: Int?, depth: Int, isErroneous: Bool) {
        self.kind = kind
        self.range = range
        self.parent = parent
        self.depth = depth
        self.isErroneous = isErroneous
    }
}

/// The parser's C function table. It points at an immutable static in the
/// library, so sharing it across threads is safe.
private struct SyntaxEngine: @unchecked Sendable {
    let api: UnsafePointer<LBSyntaxAPI>

    init?(_ api: UnsafePointer<LBSyntaxAPI>) {
        guard api.pointee.abi_version == LB_SYNTAX_ABI_VERSION,
              Int(api.pointee.node_size) == MemoryLayout<LBSyntaxNode>.size
        else {
            return nil
        }
        self.api = api
    }

    func kindName(_ code: UInt16) -> String? {
        api.pointee.kind_name(code).map { String(cString: $0) }
    }

    private static let installed = OSAllocatedUnfairLock<SyntaxEngine?>(initialState: {
        #if os(macOS)
            // The macOS manifest links Engine/SyntaxBridge into LeftBlankCore.
            SyntaxEngine(lb_syntax_api())
        #else
            // On iPad the parser is part of the app's engine library; see SyntaxTree.install.
            nil
        #endif
    }())

    static var current: SyntaxEngine? {
        installed.withLock { $0 }
    }

    static func install(_ engine: SyntaxEngine) {
        installed.withLock { $0 = engine }
    }
}

/// A typst-syntax parse of one source text, kept in sync with the editor's edits.
///
/// Swift owns the text; this mirrors each native replacement so typst-syntax
/// can reparse incrementally. Not thread-safe: use one serial owner.
public final class SyntaxTree {
    private let engine: SyntaxEngine
    private var handle: OpaquePointer?

    /// Whether the parser library is linked (macOS) or was installed (iPad).
    public static var isAvailable: Bool {
        SyntaxEngine.current != nil
    }

    /// Provides the parser on platforms where the app, not LeftBlankCore, links
    /// it: pass the iPad engine library's `lb_syntax_api()`. Returns false, and
    /// changes nothing, if the table has a different ABI version or layout.
    @discardableResult
    public static func install(_ table: UnsafeRawPointer) -> Bool {
        guard let engine = SyntaxEngine(table.assumingMemoryBound(to: LBSyntaxAPI.self)) else {
            return false
        }
        SyntaxEngine.install(engine)
        return true
    }

    /// The installed table, for tests.
    static var installedTable: UnsafeRawPointer? {
        SyntaxEngine.current.map { UnsafeRawPointer($0.api) }
    }

    /// Parses `source`; nil when no parser is available.
    public init?(_ source: String) {
        guard let engine = SyntaxEngine.current else {
            return nil
        }
        var source = source
        guard let handle = source.withUTF8({ engine.api.pointee.parse($0.baseAddress, $0.count) }) else {
            return nil
        }
        self.engine = engine
        self.handle = handle
    }

    deinit {
        engine.api.pointee.free(handle)
    }

    /// UTF-16 length of the parsed text; 0 after a failed edit.
    public var utf16Length: Int {
        Int(engine.api.pointee.utf16_length(handle))
    }

    /// Whether the tree still mirrors its text. After a failed edit it does not;
    /// parse the current text again.
    public var isValid: Bool {
        handle != nil
    }

    /// Mirrors one native replacement of UTF-16 `range`, and returns the range
    /// typst-syntax reparsed in the new text. Returns nil, and invalidates the
    /// tree, for a range outside the text or one that splits a surrogate pair.
    public func edit(_ range: NSRange, replacement: String) -> NSRange? {
        guard let handle, range.location >= 0, range.length >= 0, NSMaxRange(range) <= Int(UInt32.max) else {
            invalidate()
            return nil
        }
        var start: UInt32 = 0, end: UInt32 = 0
        var replacement = replacement
        let applied = replacement.withUTF8 { buffer in
            engine.api.pointee.edit(
                handle,
                UInt32(range.location),
                UInt32(NSMaxRange(range)),
                buffer.baseAddress,
                buffer.count,
                &start,
                &end,
            )
        }
        guard applied else {
            invalidate()
            return nil
        }
        return NSRange(location: Int(start), length: Int(end) - Int(start))
    }

    /// Nodes overlapping `window` (the whole text when nil), in pre-order. An
    /// empty window selects the nodes touching that point. Each node is listed
    /// with its parent. Nil after a failed edit.
    public func nodes(in window: NSRange? = nil) -> [SyntaxNode]? {
        guard let handle else {
            return nil
        }
        let start = window.map { UInt32(clamping: max(0, $0.location)) } ?? 0
        let end = window.map { UInt32(clamping: max(0, NSMaxRange($0))) } ?? UInt32.max
        var count = 0
        guard let raw = engine.api.pointee.nodes(handle, start, max(start, end), &count) else {
            return nil
        }
        defer { engine.api.pointee.nodes_free(raw, count) }
        return UnsafeBufferPointer(start: raw, count: count).map { node in
            SyntaxNode(
                kind: SyntaxKind(rawValue: node.kind) ?? .other,
                range: NSRange(location: Int(node.start), length: Int(node.end) - Int(node.start)),
                parent: node.parent == LB_SYNTAX_NO_PARENT ? nil : Int(node.parent),
                depth: Int(node.depth),
                isErroneous: UInt32(node.flags) & LB_SYNTAX_NODE_ERRONEOUS != 0,
            )
        }
    }

    private func invalidate() {
        engine.api.pointee.free(handle)
        handle = nil
    }
}

/// Children of each node in a pre-order list, as `SyntaxTree.nodes` returns it.
struct SyntaxChildren {
    let nodes: [SyntaxNode]
    let children: [[Int]]

    init(_ nodes: [SyntaxNode]) {
        var children = [[Int]](repeating: [], count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, parent < nodes.count {
                children[parent].append(index)
            }
        }
        self.nodes = nodes
        self.children = children
    }

    func children(_ index: Int, _ kind: SyntaxKind) -> [SyntaxNode] {
        children[index].map { nodes[$0] }.filter { $0.kind == kind }
    }
}

/// Typst string literals.
enum TypstString {
    /// The contents of a Typst string literal; nil for an escape this model does not decode.
    static func decode(_ raw: String) -> String? {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
            return nil
        }
        var result = "", escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\", "\"": result.append(character)
                default: return nil
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    /// A Typst string literal for `value`.
    static func encode(_ value: String) -> String {
        var result = "\""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }
}
