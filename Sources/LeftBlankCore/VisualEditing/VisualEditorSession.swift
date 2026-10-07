import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// The visual layer of one TextKit 2 text view, shared verbatim by the Mac
/// (`NSTextView`) and the iPad (`UITextView`).
///
/// Source stays the document of record. As `NSTextContentStorage`'s delegate,
/// the session returns each paragraph's display text with the *same UTF-16
/// length* as the source: concealed markers become U+200B (zero width), and a
/// chip, bullet, image or typeset equation becomes U+FFFC carrying an
/// attachment, followed by U+200B. Display and source locations therefore map
/// 1:1, so TextKit's selection, hit testing, IME and editing ranges stay source
/// ranges, and the text storage (undo, copy, find, save) never sees a display
/// character. Construct styles (heading sizes, strong, emphasis, code) live in
/// the display paragraph too; Tinymist's semantic colours are rendering
/// attributes (`colors`), so a syntax reply never re-lays out text.
///
/// The view forwards character edits and selection changes. Parsing and
/// planning run on `PresentationEngine`; the session never waits for it.
@MainActor
public final class VisualEditorSession: NSObject, @preconcurrency NSTextContentStorageDelegate {
    public private(set) var snapshot = PresentationSnapshot()
    /// The document's function definitions, for chip forms.
    public private(set) var definitions = FunctionDefinitions()
    public private(set) var formatter = ChipFormatter()
    /// Semantic syntax colours, drawn over the display paragraphs.
    public let colors: RenderingAttributes
    public var style: VisualStyle {
        didSet {
            if style != oldValue {
                invalidate([NSRange(location: 0, length: snapshot.length)])
            }
        }
    }

