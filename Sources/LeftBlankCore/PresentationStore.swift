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
