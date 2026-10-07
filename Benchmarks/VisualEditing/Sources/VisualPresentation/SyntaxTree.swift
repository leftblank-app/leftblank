import Foundation
import LeftBlankSyntaxFFI

/// Stable LeftBlank kind codes from Engine/SyntaxBridge (`kinds!`). Append only.
public enum SyntaxKind: UInt16, Sendable, CaseIterable {
    case other = 0
    case markup
    case text
    case space
    case linebreak
    case parbreak
    case escape
    case shorthand
    case smartQuote
    case strong
    case emph
    case raw
    case rawLang
    case rawDelim
    case rawTrimmed
    case link
    case label
    case ref
    case refMarker
    case heading
    case headingMarker
    case listItem
    case listMarker
    case enumItem
    case enumMarker
    case termItem
    case termMarker
    case equation
    case math
    case hash = 30
    case leftBrace
    case rightBrace
    case leftBracket
    case rightBracket
    case leftParen
    case rightParen
    case comma
    case colon
    case star
    case underscore
    case dollar
    case semicolon
    case eq
    case dot
    case dots
    case code = 50
    case ident
    case bool
    case int
    case float
    case numeric
    case str
    case codeBlock
    case contentBlock
    case parenthesized
    case array
    case dict
    case named
    case keyed
    case fieldAccess
    case funcCall
    case args
    case spread
    case closure
    case params
    case letBinding
    case setRule
    case showRule
    case moduleImport
    case moduleInclude
    case conditional
    case whileLoop
    case forLoop
    case contextual
    case unary
    case binary
    case lineComment
    case blockComment
    case error
    case noneLiteral
    case auto
    case destructuring
    case letKeyword
    case setKeyword
    case showKeyword
    case importKeyword
    case includeKeyword

    /// The bridge's own name for this code, for consistency tests.
    public var bridgeName: String? {
        lb_syntax_kind_name(rawValue).map { String(cString: $0) }
    }
}

/// One node of a flattened pre-order tree. Ranges are UTF-16 (NSRange).
public struct SyntaxNode: Equatable, Sendable {
    public let kind: SyntaxKind
    public let range: NSRange
    /// Index of the parent in the same array, if it was included.
    public let parent: Int?
    public let depth: Int
    public let erroneous: Bool

    public init(kind: SyntaxKind, range: NSRange, parent: Int?, depth: Int, erroneous: Bool) {
        self.kind = kind
        self.range = range
        self.parent = parent
        self.depth = depth
        self.erroneous = erroneous
    }
}

/// A typst-syntax `Source` owned by Rust and kept in sync with native edits.
/// Not thread-safe: one serial owner (an actor in production) mutates it.
public final class SyntaxTree {
    private let handle: OpaquePointer

    public init?(_ source: String) {
        var source = source
        guard let handle = source.withUTF8({ lb_syntax_parse($0.baseAddress, $0.count) }) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        lb_syntax_free(handle)
    }

    public var utf16Length: Int {
        Int(lb_syntax_utf16_length(handle))
    }

    /// Mirrors one native replacement; returns the range typst-syntax reparsed
    /// in the new text, or nil if the range was invalid (e.g. split surrogate).
    public func edit(_ range: NSRange, replacement: String) -> NSRange? {
        var start: UInt32 = 0, end: UInt32 = 0
        var replacement = replacement
        let applied = replacement.withUTF8 { buffer in
            lb_syntax_edit(
                handle,
                UInt32(range.location),
                UInt32(NSMaxRange(range)),
                buffer.baseAddress,
                buffer.count,
                &start,
                &end,
            )
        }
        return applied ? NSRange(location: Int(start), length: Int(end) - Int(start)) : nil
    }

    /// Nodes overlapping `window` (the whole document when nil), pre-order.
    public func nodes(in window: NSRange? = nil) -> [SyntaxNode] {
        let start = UInt32(window?.location ?? 0)
        let end = window.map { UInt32(NSMaxRange($0)) } ?? UInt32.max
        var count = 0
        guard let raw = lb_syntax_nodes_copy(handle, start, end, &count) else {
            return []
        }
        defer { lb_syntax_nodes_release(raw, count) }
        return UnsafeBufferPointer(start: raw, count: count).map(Self.node)
    }

    private static func node(_ node: LBSyntaxNode) -> SyntaxNode {
        let range = NSRange(location: Int(node.start), length: Int(node.end) - Int(node.start))
        let parent: Int? = node.parent == UInt32.max ? nil : Int(node.parent)
        return SyntaxNode(
            kind: SyntaxKind(rawValue: node.kind) ?? .other,
            range: range,
            parent: parent,
            depth: Int(node.depth),
            erroneous: node.flags & 1 != 0,
        )
    }
}
