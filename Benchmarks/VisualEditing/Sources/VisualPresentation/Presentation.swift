import CoreGraphics
import Foundation

/// A source edit the platform adapter applies as one native, undoable
/// replacement (production: LeftBlankCore.TextReplacement).
public struct SourceEdit: Equatable, Sendable {
    public let range: NSRange
    public let text: String
    /// Tab placeholders, relative to the start of `text`.
    public let placeholders: [NSRange]

    public init(range: NSRange, text: String, placeholders: [NSRange] = []) {
        self.range = range
        self.text = text
        self.placeholders = placeholders
    }
}

public enum PresentationStyle: Equatable, Sendable {
    case heading(Int)
    case strong
    case emphasis
    case code
    case link
    case ref
    case label
    case listMarker
    case math
    /// A syntax marker currently revealed because the caret touches it.
    case revealedMarker
}

public struct StyleRun: Equatable, Sendable {
    public let range: NSRange
    public let style: PresentationStyle
}

public struct ChipArgument: Equatable, Sendable {
    /// Parameter name: explicit for named arguments, from the signature for positional ones.
    public let name: String?
    public let positional: Bool
    public let valueRange: NSRange
    /// Decoded literal for strings/numbers/booleans; nil for other expressions.
    public let literal: String?
    public let isString: Bool
}

public struct Chip: Equatable, Sendable {
    public let callee: String
    public let range: NSRange
    public let arguments: [ChipArgument]
    public let label: String
    /// The call's closing parenthesis, where missing named arguments are appended.
    public let closeParen: Int
}

public enum ReplacementContent: Equatable, Sendable {
    case chip(Chip)
    case bullet
    case image(path: String)
    /// An engine-rendered fragment (math), identified by its cache key.
    case fragment(key: String, size: CGSize, baseline: CGFloat)
}

/// A source range drawn as one atomic box; the box occupies the first UTF-16
/// unit and the rest of the range is concealed.
public struct Replacement: Equatable, Sendable {
    public let range: NSRange
    public let content: ReplacementContent
}

public enum InlineRequest: Equatable, Sendable {
    case math(range: NSRange, source: String, block: Bool)
    case image(range: NSRange, path: String)

    public var range: NSRange {
        switch self {
        case let .math(range, _, _), let .image(range, _): range
        }
    }
}

public struct DisplayPlan: Equatable, Sendable {
    /// Sorted, disjoint UTF-16 ranges drawn with zero width.
    public var conceals: [NSRange] = []
    /// Sorted, disjoint atomic replacements.
    public var replacements: [Replacement] = []
    public var styles: [StyleRun] = []
    public var requests: [InlineRequest] = []
    /// Construct extents currently showing source because of the selection.
    public var revealed: [NSRange] = []
    /// Extents of every construct that conceals or replaces (sorted), so a
    /// partial re-plan knows which entries it owns.
    public var extents: [NSRange] = []
    /// Longest style/extent range: bounds the backward scan when splicing
    /// (entries are sorted by location but may nest).
    public var maxSpan = 0

    public init() {}

    public func isConcealed(_ index: Int) -> Bool {
        Self.find(index, in: conceals) != nil
    }

    public func replacement(containing index: Int) -> Replacement? {
        var low = 0, high = replacements.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(replacements[mid].range) <= index {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < replacements.count, replacements[low].range.location <= index else {
            return nil
        }
        return replacements[low]
    }

    /// Replacements intersecting `range` (binary search; layout calls this per line).
    public func replacements(in range: NSRange) -> ArraySlice<Replacement> {
        var low = 0, high = replacements.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(replacements[mid].range) <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var end = low
        while end < replacements.count, replacements[end].range.location < NSMaxRange(range) {
            end += 1
        }
        return replacements[low ..< end]
    }

    static func conceals(_ ranges: [NSRange], overlapping range: NSRange) -> ArraySlice<NSRange> {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) < range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var end = low
        while end < ranges.count, ranges[end].location <= NSMaxRange(range) {
            end += 1
        }
        return ranges[low ..< end]
    }

