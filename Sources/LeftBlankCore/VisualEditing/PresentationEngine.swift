import Foundation

/// Owns one buffer's syntax tree and display plan off the main thread.
///
/// Parsing can take far longer than a keystroke: an unclosed `$` in the middle
/// of a book reparses to its end (about 0.1 s locally, 0.4 s on CI). The text
/// view therefore never waits for this actor. It sends batches of native edits
/// with the selection, and draws a rebased `PresentationSnapshot` until the
/// reply for its current revision arrives.
public actor PresentationEngine {
    public struct Edit: Sendable, Equatable {
        /// The replaced range, in the text before this edit.
        public let range: NSRange
        public let text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    public struct Reply: Sendable {
        public let snapshot: PresentationSnapshot
        public let definitions: FunctionDefinitions
        public let formatter: ChipFormatter
        /// The document's rules for equations (`MathPreamble.extract`).
        public let preamble: String
    }

    private let source = NSMutableString()
    private var tree: SyntaxTree?
    private var store: PresentationStore?
    private var options = PresentationOptions()
    /// Top-level `#let`, `#set`, `#show` and `#import` statements; editing
    /// one may change chip value labels or how equations render.
    private var bindings: [NSRange] = []
    private var preamble = ""

    public init() {}

    /// Plans `text` from scratch.
    public func open(_ text: String, selection: NSRange, options: PresentationOptions) -> Reply {
        source.setString(text)
        self.options = options
        rebuild(selection: selection)
        return reply()
    }

    /// Applies native edits in order, then the selection the view has now.
    public func update(_ edits: [Edit], selection: NSRange, options: PresentationOptions? = nil) -> Reply {
        var labelsChanged = false
        for edit in edits {
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= source.length else {
                source.replaceCharacters(in: NSRange(location: 0, length: source.length), with: edit.text)
                rebuild(selection: selection)
                continue
            }
            source.replaceCharacters(in: edit.range, with: edit.text)
            let length = (edit.text as NSString).length
            labelsChanged = labelsChanged || bindings.contains { NSIntersectionRange($0, edit.range).length > 0
                || NSLocationInRange(edit.range.location, $0)
            }
            bindings = bindings.compactMap { binding in
                if NSMaxRange(binding) <= edit.range.location {
                    return binding
                }
                return binding.location >= NSMaxRange(edit.range)
                    ? binding.offset(by: length - edit.range.length) : nil
            }
            guard let tree, var store, let reparsed = tree.edit(edit.range, replacement: edit.text) else {
                rebuild(selection: selection)
                continue
            }
            store.edit(edit.range, replacementLength: length, reparsed: reparsed, source: source, tree: tree)
            labelsChanged = labelsChanged || tree.nodes(in: reparsed)?.contains {
                [.letBinding, .setRule, .showRule, .moduleImport].contains($0.kind)
            } == true
            self.store = store
        }
        if let options, options != self.options {
            self.options = options
            labelsChanged = true
        }
        if labelsChanged, let tree {
            refreshLabels(tree)
        }
        if var store, let tree {
            store.select(selection, source: source, tree: tree)
            self.store = store
        }
        return reply()
    }

    /// "Repeat previous call": the nearest earlier call before `location` that
    /// is a chip, whatever the selection reveals.
    public func repeatPrevious(before location: Int, formatter: ChipFormatter) -> ChipInsertion? {
        guard let tree, let store, location <= source.length else {
            return nil
        }
        var span = 4096
        while true {
            let start = max(0, location - span)
            let plan = Presentation.plan(
                source: source,
                nodes: tree.nodes(in: NSRange(location: start, length: location - start)) ?? [],
                selection: NSRange(location: source.length + 1, length: 0),
                definitions: store.definitions,
                options: options,
            )
            if let insertion = ChipEditing.repeatPrevious(before: location, chips: plan.chips, formatter: formatter) {
                return insertion
            }
            if start == 0 {
                return nil
            }
            span *= 4
        }
    }

    private func rebuild(selection: NSRange) {
        guard let tree = SyntaxTree(source as String) else {
            tree = nil
            store = nil
            return
        }
        self.tree = tree
        store = nil
        refreshLabels(tree)
        if store == nil {
            store = PresentationStore(source: source, tree: tree, selection: selection, options: options)
        }
    }

    /// Value labels come from the document's own definitions, so a change to
    /// one re-plans every chip.
    private func refreshLabels(_ tree: SyntaxTree) {
        let nodes = tree.nodes() ?? []
        bindings = nodes.filter { [.letBinding, .setRule, .showRule, .moduleImport].contains($0.kind) }.map(\.range)
        preamble = MathPreamble.extract(source: source as String, nodes: nodes)
        var options = options
        options.formatter.functions = Presentation.valueLabels(source: source, nodes: nodes)
        guard options != self.options || store == nil else {
            return
        }
        self.options = options
        if var store {
            store.setOptions(options, source: source, tree: tree)
            self.store = store
        }
    }

    private func reply() -> Reply {
        Reply(
            snapshot: store?.snapshot ?? PresentationSnapshot(length: source.length),
            definitions: store?.definitions ?? FunctionDefinitions(),
            formatter: options.formatter,
            preamble: preamble,
        )
    }
}
