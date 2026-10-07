import Foundation

/// The display plan of one editor buffer, kept current across edits and
/// selection changes without re-planning the whole document.
///
/// The plan is stored in blocks: consecutive source ranges of whole
/// paragraphs, each holding entries relative to its own start. No construct
/// or `#let` definition crosses a block boundary. An edit therefore rebases
/// later blocks by moving one start offset each, and re-plans only the blocks
/// that the edit, the reparsed range or the selection touch. Not thread-safe:
/// use one serial owner, the same one that owns the `SyntaxTree`.
public struct PresentationStore {
    struct Block: Equatable {
        var start: Int
        var length: Int
        /// Entries relative to `start`.
        var plan: DisplayPlan
        /// Definitions whose binding starts in this block, relative to `start`.
        var definitions: [FunctionDefinitions.Definition]

        var range: NSRange {
            NSRange(location: start, length: length)
        }
    }

    /// Blocks grow to at least this many UTF-16 units before a paragraph boundary ends them.
    static let blockLength = 2048

    private(set) var blocks: [Block] = []
    public private(set) var selection: NSRange
    public private(set) var options: PresentationOptions
    /// The document's `#let` function definitions, which name chip arguments.
    public private(set) var definitions = FunctionDefinitions()

    /// Plans the whole document. `tree` must mirror `source`.
    public init(
        source: NSString,
        tree: SyntaxTree,
        selection: NSRange,
        options: PresentationOptions = PresentationOptions(),
    ) {
        self.selection = selection
        self.options = options
        rebuild(source: source, tree: tree)
    }

    /// UTF-16 length of the planned source.
    public var length: Int {
        blocks.last.map { NSMaxRange($0.range) } ?? 0
    }

    /// The whole plan, with absolute ranges.
    public var plan: DisplayPlan {
        plan(in: NSRange(location: 0, length: length))
    }

    /// Entries that intersect or touch `range`, with absolute ranges, for
    /// example for one paragraph the text system is laying out.
    public func plan(in range: NSRange) -> DisplayPlan {
        var result = DisplayPlan()
        var index = Presentation.firstIndex(blocks) { NSMaxRange($0.range) >= range.location }
        while index < blocks.count, blocks[index].start <= NSMaxRange(range) {
            result.append(blocks[index].plan.offset(by: blocks[index].start))
            index += 1
        }
        return result.restricted(to: range)
    }

    /// Re-plans everything, for example after the options change.
    public mutating func setOptions(_ options: PresentationOptions, source: NSString, tree: SyntaxTree) {
        self.options = options
        rebuild(source: source, tree: tree)
    }

    /// Mirrors one native replacement of `range` (old coordinates) by text of
    /// `replacementLength` UTF-16 units. `reparsed` is the range `tree.edit`
    /// returned for the same edit; `tree` and `source` already contain it. The
    /// selection is rebased as the text system does; call `select` afterwards
    /// if it lands elsewhere. Returns the ranges whose display was re-planned,
    /// in new coordinates.
    @discardableResult
    public mutating func edit(
        _ range: NSRange,
        replacementLength: Int,
        reparsed: NSRange,
        source: NSString,
        tree: SyntaxTree,
    ) -> [NSRange] {
        let delta = replacementLength - range.length
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= length,
              length + delta == source.length
        else {
            // Not the edit this store last saw: plan from scratch.
            selection = NSRange(location: min(selection.location, source.length), length: 0)
            rebuild(source: source, tree: tree)
            return [NSRange(location: 0, length: source.length)]
        }
        let touched = selection.location <= NSMaxRange(range) && NSMaxRange(selection) >= range.location
        selection = Self.rebase(selection, editing: range, delta: delta)
        // Merge the blocks the edit touches into one block to re-plan; later blocks move.
        let first = min(Presentation.firstIndex(blocks) { NSMaxRange($0.range) >= range.location }, blocks.count - 1)
        var last = first
        while last + 1 < blocks.count, blocks[last + 1].start <= NSMaxRange(range) {
            last += 1
        }
        let start = blocks[first].start
        let end = NSMaxRange(blocks[last].range) + delta
        blocks.replaceSubrange(
            first ... last,
            with: [Block(start: start, length: end - start, plan: DisplayPlan(), definitions: [])],
        )
        for index in blocks.indices.dropFirst(first + 1) {
            blocks[index].start += delta
        }
        let edited = NSRange(location: range.location, length: replacementLength)
        let affected = update(NSUnionRange(edited, reparsed), source: source, tree: tree)
        guard touched, selection.location < affected.location || NSMaxRange(selection) > NSMaxRange(affected) else {
            return [affected]
        }
        // The edit moved the selection relative to constructs outside the re-planned range.
        return [affected, update(selection, source: source, tree: tree)]
    }