    /// Off shows plain source: no concealment, styles or boxes.
    public var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                invalidate([NSRange(location: 0, length: snapshot.length)])
            }
        }
    }

    /// `#image` paths resolve against this file's folder.
    public var documentURL: URL?
    /// Typesets equations in the document's context; without one they show
    /// as source.
    public var mathRenderer: (any InlineMathRenderer)? {
        didSet {
            pendingMath = []
            invalidate(requestRanges {
                if case .math = $0 {
                    true
                } else {
                    false
                }
            })
        }
    }

    /// The document's rules for equations (`MathPreamble`), kept by the engine.
    public private(set) var mathPreamble = ""
    /// A chip was clicked or tapped.
    public var onActivateChip: ((Chip, PlatformView) -> Void)?
    /// Whether the view is composing text; plans wait until it finishes.
    public var hasMarkedText: () -> Bool = { false }
    /// The visible rect in text-container coordinates, and a way to scroll so
    /// that container-y `y` is at its top. With it, re-planned text above the
    /// viewport never moves what the writer is reading.
    public var viewport: (visible: () -> CGRect, scroll: (CGFloat) -> Void)?

    private weak var contentStorage: NSTextContentStorage?
    private weak var textLayoutManager: NSTextLayoutManager?
    private let engine = PresentationEngine()
    private var selection = NSRange(location: 0, length: 0)
    /// Increases with every edit or selection change sent to the engine.
    private var revision = 0
    private var pending: [PresentationEngine.Edit] = []
    private var inFlight = false
    /// Changes not drawn yet because text is being composed.
    private var deferred: [NSRange] = []
    private var opened = false
    /// Increases with every `open`; replies for an older text are dropped.
    private var generation = 0
    private let images = InlineImageCache()
    /// Equations waiting for the next render batch.
    private var pendingMath: [MathRenderRequest] = []
    private var mathScheduled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(contentStorage: NSTextContentStorage, textLayoutManager: NSTextLayoutManager, style: VisualStyle) {
        self.contentStorage = contentStorage
        self.textLayoutManager = textLayoutManager
        self.style = style
        colors = RenderingAttributes(manager: textLayoutManager, length: contentStorage.textStorage?.length ?? 0)
        super.init()
        contentStorage.delegate = self
        images.loaded = { [weak self] _ in
            self?.invalidate(self?.requestRanges {
                if case .image = $0 {
                    true
                } else {
                    false
                }
            } ?? [])
        }
    }

    private var text: NSString {
        (contentStorage?.textStorage?.string ?? "") as NSString
    }

    // MARK: - Input from the view

    /// Plans the text the storage holds now, for example after loading a file.
    /// This one plan is synchronous (about 0.1 s for a book), before TextKit
    /// lays anything out: installing a book's first plan later would
    /// invalidate every paragraph after layout began, and TextKit 2 then
    /// re-estimates the whole document while the writer scrolls.
    public func open(selection: NSRange) {
        let source = text as String
        self.selection = selection
        revision += 1
        generation += 1
        pending = []
        deferred = []
        colors.removeAll()
        colors.replaceCharacters(in: NSRange(location: 0, length: colors.length), length: text.length)
        images.removeAll()
        opened = true
        var initial = PresentationSnapshot(length: text.length)
        if let tree = SyntaxTree(source) {
            var options = PresentationOptions()
            options.formatter.functions = Presentation.valueLabels(source: text, nodes: tree.nodes() ?? [])
            let store = PresentationStore(source: text, tree: tree, selection: selection, options: options)
            initial = store.snapshot
            definitions = store.definitions
            formatter = options.formatter
        }
        install(initial, force: true)
        let sent = revision, generation = generation
        inFlight = true
        Task {
            let reply = await engine.open(source, selection: selection, options: PresentationOptions())
            receive(reply, sent: sent, generation: generation)
        }
    }

    /// Forward from `NSTextStorageDelegate` `didProcessEditing` when characters
    /// changed. `edited` is in the new text; `delta` is its change in length.
    public func textDidChange(edited: NSRange, delta: Int) {
        guard opened else {
            return
        }
        let original = NSRange(location: edited.location, length: edited.length - delta)
        colors.replaceCharacters(in: original, length: edited.length)
        snapshot.edit(original, replacementLength: edited.length)
        deferred = deferred.map { PresentationStore.rebase($0, editing: original, delta: delta) }
        selection = PresentationStore.rebase(selection, editing: original, delta: delta)
        pending.append(.init(range: original, text: text.substring(with: edited)))
        revision += 1
        send()
    }

    public func selectionDidChange(_ selection: NSRange) {
        guard opened else {
            return
        }
        if !deferred.isEmpty, !hasMarkedText() {
            let ranges = deferred
            deferred = []
            invalidate(ranges)
        }
        guard selection != self.selection else {
            return
        }
        let old = self.selection
        self.selection = selection
        revision += 1
        send()
        // Typeset equations are boxes outside the plan's reveal rules: the
        // caret entering or leaving one swaps it with its source.
        if mathRenderer != nil {
            let swapped = [old, selection].flatMap { range in
                snapshot.plan(in: range).requests.compactMap { request -> NSRange? in
                    guard case .math = request else {
                        return nil
                    }
                    let touched = { (selection: NSRange) in
                        selection.location <= NSMaxRange(request.range) && NSMaxRange(selection) >= request.range
                            .location
                    }
                    return touched(old) != touched(selection) ? request.range : nil
                }
            }
            invalidate(swapped)
        }
    }

    /// Returns once the display reflects every edit and selection sent so far.
    public func settled() async {
        guard inFlight || !pending.isEmpty else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func send() {
        guard !inFlight else {
            return
        }
        inFlight = true
        let edits = pending, selection = selection, sent = revision, generation = generation
        pending = []
        Task {
            let reply = await engine.update(edits, selection: selection)
            receive(reply, sent: sent, generation: generation)
        }
    }

    private func receive(_ reply: PresentationEngine.Reply, sent: Int, generation: Int) {
        inFlight = false
        guard generation == self.generation else {
            send()
            return
        }
        definitions = reply.definitions
        formatter = reply.formatter
        if reply.preamble != mathPreamble {
            mathPreamble = reply.preamble
            invalidate(requestRanges {
                if case .math = $0 {
                    true
                } else {
                    false
                }
            })
        }
        // Edits made while the engine worked move the reply into today's text.
        var next = reply.snapshot
        for edit in pending {
            next.edit(edit.range, replacementLength: (edit.text as NSString).length)
        }
        if next.length == text.length {
            install(next)
        }
        if sent != revision {
            send()
        } else {
            let waiting = waiters
            waiters = []
            waiting.forEach { $0.resume() }
        }
    }

    private func install(_ next: PresentationSnapshot, force: Bool = false) {
        let changed = force ? [NSRange(location: 0, length: next.length)] : next.changedRanges(from: snapshot)
        snapshot = next
        if hasMarkedText() {
            // Never re-lay out marked text under the writer.
            deferred += changed
            return
        }
        invalidate(changed)
    }

    /// Makes the content storage rebuild the paragraphs covering `ranges`. An
    /// attribute-only edit: no characters change, so there is no undo record
    /// and the selection stays.
    public func invalidate(_ ranges: [NSRange]) {
        guard let storage = contentStorage, let text = storage.textStorage, !ranges.isEmpty,
              text.length == snapshot.length, text.editedMask.isEmpty
        else {
            return
        }
        let source = text.string as NSString
        let paragraphs = Presentation.merged(ranges.map {
            Presentation.paragraphRange(
                NSIntersectionRange($0, NSRange(location: 0, length: source.length)),
                in: source,
            )
        })
        // Text re-planned above the viewport can change height; remember which
        // line is at the top and where, from the laid-out viewport itself.
        var anchor: (offset: Int, y: CGFloat)?
        if let viewport, let manager = textLayoutManager {
            let visible = viewport.visible()
            if let offset = TextKit2Geometry.viewportInsertionOffset(at: visible.origin, in: manager),
               paragraphs.contains(where: { $0.location < offset }),
               let caret = TextKit2Geometry.caretRect(at: offset, in: manager)
            {
                anchor = (offset, caret.minY - visible.minY)
            }
        }
        storage.performEditingTransaction {
            for range in paragraphs where NSMaxRange(range) <= text.length && range.length > 0 {
                text.edited(.editedAttributes, range: range, changeInLength: 0)
            }
        }
        guard let anchor, let viewport, let manager = textLayoutManager else {
            return
        }
        for _ in 0 ..< 3 {
            guard let caret = TextKit2Geometry.caretRect(at: anchor.offset, in: manager) else {
                return
            }
            let visible = viewport.visible()
            if abs(caret.minY - visible.minY - anchor.y) < 0.5 {
                return
            }
            viewport.scroll(max(0, caret.minY - anchor.y))
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    // MARK: - Display paragraphs

    /// Temporary diagnostic: TextKit creates one element per request.
    public static var paragraphRequests = 0

    public func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange,
    ) -> NSTextParagraph? {
        Self.paragraphRequests += 1
        guard isEnabled, let text = textContentStorage.textStorage, text.length == snapshot.length,
              NSMaxRange(range) <= text.length
        else {
            return nil
        }
        let plan = snapshot.plan(in: range)
        guard !plan.styles.isEmpty || !plan.conceals.isEmpty || !plan.replacements.isEmpty else {
            return nil
        }
        return NSTextParagraph(attributedString: display(
            text.attributedSubstring(from: range),
            range: range,
            plan: plan,
        ))
    }

    /// The display text of the paragraph at `range`; exposed for tests.
    func display(_ source: NSAttributedString, range: NSRange, plan: DisplayPlan) -> NSAttributedString {
        let display = NSMutableAttributedString(attributedString: source)
        func local(_ value: NSRange) -> NSRange? {
            let clipped = NSIntersectionRange(value, range)
            return clipped
                .length > 0 ? NSRange(location: clipped.location - range.location, length: clipped.length) : nil
        }
        for run in plan.styles {
            guard let span = local(run.range) else {
                continue
            }
            switch run.style {
            case .strong:
                display.enumerateAttribute(.font, in: span) { value, part, _ in
                    let font = value as? PlatformFont ?? style.font
                    let bold: PlatformFont = font.visualIsMonospaced
                        ? .monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
                        : .systemFont(ofSize: font.pointSize, weight: .semibold)
                    display.addAttributes([.font: bold, .foregroundColor: style.strong], range: part)
                }
            case .emphasis:
                display.enumerateAttribute(.font, in: span) { value, part, _ in
                    display.addAttribute(
                        .font,
                        value: (value as? PlatformFont ?? style.font).visualItalic(),
                        range: part,
                    )
                }
            case .revealedMarker:
                display.addAttribute(.foregroundColor, value: style.marker, range: span)
            default:
                display.addAttributes(style.attributes(for: run.style), range: span)
            }
        }
        for conceal in plan.conceals {
            if let span = local(conceal) {
                display.replaceCharacters(in: span, with: String(repeating: "\u{200B}", count: span.length))
            }
        }
        var boxes: [(NSRange, VisualAttachment)] = []
        for replacement in plan.replacements where replacement.range.location >= range.location {
            if let span = local(replacement.range), let box = attachment(for: replacement.content) {
                boxes.append((span, box))
            }
        }
        for request in plan.requests {
            guard case let .math(mathRange, source, isBlock) = request, mathRange.location >= range.location,
                  NSMaxRange(mathRange) <= NSMaxRange(range), !touchesSelection(mathRange),
                  let span = local(mathRange), let box = equation(source, isBlock: isBlock)
            else {
                continue
            }
            boxes.append((span, box))
        }
        for (span, box) in boxes {
            let attributes = display.attributes(at: span.location, effectiveRange: nil)
            var boxAttributes = attributes
            boxAttributes[.attachment] = box
            let replacement = NSMutableAttributedString(string: "\u{FFFC}", attributes: boxAttributes)
            replacement.append(NSAttributedString(
                string: String(repeating: "\u{200B}", count: span.length - 1),
                attributes: attributes,
            ))
            display.replaceCharacters(in: span, with: replacement)
        }
        return display
    }

    private func touchesSelection(_ range: NSRange) -> Bool {
        selection.location <= NSMaxRange(range) && NSMaxRange(selection) >= range.location
    }

    private func attachment(for content: ReplacementContent) -> VisualAttachment? {
        let font = style.font
        switch content {
        case let .chip(chip):
            return .chip(chip.label, style: style, session: self)
        case .bullet:
            let width = ceil(("• " as NSString).size(withAttributes: [.font: font]).width)
            return VisualAttachment(
                content: .bullet,
                size: CGSize(width: width, height: ceil(font.ascender - font.descender)),
                descent: -font.descender,
                style: style,
                session: self,
            )
        case let .image(path):
            let url = URL(fileURLWithPath: path, relativeTo: documentURL?.deletingLastPathComponent())
                .standardizedFileURL
            let image = images.image(at: url)
            let size = image?.size ?? CGSize(width: 96, height: 64)
            return VisualAttachment(
                content: .image(image?.image, name: url.lastPathComponent),
                size: size,
                descent: 0,
                style: style,
                session: self,
            )
        case .fragment:
            return nil
        }
    }

    private func equation(_ source: String, isBlock: Bool) -> VisualAttachment? {
        guard let renderer = mathRenderer else {
            return nil
        }
        let request = MathRenderRequest(source: source, isBlock: isBlock, style: mathStyle)
        let cached = renderer.cached(request)
        if cached == nil || cached?.isStale == true, !pendingMath.contains(request) {
            pendingMath.append(request)
            scheduleMath(renderer)
        }
        // A stale image (another style or an earlier failure) shows until a
        // current one arrives.
        return cached?.image.map {
            VisualAttachment(
                content: .math($0.image),
                size: $0.size,
                descent: $0.descent,
                style: style,
                session: self,
            )
        }
    }

    /// One batch per layout pass: the paragraphs TextKit asks for together.
    private func scheduleMath(_ renderer: any InlineMathRenderer) {
        guard !mathScheduled else {
            return
        }
        mathScheduled = true
        Task {
            await Task.yield()
            mathScheduled = false
            let batch = pendingMath
            pendingMath = []
            guard !batch.isEmpty else {
                return
            }
            let results = await renderer.render(batch)
            let sources = Set(results.filter { $0.image != nil }.map(\.request.source))
            invalidate(requestRanges {
                if case let .math(_, source, _) = $0 {
                    sources.contains(source)
                } else {
                    false
                }
            })
        }
    }

    private var mathStyle: MathRenderStyle {
        #if canImport(AppKit)
            var color: CGColor = style.math.cgColor
            NSApp?.effectiveAppearance.performAsCurrentDrawingAppearance { color = style.math.cgColor }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
        #else
            let color = style.math.resolvedColor(with: UITraitCollection.current).cgColor
            let scale = UITraitCollection.current.displayScale
        #endif
        let folder = documentURL?.deletingLastPathComponent()
        return MathRenderStyle(
            fontSize: Double(style.fontSize),
            color: MathColor(color) ?? MathColor(red: 0, green: 0, blue: 0),
            preamble: mathPreamble,
            scale: Double(max(1, scale)),
            directory: folder,
        )
    }

    /// Ranges of the requests (equations, images) that match.
    private func requestRanges(_ matches: (InlineRequest) -> Bool) -> [NSRange] {
        snapshot.plan(in: NSRange(location: 0, length: snapshot.length)).requests.filter(matches).map(\.range)
    }

    // MARK: - Chips

    func activateChip(at location: any NSTextLocation, view: PlatformView) {
        guard let manager = textLayoutManager else {
            return
        }
        if let chip = chip(at: TextKit2Geometry.offset(of: location, in: manager)) {
            onActivateChip?(chip, view)
        }
    }

    /// The chip drawn at `offset`.
    public func chip(at offset: Int) -> Chip? {
        snapshot.plan(in: NSRange(location: offset, length: 0)).chips.first { NSLocationInRange(offset, $0.range) }
    }

    public func signature(for chip: Chip) -> FunctionSignature? {
        definitions.signature(chip.callee, before: chip.range.location)
    }

    /// The single source replacement that writes a form's values back.
    public func edit(_ chip: Chip, values: [String: String]) throws -> TextReplacement? {
        guard let signature = signature(for: chip) else {
            return nil
        }
        return try ChipEditing.edit(chip, values: values, signature: signature, source: text)
    }

    /// "Repeat previous call" at `location`: the nearest earlier call that
    /// shows as a chip, with Tab placeholders for its values.
    public func repeatPrevious(at location: Int) async -> ChipInsertion? {
        // The engine must have the edits typed just before.
        await settled()
        return await engine.repeatPrevious(before: location, formatter: formatter)
    }
}
