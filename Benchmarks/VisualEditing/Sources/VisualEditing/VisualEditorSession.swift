import Foundation
import VisualPresentation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Platform-neutral glue: keeps the typst-syntax tree in step with native
/// edits, maintains the display plan incrementally (reveal and typing only
/// re-plan the touched paragraphs) and applies it through `DisplaySubstitution`.
/// The NSTextView/UITextView shims only forward `didProcessEditing` and
/// selection changes to it.
@MainActor
public final class VisualEditorSession {
    public let substitution: DisplaySubstitution
    public var formatter = ChipFormatter()
    public var policy = RevealPolicy.construct
    public var fragments: [String: (size: CGSize, baseline: CGFloat)] = [:]
    public private(set) var plan = DisplayPlan()
    public private(set) var lastPlanMilliseconds = 0.0
    public private(set) var lastNodeMilliseconds = 0.0
    public private(set) var lastShiftMilliseconds = 0.0
    /// Edits the parser rejected (must stay zero; production would reparse).
    public private(set) var editFailures = 0
    private let tree: SyntaxTree
    private weak var storage: NSTextContentStorage?
    private var signatures: [String: FunctionSignature] = [:]
    private var selection = NSRange(location: 0, length: 0)
    private var planned = false
    private var dirty: [NSRange] = []
    private var forwarder: EditForwarder?
    private var definitions: [NSRange] = []
    private var definitionCount = 0

    public init?(contentStorage: NSTextContentStorage, mode: DisplaySubstitution.Mode = .zeroWidth) {
        guard let text = contentStorage.textStorage?.string, let tree = SyntaxTree(text) else {
            return nil
        }
        self.tree = tree
        storage = contentStorage
        substitution = DisplaySubstitution(mode: mode)
        substitution.install(on: contentStorage)
        let all = tree.nodes()
        signatures = Presentation.signatures(nodes: all, source: text as NSString)
        definitions = all.filter { $0.kind == .letBinding }.map(\.range)
        definitionCount = definitions.count
    }

    /// For views that have no storage delegate yet (tests, the iPad shim).
    /// The macOS editor forwards from its existing Coordinator instead.
    public func observeEdits() {
        let forwarder = EditForwarder(session: self)
        self.forwarder = forwarder
        storage?.textStorage?.delegate = forwarder
    }

    private var source: NSString {
        (storage?.textStorage?.string ?? "") as NSString
    }

    private func input(_ selection: NSRange) -> PresentationInput {
        var input = PresentationInput(source: source, nodes: [], selection: selection)
        input.policy = policy
        input.formatter = formatter
        input.signatures = signatures
        input.fragments = fragments
        return input
    }

    private func timedNodes(_ range: NSRange?) -> [SyntaxNode] {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { lastNodeMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
        return tree.nodes(in: range)
    }

    /// Forward from NSTextStorageDelegate.didProcessEditing (characters only).
    /// `edited` is the range in the new text; `delta` its change in length.
    public func textDidChange(edited: NSRange, delta: Int) {
        let original = NSRange(location: edited.location, length: edited.length - delta)
        let reparsed = tree.edit(original, replacement: source.substring(with: edited))
        if reparsed == nil {
            editFailures += 1
        }
        guard planned else {
            return
        }
        if selection.location > NSMaxRange(original) {
            selection.location += delta
        }
        lastNodeMilliseconds = 0
        let started = DispatchTime.now().uptimeNanoseconds
        let window = NSUnionRange(edited, reparsed ?? edited)
        // Shift known `#let` ranges; an edit touching one (or adding one) may
        // change signatures, and therefore every chip of that function.
        definitions = definitions.compactMap { range in
            if NSMaxRange(range) < original.location {
                return range
            }
            return range.location > NSMaxRange(original) ? NSRange(
                location: range.location + delta,
                length: range.length,
            ) : nil
        }
        let touched = definitions.count != definitionCount
        if touched || tree.nodes(in: window).contains(where: { $0.kind == .letBinding }) {
            let all = tree.nodes()
            definitions = all.filter { $0.kind == .letBinding }.map(\.range)
            definitionCount = definitions.count
            let updated = Presentation.signatures(nodes: all, source: source)
            if updated != signatures {
                // A definition changed: re-plan everything (rare), then force a rebuild.
                signatures = updated
                var full = input(selection)
                full.nodesOverride = tree.nodes()
                plan = Presentation.plan(full)
                substitution.rebase(plan)
                dirty.append(NSRange(location: 0, length: source.length))
                return
            }
        }
        let shifted = plan.shifted(editing: original, delta: delta)
        lastShiftMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let update = Presentation.update(
            shifted,
            window: window,
            input: input(selection),
        ) { self.timedNodes($0) }
        plan = update.plan
        lastPlanMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        // Inside processEditing: hand TextKit the rebased plan now, and force
        // the edited paragraphs to rebuild on the next selection change.
        substitution.rebase(plan)
        dirty.append(update.affected)
    }

    /// Recomputes and applies the plan. While IME composition is active the
    /// update is deferred: marked text must never be re-laid out under the user.
    @discardableResult
    public func selectionDidChange(_ selection: NSRange, hasMarkedText: Bool) -> [NSRange] {
        guard !hasMarkedText else {
            return []
        }
        let old = self.selection
        self.selection = selection
        lastNodeMilliseconds = 0
        let started = DispatchTime.now().uptimeNanoseconds
        var windows: [NSRange]?
        if planned {
            var next = plan
            var affected: [NSRange] = []
            // One window when both selections share a paragraph (typing, arrows).
            let paragraph = source.paragraphRange(for: NSRange(location: min(old.location, source.length), length: 0))
            let targets = NSLocationInRange(selection.location, paragraph) || selection
                .location == NSMaxRange(paragraph)
                ? [NSUnionRange(old, selection)] : [old, selection]
            for window in targets {
                let update = Presentation.update(next, window: window, input: input(selection)) { self.timedNodes($0) }
                next = update.plan
                affected.append(update.affected)
            }
            plan = next
            windows = affected
        } else {
            var full = input(selection)
            full.nodesOverride = timedNodes(nil)
            plan = Presentation.plan(full)
            planned = true
        }
        lastPlanMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let force = dirty
        dirty = []
        return substitution.apply(plan, within: windows, force: force)
    }

    public var chips: [Chip] {
        plan.replacements.compactMap {
            if case let .chip(chip) = $0.content {
                return chip
            }
            return nil
        }
    }
}

@MainActor
final class EditForwarder: NSObject, @preconcurrency NSTextStorageDelegate {
    weak var session: VisualEditorSession?

    init(session: VisualEditorSession) {
        self.session = session
    }

    func textStorage(
        _: NSTextStorage,
        didProcessEditing editedMask: StorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int,
    ) {
        guard editedMask.contains(.editedCharacters) else {
            return
        }
        session?.textDidChange(edited: editedRange, delta: delta)
    }
}