    static func find(_ index: Int, in ranges: [NSRange]) -> Int? {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= index {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count && ranges[low].location <= index ? low : nil
    }

    /// Rebases entries after a native edit of `range` (old coordinates) that
    /// changed the length by `delta`; entries touching the edit are dropped
    /// and re-planned by `Presentation.update`.
    public func shifted(editing range: NSRange, delta: Int) -> DisplayPlan {
        func move(_ value: NSRange) -> NSRange? {
            if NSMaxRange(value) < range.location {
                return value
            }
            if value.location > NSMaxRange(range) {
                return NSRange(location: value.location + delta, length: value.length)
            }
            return nil
        }
        var next = DisplayPlan()
        next.maxSpan = maxSpan
        next.requests = requests.compactMap { request in
            move(request.range).map { range in
                switch request {
                case let .math(_, source, block): .math(range: range, source: source, block: block)
                case let .image(_, path): .image(range: range, path: path)
                }
            }
        }
        next.conceals = conceals.compactMap(move)
        next.extents = extents.compactMap(move)
        next.revealed = revealed.compactMap(move)
        next.replacements = replacements.compactMap { replacement in
            move(replacement.range).map { Replacement(
                range: $0,
                content: replacement.content.moved(by: $0.location - replacement.range.location),
            ) }
        }
        next.styles = styles.compactMap { style in move(style.range).map { StyleRun(range: $0, style: style.style) } }
        return next
    }

    /// Character ranges whose display differs between two plans (for minimal
    /// glyph/layout invalidation).
    public func changedRanges(from old: DisplayPlan, within window: NSRange? = nil) -> [NSRange] {
        func spans(_ plan: DisplayPlan) -> Set<Pair> {
            guard let window else {
                return Set(plan.conceals.map { Pair($0, 0) } + plan.replacements
                    .map { Pair($0.range, $0.content.hashKey) })
            }
            return Set(Self.conceals(plan.conceals, overlapping: window).map { Pair($0, 0) }
                + plan.replacements(in: window).map { Pair($0.range, $0.content.hashKey) })
        }
        let before = spans(old), after = spans(self)
        return Presentation.merged(before.symmetricDifference(after).map(\.range))
    }

    struct Pair: Hashable {
        let location: Int, length: Int, content: Int
        init(_ range: NSRange, _ content: Int) {
            location = range.location
            length = range.length
            self.content = content
        }

        var range: NSRange {
            NSRange(location: location, length: length)
        }
    }
}

extension ReplacementContent {
    /// Chips carry source ranges for form edits; keep them in step with edits.
    func moved(by delta: Int) -> ReplacementContent {
        guard delta != 0, case let .chip(chip) = self else {
            return self
        }
        return .chip(Chip(
            callee: chip.callee,
            range: NSRange(location: chip.range.location + delta, length: chip.range.length),
            arguments: chip.arguments.map {
                ChipArgument(
                    name: $0.name,
                    positional: $0.positional,
                    valueRange: NSRange(location: $0.valueRange.location + delta, length: $0.valueRange.length),
                    literal: $0.literal,
                    isString: $0.isString,
                )
            },
            label: chip.label,
            closeParen: chip.closeParen + delta,
        ))
    }

    var hashKey: Int {
        switch self {
        case let .chip(chip): chip.label.hashValue ^ 1
        case .bullet: 2
        case let .image(path): path.hashValue ^ 3
        case let .fragment(key, _, _): key.hashValue ^ 4
        }
    }
}

public struct FunctionSignature: Equatable, Sendable {
    public struct Parameter: Equatable, Sendable {
        public let name: String
        public let positional: Bool
        public let defaultSource: String?
    }

    public let name: String
    public let parameters: [Parameter]

