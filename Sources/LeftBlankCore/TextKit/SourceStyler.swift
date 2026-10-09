import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Reading styles for one TextKit 2 text view, shared verbatim by the Mac
/// (`NSTextView`) and the iPad (`UITextView`).
///
/// Styles are plain attributes on the source text in the text storage:
/// headings are larger and bold by level, `*strong*` is bold, `_emphasis_`
/// italic and raw text monospaced. Every character, markers included, is
/// drawn as typed; nothing is hidden or replaced. Tinymist's semantic colours
/// are rendering attributes (`colors`), so a syntax reply never re-lays out
/// text.
///
/// The view forwards character edits. Parsing runs on `SourceStyleEngine`;
/// the styler never waits for it. Until a reply arrives, edited text keeps the
/// fonts the text storage moved with it.
@MainActor
public final class SourceStyler: NSObject, @preconcurrency NSTextContentStorageDelegate {
    /// The `SourceStyle` the font of a run was chosen for, as `code(for:)`.
    /// Comparing it, not fonts, leaves the fallback fonts AppKit and UIKit
    /// substitute for CJK and emoji alone.
    static let styleKey = NSAttributedString.Key("LeftBlankSourceStyle")

    /// Semantic syntax colours, drawn over the text.
    public let colors: RenderingAttributes
    public private(set) var fontSize: CGFloat
    public private(set) var textColor: PlatformColor
    /// Off shows plain source: one font, syntax colours only.
    public private(set) var isEnabled = true
    /// Whether the view is composing text; styles wait until it finishes.
    public var hasMarkedText: () -> Bool = { false }
    /// The visible rect in text-container coordinates, and a way to scroll so
    /// that container-y `y` is at its top. With it, restyled text above the
    /// viewport never moves what the writer is reading.
    public var viewport: (visible: () -> CGRect, scroll: (CGFloat) -> Void)?

