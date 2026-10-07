import AppKit
import LeftBlankCore
import SwiftUI

/// The manuscript's TextKit 2 stack and its visual layer
/// (`VisualEditorSession`, shared with the iPad). Never touch `layoutManager`:
/// one access, ours or AppKit's, switches the view to TextKit 1 for good and
/// the visual layer stops drawing. SwiftLint rejects it in the app.
extension ManuscriptTextView {
    static func make(frame: NSRect) -> ManuscriptTextView {
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = container
        let editor = ManuscriptTextView(frame: frame, textContainer: container)
        editor.session = VisualEditorSession(
            contentStorage: content,
            textLayoutManager: manager,
            style: visualStyle(16),
        )
        editor.session?.hasMarkedText = { [weak editor] in editor?.hasMarkedText() ?? false }
        editor.session?.onActivateChip = { [weak editor] chip, view in editor?.showChipForm(chip, from: view) }
        editor.session?.viewport = (
            visible: { [weak editor] in editor?.containerVisibleRect() ?? .zero },
            scroll: { [weak editor] in editor?.scrollContainer(to: $0) },
        )
        NotificationCenter.default.addObserver(
            editor,
            selector: #selector(switchingToTextKit1),
            name: NSTextView.willSwitchToNSLayoutManagerNotification,
            object: editor,
        )
        return editor
    }

    static func visualStyle(_ size: CGFloat) -> VisualStyle {
        VisualStyle(
            fontSize: size,
            text: Theme.sourceText,
            strong: Theme.sourceStrong,
            code: Theme.sourceString,
            codeBackground: Theme.codeBackground,
            link: Theme.sourceFunction,
            marker: Theme.sourceComment,
            math: Theme.sourceNumber,
            chip: Theme.nativeAccent,
            chipFill: Theme.selection,
        )
    }

    @objc func switchingToTextKit1(_: Notification) {
        switchedToTextKit1 = true
        workspace?.recordOperation("editor.textKit1Fallback", [
            "symbols": Thread.callStackSymbols.prefix(12).joined(separator: " | "),
        ])
    }

    /// Lays out the visible text before AppKit interprets a pointer.
    func prepareForPointerInteraction() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// The character under the pointer, not the nearest insertion position in the margin.
    func sourceOffset(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard let manager = textLayoutManager else {
            return nil
        }
        let offset = TextKit2Geometry.character(
            at: CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
            in: manager,
            text: string as NSString,
        )
        // A chip stands for its call: hover and command-click mean its function.
        if let offset, let chip = session?.chip(at: offset) {
            return chip.range.location + 1
        }
        return offset
    }