    public var positional: [Parameter] {
        parameters.filter(\.positional)
    }
}

public enum RevealPolicy: Sendable {
    /// Reveal only constructs the selection touches (Obsidian live preview).
    case construct
    /// Reveal every construct in the selection's paragraphs (LeftBlank today).
    case paragraph
}

/// Value labels for enumerated parameters, e.g. `status: done -> 已完成`.
public struct ChipFormatter: Sendable {
    public var valueLabels: [String: [String: String]]

    public init(valueLabels: [String: [String: String]] = [:]) {
        self.valueLabels = valueLabels
    }

    public func label(for callee: String, arguments: [ChipArgument]) -> String {
        var words: [String] = []
        for argument in arguments {
            guard let value = argument.literal, !value.isEmpty else {
                continue
            }
            if let name = argument.name, let labels = valueLabels[name] {
                words.append("[\(labels[value] ?? value)]")
            } else if argument.positional {
                words.append(value)
            }
        }
        return words.isEmpty ? callee : words.joined(separator: " ")
    }
}

public struct PresentationInput {
    public let source: NSString
    public let nodes: [SyntaxNode]
    public let selection: NSRange
    public var policy: RevealPolicy = .construct
    public var formatter = ChipFormatter()
    /// Functions shown as chips: signatures from `#let` (see `signatures`).
    public var signatures: [String: FunctionSignature] = [:]
    /// Engine-rendered fragments available now, keyed by equation source.
    public var fragments: [String: (size: CGSize, baseline: CGFloat)] = [:]
    public var showImages = true
    /// Nodes for a partial re-plan (see `Presentation.update`).
    public var nodesOverride: [SyntaxNode]?

    public init(source: NSString, nodes: [SyntaxNode], selection: NSRange) {
        self.source = source
        self.nodes = nodes
        self.selection = selection
    }
}

/// Pure presentation model: source + syntax nodes + selection -> display plan.
/// No AppKit/UIKit; identical on macOS and iPadOS.
public enum Presentation {
    struct Construct {
        let extent: NSRange
        var conceals: [NSRange] = []
        var replacement: Replacement?
        var styles: [StyleRun] = []
        var request: InlineRequest?
    }