    private weak var contentStorage: NSTextContentStorage?
    private weak var textLayoutManager: NSTextLayoutManager?
    private let engine = SourceStyleEngine()
    private var fonts: [SourceStyle: PlatformFont] = [:]
    private var pending: [SourceStyleEngine.Edit] = []
    private var inFlight = false
    /// Replies not applied yet because text is being composed.
    private var deferred: [SourceStyleEngine.Reply] = []
    private var opened = false
    /// Increases with every `open`; replies for an older text are dropped.
    private var generation = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        contentStorage: NSTextContentStorage,
        textLayoutManager: NSTextLayoutManager,
        fontSize: CGFloat,
        textColor: PlatformColor,
    ) {
        self.contentStorage = contentStorage
        self.textLayoutManager = textLayoutManager
        self.fontSize = fontSize
        self.textColor = textColor
        colors = RenderingAttributes(manager: textLayoutManager, length: contentStorage.textStorage?.length ?? 0)
        super.init()
        contentStorage.delegate = self
    }

    /// Attributes of plain source text and of new typing.
    public var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 2
        return [.font: font(for: .plain), .foregroundColor: textColor, .paragraphStyle: paragraph]
    }

    public func font(for style: SourceStyle) -> PlatformFont {
        if let font = fonts[style] {
            return font
        }
        let heading = style.heading > 0
        let size = heading ? fontSize + CGFloat(max(2, 8 - style.heading * 2)) : fontSize
        let weight: PlatformFont.Weight = heading || style.strong ? .semibold : .regular
        var font: PlatformFont = heading && !style.raw
            ? .systemFont(ofSize: size, weight: weight)
            : .monospacedSystemFont(ofSize: size, weight: weight)
        if style.emphasis {
            font = font.italic()
        }
        fonts[style] = font
        return font
    }

    private var storage: NSTextStorage? {
        contentStorage?.textStorage
    }

    // MARK: - Input from the view

    /// Styles the text the storage holds now from scratch, for example after
    /// loading a file or changing the font. This one parse is synchronous
    /// (about 0.1 s for a book), before TextKit lays anything out: styling a
    /// book later would invalidate every paragraph after layout began, and
    /// TextKit 2 then re-estimates the whole document while the writer
    /// scrolls.
    public func open(fontSize: CGFloat, textColor: PlatformColor, isEnabled: Bool) {
        guard let storage else {
            return
        }
        if fontSize != self.fontSize || textColor != self.textColor {
            fonts = [:]
        }
        self.fontSize = fontSize
        self.textColor = textColor
        self.isEnabled = isEnabled
        // Replies still on their way belong to the old text.
        generation += 1
        inFlight = false
        pending = []
        deferred = []
        opened = true
        let source = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        colors.removeAll()
        colors.replaceCharacters(in: NSRange(location: 0, length: colors.length), length: whole.length)
        let runs = isEnabled ? SyntaxTree(source).map { SourceStyling.runs($0.nodes() ?? []) } ?? [] : []
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        for segment in SourceStyling.segments(runs, in: whole) where segment.style != .plain {
            storage.addAttributes(
                [.font: font(for: segment.style), Self.styleKey: Self.code(for: segment.style)],
                range: segment.range,
            )
        }
        storage.endEditing()
        guard isEnabled else {
            resumeWaiters()
            return
        }
        let generation = generation
        inFlight = true
        Task {
            await engine.open(source)
            if generation == self.generation {
                inFlight = false
                send()
            }
        }
    }

    /// Forward from `NSTextStorageDelegate` `didProcessEditing` when characters
    /// changed. `edited` is in the new text; `delta` is its change in length.
    public func textDidChange(edited: NSRange, delta: Int) {
        guard opened, let storage else {
            return
        }
        let original = NSRange(location: edited.location, length: edited.length - delta)
        colors.replaceCharacters(in: original, length: edited.length)
        guard isEnabled else {
            return
        }
        deferred = deferred.map { $0.rebased(editing: original, delta: delta) }
        pending.append(.init(range: original, text: (storage.string as NSString).substring(with: edited)))
        send()
    }

    /// Applies styles that waited for a composition to end. Call when the
    /// selection changes.
    public func selectionDidChange() {
        guard !deferred.isEmpty, !hasMarkedText() else {
            return
        }
        let replies = deferred
        deferred = []
        replies.forEach(apply)
    }

    /// Returns once the text is styled for every edit sent so far.
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
        guard !pending.isEmpty else {
            resumeWaiters()
            return
        }
        inFlight = true
        let edits = pending, generation = generation
        pending = []
        Task {
            let reply = await engine.update(edits)
            receive(reply, generation: generation)
        }
    }

    private func receive(_ reply: SourceStyleEngine.Reply, generation: Int) {
        // A newer `open` owns the engine now.
        guard generation == self.generation else {
            return
        }
        inFlight = false
        // Edits made while the engine worked move the reply into today's text.
        var reply = reply
        for edit in pending {
            reply = reply.rebased(editing: edit.range, delta: (edit.text as NSString).length - edit.range.length)
        }
        apply(reply)
        send()
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    /// Sets the fonts of `reply.region` where they differ from its styles. An
    /// attribute-only edit: no characters change, so there is no undo record
    /// and the selection stays.
    private func apply(_ reply: SourceStyleEngine.Reply) {
        guard let storage, NSMaxRange(reply.region) <= storage.length else {
            return
        }
        if hasMarkedText() || !storage.editedMask.isEmpty {
            // Never re-lay out marked text under the writer.
            deferred.append(reply)
            return
        }
        var changes: [(range: NSRange, style: SourceStyle)] = []
        for segment in SourceStyling.segments(reply.runs, in: reply.region) {
            let code = Self.code(for: segment.style)
            storage.enumerateAttribute(Self.styleKey, in: segment.range) { value, span, _ in
                if value as? Int ?? 0 != code {
                    changes.append((span, segment.style))
                }
            }
        }
        guard let first = changes.first else {
            return
        }
        // Text restyled above the viewport can change height; remember which
        // line is at the top and where, from the laid-out viewport itself.
        var anchor: (offset: Int, y: CGFloat)?
        if let viewport, let manager = textLayoutManager {
            let visible = viewport.visible()
            if let offset = TextKit2Geometry.viewportInsertionOffset(at: visible.origin, in: manager),
               first.range.location < offset,
               let caret = TextKit2Geometry.caretRect(at: offset, in: manager)
            {
                anchor = (offset, caret.minY - visible.minY)
            }
        }
        storage.beginEditing()
        for change in changes {
            if change.style == .plain {
                storage.addAttribute(.font, value: font(for: .plain), range: change.range)
                storage.removeAttribute(Self.styleKey, range: change.range)
            } else {
                storage.addAttributes(
                    [.font: font(for: change.style), Self.styleKey: Self.code(for: change.style)],
                    range: change.range,
                )
            }
        }
        storage.endEditing()
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

    static func code(for style: SourceStyle) -> Int {
        min(style.heading, 7) | (style.strong ? 8 : 0) | (style.emphasis ? 16 : 0) | (style.raw ? 32 : 0)
    }

    /// The style the text at `offset` is drawn in.
    public func style(at offset: Int) -> SourceStyle {
        guard let storage, offset >= 0, offset < storage.length else {
            return .plain
        }
        let code = storage.attribute(Self.styleKey, at: offset, effectiveRange: nil) as? Int ?? 0
        return SourceStyle(heading: code & 7, strong: code & 8 != 0, emphasis: code & 16 != 0, raw: code & 32 != 0)
    }

    // MARK: - Paragraph count

    /// Paragraphs TextKit has asked for, process-wide. Each request builds a
    /// text element, and on macOS 15 every edit walks the cached elements
    /// after it, so the book benchmark checks this count stays small.
    public private(set) static var paragraphsBuilt = 0

    public func textContentStorage(
        _: NSTextContentStorage,
        textParagraphWith _: NSRange,
    ) -> NSTextParagraph? {
        Self.paragraphsBuilt += 1
        return nil
    }
}

extension SourceStyleEngine.Reply {
    /// The same styles after a native replacement of `edit` (old coordinates)
    /// that changed the length by `delta`.
    func rebased(editing edit: NSRange, delta: Int) -> Self {
        Self(
            region: SourceStyling.rebase(region, editing: edit, delta: delta),
            runs: runs.map { SourceStyleRun(
                range: SourceStyling.rebase($0.range, editing: edit, delta: delta),
                kind: $0.kind,
            ) },
        )
    }
}