    /// Moves the selection and re-plans the constructs whose reveal state may
    /// change. Returns the ranges whose display was re-planned.
    @discardableResult
    public mutating func select(_ selection: NSRange, source: NSString, tree: SyntaxTree) -> [NSRange] {
        let old = self.selection
        self.selection = selection
        guard old != selection else {
            return []
        }
        return [update(old, source: source, tree: tree), update(selection, source: source, tree: tree)]
    }

    /// The selection after a replacement, as `NSTextView` and `UITextView` adjust it.
    static func rebase(_ selection: NSRange, editing range: NSRange, delta: Int) -> NSRange {
        let end = NSMaxRange(range), replaced = range.location + range.length + delta
        func move(_ location: Int) -> Int {
            location >= end ? location + delta : min(location, replaced)
        }
        let start = move(selection.location)
        return NSRange(location: start, length: max(0, move(NSMaxRange(selection)) - start))
    }

    // MARK: - Planning

    private mutating func rebuild(source: NSString, tree: SyntaxTree) {
        let whole = NSRange(location: 0, length: source.length)
        let nodes = tree.nodes() ?? []
        definitions = FunctionDefinitions(source: source, nodes: nodes)
        let plan = Presentation.plan(
            source: source,
            nodes: nodes,
            selection: selection,
            definitions: definitions,
            options: options,
        )
        blocks = Self.blocks(covering: whole, plan: plan, definitions: definitions.definitions, source: source)
    }

    /// Re-plans the blocks around `window` and returns the re-planned range.
    private mutating func update(_ window: NSRange, source: NSString, tree: SyntaxTree) -> NSRange {
        var span = blockSpan(Presentation.paragraphRange(window, in: source))
        var affected = NSRange()
        var nodes: [SyntaxNode] = []
        var plan = DisplayPlan()
        var local: [FunctionDefinitions.Definition] = []
        // Grow until no construct crosses the edge. Constructs rarely span
        // paragraphs, so this converges in one or two rounds.
        while true {
            let start = blocks[span.lowerBound].start
            affected = NSRange(location: start, length: NSMaxRange(blocks[span.upperBound - 1].range) - start)
            nodes = tree.nodes(in: affected) ?? []
            // Definitions outside the window keep their stored places; the
            // window's own come from its fresh nodes.
            local = Presentation.definitions(source: source, nodes: nodes)
            let visible = absoluteDefinitions(blocks[..<span.lowerBound]) + local
                + absoluteDefinitions(blocks[span.upperBound...])
            plan = Presentation.plan(
                source: source,
                nodes: nodes,
                selection: selection,
                definitions: FunctionDefinitions(visible),
                options: options,
            )
            let grown = plan.extents.reduce(affected) { NSUnionRange($0, $1) }
            let next = blockSpan(grown)
            if next == span {
                break
            }
            span = next
        }
        blocks.replaceSubrange(
            span,
            with: Self.blocks(covering: affected, plan: plan, definitions: local, source: source),
        )
        let updated = FunctionDefinitions(absoluteDefinitions(blocks[...]))
        guard updated.signatures == definitions.signatures else {
            // A definition was added, removed or changed, so calls elsewhere may change.
            rebuild(source: source, tree: tree)
            return NSRange(location: 0, length: source.length)
        }
        definitions = updated
        return affected
    }

    private func absoluteDefinitions(_ blocks: ArraySlice<Block>) -> [FunctionDefinitions.Definition] {
        blocks.flatMap { block in
            block.definitions.map { .init(location: $0.location + block.start, signature: $0.signature) }
        }
    }