    public static func plan(_ input: PresentationInput) -> DisplayPlan {
        let nodes = input.nodesOverride ?? input.nodes, source = input.source
        var children = [[Int]](repeating: [], count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent {
                children[parent].append(index)
            }
        }
        func child(_ index: Int, _ kind: SyntaxKind) -> [SyntaxNode] {
            children[index].map { nodes[$0] }.filter { $0.kind == kind }
        }
        func text(_ range: NSRange) -> String {
            source.substring(with: range)
        }
        var constructs: [Construct] = []
        for (index, node) in nodes.enumerated() where !node.erroneous {
            let range = node.range
            switch node.kind {
            case .heading:
                guard let marker = child(index, .headingMarker).first else {
                    continue
                }
                var hidden = marker.range
                if NSMaxRange(hidden) < source.length, source.character(at: NSMaxRange(hidden)) == 32 {
                    hidden.length += 1
                }
                constructs.append(Construct(
                    extent: range,
                    conceals: [hidden],
                    styles: [StyleRun(range: range, style: .heading(marker.range.length))],
                ))
            case .strong, .emph:
                let markers = child(index, node.kind == .strong ? .star : .underscore).map(\.range)
                guard markers.count == 2 else {
                    continue
                }
                constructs.append(Construct(
                    extent: range,
                    conceals: markers,
                    styles: [StyleRun(range: range, style: node.kind == .strong ? .strong : .emphasis)],
                ))
            case .raw:
                let inline = text(range).rangeOfCharacter(from: .newlines) == nil
                let hidden = inline ? child(index, .rawDelim).map(\.range) + child(index, .rawLang).map(\.range) : []
                constructs.append(Construct(
                    extent: range,
                    conceals: hidden,
                    styles: [StyleRun(range: range, style: .code)],
                ))
            case .link:
                constructs.append(Construct(extent: range, styles: [StyleRun(range: range, style: .link)]))
            case .ref:
                constructs.append(Construct(
                    extent: range,
                    // RefMarker spans `@target`; only the `@` is syntax.
                    conceals: child(index, .refMarker).map { NSRange(location: $0.range.location, length: 1) },
                    styles: [StyleRun(range: range, style: .ref)],
                ))
            case .label where range.length >= 2:
                constructs.append(Construct(
                    extent: range,
                    conceals: [NSRange(location: range.location, length: 1), NSRange(
                        location: NSMaxRange(range) - 1,
                        length: 1,
                    )],
                    styles: [StyleRun(range: range, style: .label)],
                ))
            case .listItem:
                guard let marker = child(index, .listMarker).first else {
                    continue
                }
                constructs.append(Construct(
                    extent: marker.range,
                    replacement: Replacement(range: marker.range, content: .bullet),
                    styles: [StyleRun(range: marker.range, style: .listMarker)],
                ))
            case .enumItem:
                if let marker = child(index, .enumMarker).first {
                    constructs.append(Construct(
                        extent: marker.range,
                        styles: [StyleRun(range: marker.range, style: .listMarker)],
                    ))
                }
            case .equation:
                let body = text(range)
                let block = body.count > 2 && body.dropFirst().first?.isWhitespace == true
                    && body.dropLast().last?.isWhitespace == true
                var construct = Construct(
                    extent: range,
                    styles: [StyleRun(range: range, style: .math)],
                    request: .math(range: range, source: body, block: block),
                )
                if let fragment = input.fragments[body] {
                    construct.replacement = Replacement(
                        range: range,
                        content: .fragment(key: body, size: fragment.size, baseline: fragment.baseline),
                    )
                }
                constructs.append(construct)
            case .hash:
                // `#` is a sibling of the embedded expression in markup.
                guard index + 1 < nodes.count, nodes[index + 1].kind == .funcCall,
                      nodes[index + 1].range.location == NSMaxRange(range), !nodes[index + 1].erroneous,
                      let construct = call(at: index + 1, hash: range, input: input, children: children)
                else {
                    continue
                }
                constructs.append(construct)
            default:
                continue
            }
        }
        return assemble(constructs, input: input)
    }

    private static func call(
        at index: Int,
        hash: NSRange,
        input: PresentationInput,
        children: [[Int]],
    ) -> Construct? {
        let nodes = input.nodesOverride ?? input.nodes, source = input.source
        let parts = children[index]
        guard let calleeIndex = parts.first, nodes[calleeIndex].kind == .ident,
              let argsIndex = parts.dropFirst().first, nodes[argsIndex].kind == .args
        else {
            return nil
        }
        let callee = source.substring(with: nodes[calleeIndex].range)
        let extent = NSRange(location: hash.location, length: NSMaxRange(nodes[index].range) - hash.location)
        guard let arguments = Self.arguments(argsIndex, nodes: nodes, children: children, source: source) else {
            return nil
        }
        if callee == "image", input.showImages, let path = arguments.first(where: \.positional)?.literal {
            return Construct(
                extent: extent,
                replacement: Replacement(range: extent, content: .image(path: path)),
                request: .image(range: extent, path: path),
            )
        }
        guard let signature = input.signatures[callee] else {
            return nil
        }
        // Name positional arguments from the signature so forms and labels agree.
        var position = 0
        let named = arguments.map { argument -> ChipArgument in
            guard argument.positional else {
                return argument
            }
            defer { position += 1 }
            let name = position < signature.positional.count ? signature.positional[position].name : nil
            return ChipArgument(
                name: name,
                positional: true,
                valueRange: argument.valueRange,
                literal: argument.literal,
                isString: argument.isString,
            )
        }
        let close = children[argsIndex].last.map { nodes[$0] }
        guard let close, close.kind == .rightParen else {
            return nil
        }
        let chip = Chip(
            callee: callee,
            range: extent,
            arguments: named,
            label: input.formatter.label(for: callee, arguments: named),
            closeParen: close.range.location,
        )
        return Construct(extent: extent, replacement: Replacement(range: extent, content: .chip(chip)))
    }