    /// Source of the lines intersecting the visible rect.
    func visibleCharacterRange() -> NSRange? {
        textLayoutManager.flatMap {
            TextKit2Geometry.characterRange(
                in: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y),
                manager: $0,
            )
        }
    }

    /// Scrolls `range` into view without changing the selection. Every jump
    /// (outline, preview sync, diagnostics, definitions, placeholders) uses it;
    /// see `TextKit2Geometry.reveal` for why not `scrollRangeToVisible`.
    func reveal(_ range: NSRange) {
        guard let manager = textLayoutManager else {
            return
        }
        TextKit2Geometry.reveal(range.location, in: manager, visible: containerVisibleRect, scroll: scrollContainer)
    }

    func containerVisibleRect() -> CGRect {
        visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
    }

    /// Scrolls so that container-y `y` is at the top of the viewport, or as
    /// near as the text allows. TextKit 2 resizes the view lazily, so a target
    /// laid out just now can lie past the frame: grow it to the text's extent,
    /// never beyond. A viewport past the end of the text makes macOS 15 lay out
    /// the whole document trying to fill it (all 41,302 paragraphs of War and
    /// Peace after revealing a caret restored at its end).
    func scrollContainer(to y: CGFloat) {
        guard let scroll = enclosingScrollView else {
            return
        }
        let clip = scroll.contentView
        if let manager = textLayoutManager {
            let text = manager.usageBoundsForTextContainer.maxY + 2 * textContainerInset.height
            if frame.height < text {
                setFrameSize(NSSize(width: frame.width, height: text))
            }
        }
        let top = max(0, min(y + textContainerOrigin.y, frame.height - visibleRect.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
    }

    /// Glyph frame of the character at `offset`, in view coordinates.
    func characterRect(at offset: Int) -> NSRect? {
        let text = string as NSString
        guard let manager = textLayoutManager, offset >= 0, offset < text.length else {
            return nil
        }
        return TextKit2Geometry.segments(
            text.rangeOfComposedCharacterSequence(at: offset),
            type: .standard,
            in: manager,
        )
        .first?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// What TextKit draws at `offset`: a rendering attribute (semantic colour),
    /// else the display paragraph (visual styles), else the source.
    func drawnAttribute(_ key: NSAttributedString.Key, at offset: Int) -> Any? {
        guard let manager = textLayoutManager, let location = TextKit2Geometry.location(offset, in: manager) else {
            return nil
        }
        var value: Any?
        manager.enumerateRenderingAttributes(from: location, reverse: false) { manager, attributes, range in
            if TextKit2Geometry.offset(of: range.location, in: manager) <= offset {
                value = attributes[key]
            }
            return false
        }
        if value == nil, let (paragraph, local) = displayParagraph(at: offset) {
            value = paragraph.attribute(key, at: local, effectiveRange: nil)
        }
        return value
    }

    func drawnColor(at offset: Int) -> NSColor? {
        drawnAttribute(.foregroundColor, at: offset) as? NSColor
    }

    /// The character TextKit lays out at `offset`: U+200B where markup is
    /// concealed, U+FFFC where a box stands in for source.
    func displayedCharacter(at offset: Int) -> Character? {
        displayParagraph(at: offset).map { paragraph, local in
            Character((paragraph.string as NSString).substring(with: NSRange(location: local, length: 1)))
        }
    }

    /// The box TextKit draws at `offset`, if any.
    func displayedAttachment(at offset: Int) -> VisualAttachment? {
        displayParagraph(at: offset).flatMap { paragraph, local in
            paragraph.attribute(.attachment, at: local, effectiveRange: nil) as? VisualAttachment
        }
    }

    private func displayParagraph(at offset: Int) -> (NSAttributedString, Int)? {
        guard let manager = textLayoutManager, let location = TextKit2Geometry.location(offset, in: manager) else {
            return nil
        }
        manager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = manager.textLayoutFragment(for: location),
              let paragraph = fragment.textElement as? NSTextParagraph,
              let start = paragraph.elementRange?.location
        else {
            return nil
        }
        let local = offset - TextKit2Geometry.offset(of: start, in: manager)
        let text = paragraph.attributedString
        return local >= 0 && local < text.length ? (text, local) : nil
    }

    // MARK: - Chips

    func showChipForm(_ chip: Chip, from view: NSView) {
        guard let session, let signature = session.signature(for: chip), isEditable,
              workspace?.canEditSource != false
        else {
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ChipForm(
            chip: chip,
            signature: signature,
            formatter: session.formatter,
            apply: { [weak self, weak popover] values in
                if let replacement = try self?.session?.edit(chip, values: values) {
                    self?.applyReplacement(replacement, actionName: L10n.text("Edit Call"))
                }
                popover?.close()
            },
            cancel: { [weak popover] in popover?.close() },
        ))
        chipPopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    /// One native, undoable replacement.
    func applyReplacement(_ replacement: TextReplacement, actionName: String) {
        guard replacement.range.location >= 0, NSMaxRange(replacement.range) <= string.utf16.count else {
            return
        }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        insertText(replacement.text, replacementRange: replacement.range)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(actionName)
    }

    /// Inserts a copy of the previous chip's call with Tab placeholders.
    func repeatPreviousCall() async {
        guard let session, workspace?.canEditSource != false else {
            return
        }
        let location = selectedRange().location
        guard let insertion = await session.repeatPrevious(at: location), selectedRange().location == location else {
            NSSound.beep()
            return
        }
        insertSnippet(insertion.snippet, replacing: insertion.range)
    }
}

extension Theme {
    static func color(for token: HighlightToken) -> NSColor {
        let kind = token.kind.replacingOccurrences(of: "hljs-", with: "").components(separatedBy: " ").first ?? token
            .kind
        return switch kind {
        case "comment", "punct", "delim", "meta": sourceComment
        case "string", "regexp", "escape": sourceString
        case "keyword", "operator", "selector-tag": sourceKeyword
        case "number", "bool", "literal", "symbol", "bullet": sourceNumber
        case "function", "title", "built_in", "type", "namespace", "link", "ref", "label": sourceFunction
        case "heading", "strong": sourceStrong
        case "raw", "code": sourceCode
        default: token.modifiers.contains("math") ? sourceNumber : sourceText
        }
    }
}