    /// Indices of the blocks that `range` intersects, or of the block holding an empty range.
    private func blockSpan(_ range: NSRange) -> Range<Int> {
        let first = min(Presentation.firstIndex(blocks) { NSMaxRange($0.range) > range.location }, blocks.count - 1)
        var last = first
        while last + 1 < blocks.count, blocks[last + 1].start < NSMaxRange(range) {
            last += 1
        }
        return first ..< last + 1
    }

    /// Splits `range` into blocks at paragraph starts that no construct crosses.
    static func blocks(
        covering range: NSRange,
        plan: DisplayPlan,
        definitions: [FunctionDefinitions.Definition],
        source: NSString,
    ) -> [Block] {
        var bounds = [range.location]
        var extent = 0, covered = range.location, cursor = range.location
        while cursor < NSMaxRange(range) {
            cursor = max(NSMaxRange(source.paragraphRange(for: NSRange(location: cursor, length: 0))), cursor + 1)
            guard cursor < NSMaxRange(range), let last = bounds.last, cursor - last >= blockLength else {
                continue
            }
            // The furthest end of any construct that starts before the candidate cut.
            while extent < plan.extents.count, plan.extents[extent].location < cursor {
                covered = max(covered, NSMaxRange(plan.extents[extent]))
                extent += 1
            }
            if covered <= cursor {
                bounds.append(cursor)
            }
        }
        bounds.append(NSMaxRange(range))
        let count = bounds.count - 1
        // Every array is sorted by location, so one pass assigns each entry to its block.
        func split<T>(_ items: [T], _ location: (T) -> Int) -> [[T]] {
            var result = [[T]](repeating: [], count: count)
            var block = 0
            for item in items {
                while block + 1 < count, location(item) >= bounds[block + 1] {
                    block += 1
                }
                result[block].append(item)
            }
            return result
        }
        let conceals = split(plan.conceals, \.location)
        let replacements = split(plan.replacements, \.range.location)
        let styles = split(plan.styles, \.range.location)
        let requests = split(plan.requests, \.range.location)
        let revealed = split(plan.revealed, \.location)
        let extents = split(plan.extents, \.location)
        let definitions = split(definitions, \.location)
        return (0 ..< count).map { index in
            var local = DisplayPlan()
            local.conceals = conceals[index]
            local.replacements = replacements[index]
            local.styles = styles[index]
            local.requests = requests[index]
            local.revealed = revealed[index]
            local.extents = extents[index]
            return Block(
                start: bounds[index],
                length: bounds[index + 1] - bounds[index],
                plan: local.offset(by: -bounds[index]),
                definitions: definitions[index].map {
                    .init(location: $0.location - bounds[index], signature: $0.signature)
                },
            )
        }
    }
}

public extension PresentationStore {
    /// The plan as an immutable value another thread can read.
    var snapshot: PresentationSnapshot {
        PresentationSnapshot(blocks: blocks.map { .init(start: $0.start, length: $0.length, plan: $0.plan) })
    }
}

/// A store's plan, read by the text system on the main thread while the store
/// itself lives on a background actor. Between a native edit and the store's
/// reply, `edit` rebases it: later entries move, and entries the edit touches
/// are dropped, so that text shows as source until it is planned again.
public struct PresentationSnapshot: Equatable, Sendable {
    struct Block: Equatable, Sendable {
        var start: Int
        var length: Int
        /// Entries relative to `start`.
        var plan: DisplayPlan

        var range: NSRange {
            NSRange(location: start, length: length)
        }
    }

    var blocks: [Block]

    /// A plan of plain source for text of `length` UTF-16 units.
    public init(length: Int = 0) {
        blocks = [Block(start: 0, length: length, plan: DisplayPlan())]
    }

    init(blocks: [Block]) {
        self.blocks = blocks.isEmpty ? [Block(start: 0, length: 0, plan: DisplayPlan())] : blocks
    }

    public var length: Int {
        blocks.last.map { NSMaxRange($0.range) } ?? 0
    }

    /// Entries that intersect or touch `range`, with absolute ranges.
    public func plan(in range: NSRange) -> DisplayPlan {
        var result = DisplayPlan()
        var index = Presentation.firstIndex(blocks) { NSMaxRange($0.range) >= range.location }
        while index < blocks.count, blocks[index].start <= NSMaxRange(range) {
            result.append(blocks[index].plan.offset(by: blocks[index].start))
            index += 1
        }
        return result.restricted(to: range)
    }