    /// Literal-only argument lists become chips; content blocks and arbitrary
    /// expressions keep the call as source.
    private static func arguments(
        _ args: Int,
        nodes: [SyntaxNode],
        children: [[Int]],
        source: NSString,
    ) -> [ChipArgument]? {
        var result: [ChipArgument] = []
        for index in children[args] {
            let node = nodes[index]
            switch node.kind {
            case .leftParen, .rightParen, .comma, .lineComment, .blockComment:
                continue
            case .named:
                let parts = children[index].map { nodes[$0] }
                guard let name = parts.first, name.kind == .ident, let value = parts.last,
                      let literal = literal(value, source: source)
                else {
                    return nil
                }
                result.append(ChipArgument(
                    name: source.substring(with: name.range),
                    positional: false,
                    valueRange: value.range,
                    literal: literal,
                    isString: value.kind == .str,
                ))
            default:
                guard let literal = literal(node, source: source) else {
                    return nil
                }
                result.append(ChipArgument(
                    name: nil,
                    positional: true,
                    valueRange: node.range,
                    literal: literal,
                    isString: node.kind == .str,
                ))
            }
        }
        return result
    }

    static func literal(_ node: SyntaxNode, source: NSString) -> String? {
        let raw = source.substring(with: node.range)
        switch node.kind {
        case .str: return decodeString(raw)
        case .int, .float, .numeric, .bool, .noneLiteral, .auto: return raw
        default: return nil
        }
    }

