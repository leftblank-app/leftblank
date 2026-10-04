import Foundation

/// Tracks UTF-16 placeholder ranges while the user edits one placeholder.
public struct SnippetNavigation: Sendable {
    public private(set) var ranges: [NSRange]
    public private(set) var index = 0

    public init(_ snippet: Snippet, at offset: Int) {
        ranges = snippet.selections.map { NSRange(location: offset + $0.location, length: $0.length) }
    }

    public var current: NSRange? {
        ranges.indices.contains(index) ? ranges[index] : nil
    }

    public mutating func edit(_ range: NSRange, replacement: String) {
        guard let current, range.location >= current.location, NSMaxRange(range) <= NSMaxRange(current) else {
            ranges = []
            return
        }
        let delta = replacement.utf16.count - range.length
        ranges[index].length += delta
        for next in ranges.indices where next > index {
            ranges[next].location += delta
        }
    }

    public mutating func move(backward: Bool) -> NSRange? {
        guard let last = ranges.last else {
            return nil
        }
        let end = NSMaxRange(last)
        index += backward ? -1 : 1
        if let current {
            return current
        }
        ranges = []
        return NSRange(location: end, length: 0)
    }
}
