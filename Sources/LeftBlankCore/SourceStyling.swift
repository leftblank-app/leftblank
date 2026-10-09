import Foundation

/// The reading style of a run of source: headings are larger and bold, strong
/// text is bold, emphasis italic and raw text monospaced. The editor applies it
/// as fonts on the source text itself; every marker stays visible.
public struct SourceStyle: Hashable, Sendable {
    /// Heading level, or 0 outside headings.
    public var heading = 0
    public var strong = false
    public var emphasis = false
    public var raw = false

    public init(heading: Int = 0, strong: Bool = false, emphasis: Bool = false, raw: Bool = false) {
        self.heading = heading
        self.strong = strong
        self.emphasis = emphasis
        self.raw = raw
    }

    public static let plain = SourceStyle()
}

/// One construct that changes the style of its whole range. Runs may nest.
public struct SourceStyleRun: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case strong
        case emphasis
        case raw
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

public enum SourceStyling {
    /// Heading, strong, emphasis and raw constructs among `nodes`, which may be
    /// a window of the document's nodes (`SyntaxTree.nodes(in:)`). Erroneous
    /// constructs stay plain.
    public static func runs(_ nodes: [SyntaxNode]) -> [SourceStyleRun] {
        var runs: [SourceStyleRun] = []
        for (index, node) in nodes.enumerated() where !node.isErroneous {
            switch node.kind {
            case .heading:
                // The marker is the heading's first child, listed right after it.
                let marker = index + 1 < nodes.count && nodes[index + 1].kind == .headingMarker
                    ? nodes[index + 1].range.length : 1
                runs.append(SourceStyleRun(range: node.range, kind: .heading(level: marker)))
            case .strong:
                runs.append(SourceStyleRun(range: node.range, kind: .strong))
            case .emph:
                runs.append(SourceStyleRun(range: node.range, kind: .emphasis))
            case .raw:
                runs.append(SourceStyleRun(range: node.range, kind: .raw))
            default:
                continue
            }
        }
        return runs
    }

    /// The styles of `range`, as consecutive segments that cover it.
    public static func segments(_ runs: [SourceStyleRun], in range: NSRange) -> [(range: NSRange, style: SourceStyle)] {
        var events: [(location: Int, run: SourceStyleRun.Kind, opens: Bool)] = []
        for run in runs {
            let clipped = NSIntersectionRange(run.range, range)
            if clipped.length > 0 {
                events.append((clipped.location, run.kind, true))
                events.append((NSMaxRange(clipped), run.kind, false))
            }
        }
        // Closings first at a shared location, so adjacent runs do not overlap.
        events.sort { ($0.location, $0.opens ? 1 : 0) < ($1.location, $1.opens ? 1 : 0) }
        var segments: [(range: NSRange, style: SourceStyle)] = []
        var headings: [Int] = [], strong = 0, emphasis = 0, raw = 0
        var cursor = range.location
        func style() -> SourceStyle {
            SourceStyle(heading: headings.last ?? 0, strong: strong > 0, emphasis: emphasis > 0, raw: raw > 0)
        }
        func emit(until location: Int) {
            guard location > cursor else {
                return
            }
            let current = style()
            if let last = segments.last, last.style == current, NSMaxRange(last.range) == cursor {
                segments[segments.count - 1].range.length += location - cursor
            } else {
                segments.append((NSRange(location: cursor, length: location - cursor), current))
            }
            cursor = location
        }
        for event in events {
            emit(until: event.location)
            let step = event.opens ? 1 : -1
            switch event.run {
            case let .heading(level):
                if event.opens {
                    headings.append(level)
                } else if let index = headings.lastIndex(of: level) {
                    headings.remove(at: index)
                }
            case .strong: strong += step
            case .emphasis: emphasis += step
            case .raw: raw += step
            }
        }
        emit(until: NSMaxRange(range))
        return segments
    }

    /// Where `range` (or a location in it) lands after a native replacement of
    /// `edit` (old coordinates) that changed the length by `delta`: text after
    /// the edit moves, and text inside it ends where the replacement ends.
    public static func rebase(_ range: NSRange, editing edit: NSRange, delta: Int) -> NSRange {
        let end = NSMaxRange(edit), replaced = NSMaxRange(edit) + delta
        func move(_ location: Int) -> Int {
            location >= end ? location + delta : min(location, replaced)
        }
        let start = move(range.location)
        return NSRange(location: start, length: max(0, move(NSMaxRange(range)) - start))
    }
}

/// Parses one buffer off the main thread and reports the styles of the text
/// each batch of edits reparsed.
///
/// Parsing can take far longer than a keystroke: an unclosed `$` in the middle
/// of a book reparses to its end (about 0.1 s locally, 0.4 s on CI). The text
/// view therefore never waits for this actor; its text keeps the fonts it had,
/// which move with every edit, until the reply arrives.
public actor SourceStyleEngine {
    public struct Edit: Sendable, Equatable {
        /// The replaced range, in the text before this edit.
        public let range: NSRange
        public let text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// The styles of whole paragraphs, `region`, of the text after the edits.
    public struct Reply: Sendable {
        public let region: NSRange
        public let runs: [SourceStyleRun]
    }

    private let source = NSMutableString()
    private var tree: SyntaxTree?

    public init() {}

    public func open(_ text: String) {
        source.setString(text)
        tree = SyntaxTree(text)
    }

    /// Applies native edits in order.
    public func update(_ edits: [Edit]) -> Reply {
        var region: NSRange?
        for edit in edits {
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= source.length else {
                source.setString(edit.text)
                tree = nil
                continue
            }
            source.replaceCharacters(in: edit.range, with: edit.text)
            let delta = (edit.text as NSString).length - edit.range.length
            let reparsed = tree?.edit(edit.range, replacement: edit.text)
            if reparsed == nil {
                tree = nil
            }
            let changed = reparsed ?? NSRange(location: edit.range.location, length: edit.range.length + delta)
            region = region.map { NSUnionRange(SourceStyling.rebase($0, editing: edit.range, delta: delta), changed) }
                ?? changed
        }
        var whole = false
        if tree == nil {
            // A failed edit leaves the tree out of step: parse again.
            tree = SyntaxTree(source as String)
            whole = true
        }
        let changed = whole ? NSRange(location: 0, length: source.length) : region ?? NSRange()
        let location = min(changed.location, source.length)
        let paragraphs = source.paragraphRange(for: NSRange(
            location: location,
            length: min(changed.length, source.length - location),
        ))
        return Reply(region: paragraphs, runs: SourceStyling.runs(tree?.nodes(in: paragraphs) ?? []))
    }
}