    static func decodeString(_ raw: String) -> String {
        var result = "", escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    public static func encodeString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func assemble(_ constructs: [Construct], input: PresentationInput) -> DisplayPlan {
        let selection = input.selection
        let paragraphs: NSRange? = input.policy == .paragraph
            ? input.source.paragraphRange(for: NSRange(
                location: min(selection.location, input.source.length),
                length: min(selection.length, input.source.length - min(selection.location, input.source.length)),
            ))
            : nil
        func revealed(_ extent: NSRange) -> Bool {
            if let paragraphs {
                return NSIntersectionRange(paragraphs, extent).length > 0 || extent.location == paragraphs.location
            }
            // Touching either edge counts: the caret right after `*bold*` reveals it.
            return selection.location <= NSMaxRange(extent) && NSMaxRange(selection) >= extent.location
        }
        var plan = DisplayPlan()
        var conceals: [NSRange] = []
        var replacements: [Replacement] = []
        for construct in constructs {
            if !construct.conceals.isEmpty || construct.replacement != nil {
                plan.extents.append(construct.extent)
            }
            plan.styles += construct.styles
            if let request = construct.request {
                plan.requests.append(request)
            }
            if revealed(construct.extent) {
                if !construct.conceals.isEmpty || construct.replacement != nil {
                    plan.revealed.append(construct.extent)
                }
                plan.styles += construct.conceals.map { StyleRun(range: $0, style: .revealedMarker) }
                continue
            }
            conceals += construct.conceals
            if let replacement = construct.replacement {
                replacements.append(replacement)
            }
        }
        // Outer replacements win over anything nested inside them.
        replacements.sort { $0.range.location < $1.range.location }
        for replacement in replacements {
            if let last = plan.replacements.last, NSMaxRange(last.range) > replacement.range.location {
                continue
            }
            plan.replacements.append(replacement)
        }
        plan.styles.sort { $0.range.location < $1.range.location }
        plan.maxSpan = max(plan.styles.map(\.range.length).max() ?? 0, constructs.map(\.extent.length).max() ?? 0)
        plan.requests.sort { $0.range.location < $1.range.location }
        plan.extents.sort { $0.location < $1.location }
        plan.conceals = merged(conceals.filter { range in
            plan.replacement(containing: range.location).map {
                NSIntersectionRange($0.range, range).length != range.length
            } ?? true
        })
        return plan
    }

    /// Re-plans only `window` (expanded to paragraphs and to every construct
    /// overlapping it) and splices the result into `plan`. Reveal changes and
    /// edits are local, so this keeps selection/typing cost independent of
    /// document size. `nodes(range)` fetches syntax nodes for a range.
    public static func update(
        _ plan: DisplayPlan,
        window: NSRange,
        input: PresentationInput,
        nodes: (NSRange) -> [SyntaxNode],
    ) -> (plan: DisplayPlan, affected: NSRange) {
        let source = input.source
        func paragraphs(_ range: NSRange) -> NSRange {
            let location = min(max(0, range.location), source.length)
            let length = min(max(0, range.length), source.length - location)
            return source.paragraphRange(for: NSRange(location: location, length: length))
        }
        var affected = paragraphs(window)
        var partial = DisplayPlan()
        // Grow until no construct crosses the window edge. Converges quickly
        // (constructs rarely span paragraphs); the cap is a safety net.
        for iteration in 0 ..< 64 {
            var local = input
            local.nodesOverride = nodes(iteration == 63 ? NSRange(location: 0, length: source.length) : affected)
            if iteration == 63 {
                affected = NSRange(location: 0, length: source.length)
            }
            partial = Presentation.plan(local)
            var grown = affected
            for extent in partial.extents {
                grown = NSUnionRange(grown, extent)
            }
            for extent in plan.extents[candidates(plan.extents, affected, \.self, plan.maxSpan)]
                where NSIntersectionRange(extent, grown).length > 0 || NSLocationInRange(extent.location, grown)
            {
                grown = NSUnionRange(grown, extent)
            }
            grown = paragraphs(grown)
            if grown == affected {
                break
            }
            affected = grown
        }
        // Every array is sorted by location (entries may nest): rebuild only
        // the candidate slice, so the cost is independent of document size.
        func inside(_ range: NSRange) -> Bool {
            NSIntersectionRange(range, affected).length > 0 || NSLocationInRange(range.location, affected)
        }
        func splice<T>(_ items: [T], _ fresh: [T], _ key: KeyPath<T, NSRange>) -> [T] {
            let slice = candidates(items, affected, key, plan.maxSpan)
            let middle = (items[slice].filter { !inside($0[keyPath: key]) } + fresh.filter { inside($0[keyPath: key]) })
                .sorted { $0[keyPath: key].location < $1[keyPath: key].location }
            var result = items
            result.replaceSubrange(slice, with: middle)
            return result
        }
        var next = plan
        next.conceals = mergedSorted(splice(plan.conceals, partial.conceals, \.self))
        next.replacements = splice(plan.replacements, partial.replacements, \.range)
        next.extents = splice(plan.extents, partial.extents, \.self)
        next.styles = splice(plan.styles, partial.styles, \.range)
        next.requests = splice(plan.requests, partial.requests, \.range)
        next.revealed = splice(plan.revealed, partial.revealed, \.self)
        next.maxSpan = max(plan.maxSpan, partial.maxSpan)
        return (next, affected)
    }

    /// Index range that contains every entry (sorted by location, at most
    /// `maxSpan` long) that may intersect or start in `window`.
    static func candidates<T>(
        _ items: [T],
        _ window: NSRange,
        _ key: KeyPath<T, NSRange>,
        _ maxSpan: Int,
    ) -> Range<Int> {
        func first(_ predicate: (NSRange) -> Bool) -> Int {
            var low = 0, high = items.count
            while low < high {
                let mid = (low + high) / 2
                if predicate(items[mid][keyPath: key]) {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            return low
        }
        let low = first { $0.location >= window.location - maxSpan }
        let high = first { $0.location > NSMaxRange(window) }
        return low ..< max(low, high)
    }

    /// Merges touching neighbours of an already sorted array in one pass.
    static func mergedSorted(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        result.reserveCapacity(ranges.count)
        for range in ranges where range.length > 0 {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `#let name(a, b, c: default) = ...` closures in the document.
    public static func signatures(nodes: [SyntaxNode], source: NSString) -> [String: FunctionSignature] {
        var children = [[Int]](repeating: [], count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent {
                children[parent].append(index)
            }
        }
        var result: [String: FunctionSignature] = [:]
        for (index, node) in nodes.enumerated() where node.kind == .letBinding {
            guard let closure = children[index].first(where: { nodes[$0].kind == .closure }),
                  let name = children[closure].first.map({ nodes[$0] }), name.kind == .ident,
                  let params = children[closure].first(where: { nodes[$0].kind == .params })
            else {
                continue
            }
            var parameters: [FunctionSignature.Parameter] = []
            for param in children[params] {
                let node = nodes[param]
                if node.kind == .ident {
                    parameters.append(.init(
                        name: source.substring(with: node.range),
                        positional: true,
                        defaultSource: nil,
                    ))
                } else if node.kind == .named, let ident = children[param].first.map({ nodes[$0] }),
                          let value = children[param].last.map({ nodes[$0] })
                {
                    parameters.append(.init(
                        name: source.substring(with: ident.range),
                        positional: false,
                        defaultSource: source.substring(with: value.range),
                    ))
                }
            }
            let signature = FunctionSignature(name: source.substring(with: name.range), parameters: parameters)
            result[signature.name] = signature
        }
        return result
    }
}

/// Form edits and insertion helpers that write back to source.
public enum ChipEditing {
    /// One replacement covering every changed argument; unchanged source
    /// between them (spacing, comments) is preserved verbatim.
    public static func edit(_ chip: Chip, values: [String: String], source: NSString) -> SourceEdit? {
        var changes: [(NSRange, String)] = []
        var appended: [String] = []
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            if let argument = chip.arguments.first(where: { $0.name == name }) {
                guard argument.literal != value else {
                    continue
                }
                changes.append((
                    argument.valueRange,
                    argument.isString || argument.literal == nil
                        ? Presentation.encodeString(value) : value,
                ))
            } else {
                appended.append("\(name): \(Presentation.encodeString(value))")
            }
        }
        if !appended.isEmpty {
            let prefix = chip.arguments.isEmpty ? "" : ", "
            changes.append((NSRange(location: chip.closeParen, length: 0), prefix + appended.joined(separator: ", ")))
        }
        guard !changes.isEmpty else {
            return nil
        }
        changes.sort { $0.0.location < $1.0.location }
        let start = changes[0].0.location
        let end = changes.map { NSMaxRange($0.0) }.max() ?? start
        var text = "", cursor = start
        for (range, replacement) in changes {
            text += source.substring(with: NSRange(location: cursor, length: range.location - cursor)) + replacement
            cursor = NSMaxRange(range)
        }
        return SourceEdit(range: NSRange(location: start, length: end - start), text: text)
    }

    /// "Repeat previous call": copy the nearest earlier chip's call, keeping
    /// enumerated values and blanking free text into Tab placeholders.
    public static func repeatPrevious(
        before location: Int,
        chips: [Chip],
        formatter: ChipFormatter,
    ) -> SourceEdit? {
        guard let previous = chips.last(where: { NSMaxRange($0.range) <= location }) else {
            return nil
        }
        var text = "#\(previous.callee)("
        var placeholders: [NSRange] = []
        for (index, argument) in previous.arguments.enumerated() {
            if index > 0 {
                text += ", "
            }
            if !argument.positional, let name = argument.name {
                text += "\(name): "
            }
            if let name = argument.name, formatter.valueLabels[name] != nil, let value = argument.literal {
                text += Presentation.encodeString(value)
            } else if argument.isString {
                placeholders.append(NSRange(location: (text as NSString).length + 1, length: 0))
                text += "\"\""
            } else {
                text += argument.literal ?? ""
            }
        }
        text += ")"
        return SourceEdit(range: NSRange(location: location, length: 0), text: text, placeholders: placeholders)
    }
}