    /// Mirrors one native replacement of `range` (old coordinates) by text of
    /// `replacementLength` UTF-16 units.
    public mutating func edit(_ range: NSRange, replacementLength: Int) {
        let delta = replacementLength - range.length
        guard range.location >= 0, NSMaxRange(range) <= length else {
            self = PresentationSnapshot(length: max(0, length + delta))
            return
        }
        let first = min(Presentation.firstIndex(blocks) { NSMaxRange($0.range) >= range.location }, blocks.count - 1)
        var last = first
        while last + 1 < blocks.count, blocks[last + 1].start <= NSMaxRange(range) {
            last += 1
        }
        let start = blocks[first].start
        var plan = DisplayPlan()
        for block in blocks[first ... last] {
            plan.append(block.plan.offset(by: block.start - start))
        }
        let local = NSRange(location: range.location - start, length: range.length)
        let merged = Block(
            start: start,
            length: NSMaxRange(blocks[last].range) - start + delta,
            plan: plan.rebased(editing: local, delta: delta),
        )
        blocks.replaceSubrange(first ... last, with: [merged])
        for index in blocks.indices.dropFirst(first + 1) {
            blocks[index].start += delta
        }
    }

    /// Source ranges whose display differs between `old` and this snapshot,
    /// both describing the same text.
    public func changedRanges(from old: PresentationSnapshot) -> [NSRange] {
        var previous: [Int: Block] = [:]
        for block in old.blocks {
            previous[block.start] = block
        }
        var changed: [NSRange] = []
        for block in blocks {
            guard let before = previous[block.start], before.length == block.length else {
                changed.append(block.range)
                continue
            }
            guard before.plan != block.plan else {
                continue
            }
            changed += block.plan.differences(from: before.plan).map { $0.offset(by: block.start) }
        }
        return Presentation.merged(changed)
    }
}

extension DisplayPlan {
    /// The plan after replacing `range` by `range.length + delta` units.
    func rebased(editing range: NSRange, delta: Int) -> DisplayPlan {
        func keep(_ value: NSRange) -> NSRange? {
            if NSMaxRange(value) <= range.location {
                return value
            }
            return value.location >= NSMaxRange(range) ? value.offset(by: delta) : nil
        }
        var plan = DisplayPlan()
        plan.conceals = conceals.compactMap(keep)
        plan.replacements = replacements.compactMap { replacement in
            keep(replacement.range).map { replacement.offset(by: $0.location - replacement.range.location) }
        }
        plan.styles = styles.compactMap { run in keep(run.range).map { StyleRun(range: $0, style: run.style) } }
        plan.requests = requests.compactMap { request in
            keep(request.range).map { request.offset(by: $0.location - request.range.location) }
        }
        plan.revealed = revealed.compactMap(keep)
        plan.extents = extents.compactMap(keep)
        return plan
    }

    /// Ranges of the entries that affect drawing and differ from `old`.
    func differences(from old: DisplayPlan) -> [NSRange] {
        Self.differences(conceals, old.conceals) { $0 }
            + Self.differences(replacements, old.replacements, \.range)
            + Self.differences(styles, old.styles, \.range)
            + Self.differences(requests, old.requests, \.range)
    }

    /// Entries present in only one of two location-sorted lists.
    static func differences<T: Equatable>(_ lhs: [T], _ rhs: [T], _ range: (T) -> NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var left = 0, right = 0
        while left < lhs.count || right < rhs.count {
            let leftLocation = left < lhs.count ? range(lhs[left]).location : Int.max
            let rightLocation = right < rhs.count ? range(rhs[right]).location : Int.max
            let location = min(leftLocation, rightLocation)
            var leftGroup: [T] = [], rightGroup: [T] = []
            while left < lhs.count, range(lhs[left]).location == location {
                leftGroup.append(lhs[left])
                left += 1
            }
            while right < rhs.count, range(rhs[right]).location == location {
                rightGroup.append(rhs[right])
                right += 1
            }
            result += leftGroup.filter { !rightGroup.contains($0) }.map(range)
            result += rightGroup.filter { !leftGroup.contains($0) }.map(range)
        }
        return result
    }
}
