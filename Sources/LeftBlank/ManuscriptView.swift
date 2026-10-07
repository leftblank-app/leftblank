import AppKit
import LeftBlankCore
import SwiftUI

struct ManuscriptView: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = Theme.nativeEditor
        let editor = ManuscriptTextView.make(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.workspace = workspace
        // Equations typeset in their own Tinymist helper, never the manuscript's.
        editor.session?.mathRenderer = TinymistMathTypesetter.renderer(stateDirectory: workspace.stateDirectory)
        editor.delegate = context.coordinator
        editor.textStorage?.delegate = context.coordinator
        editor.isRichText = false
        editor.registerForDraggedTypes(ResourcePasteboard.types)
        editor.isEditable = workspace.editorIsEditable
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.backgroundColor = Theme.nativeEditor
        editor.textColor = Theme.nativeText
        editor.insertionPointColor = Theme.nativeAccent
        editor.selectedTextAttributes = [.backgroundColor: Theme.selection, .foregroundColor: Theme.selectedText]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(L10n.text("Document Editor"))
        scroll.documentView = editor
        workspace.editor = editor
        editor.observeViewport(scroll.contentView)
        editor.load(workspace.text, selection: workspace.selection)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ManuscriptTextView else {
            return
        }
        workspace.editor = editor
        editor.isEditable = workspace.editorIsEditable
        editor.setAccessibilityLabel(L10n.text("Document Editor"))
        if editor.workspaceRevision != workspace.revision, !editor.hasMarkedText() {
            editor.load(
                workspace.text,
                selection: workspace.selection,
            )
        }
        if editor.appliedFontSize != workspace.fontSize || editor.session?.isEnabled != workspace.styledSource {
            editor.highlight()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        let workspace: Workspace
        init(_ workspace: Workspace) {
            self.workspace = workspace
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ManuscriptTextView else {
                return
            }
            workspace.edited(editor.string, change: editor.takeCharacterEdit())
            editor.workspaceRevision = workspace.revision
            editor.scheduleTypingAssistance()
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int,
        ) {
            guard editedMask.contains(.editedCharacters) else {
                return
            }
            workspace.editor?.recordCharacterEdit(in: textStorage, range: editedRange, delta: delta)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? ManuscriptTextView else {
                return
            }
            workspace.selection = editor.selectedRange()
            editor.selectionChanged()
            editor.scheduleTypingAssistance()
        }
    }
}

@MainActor
final class ManuscriptTextView: NSTextView {
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        ResourcePasteboard.types + super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        if !importResources(from: .general) {
            super.paste(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if !importResources(from: .general) {
            super.pasteAsPlainText(sender)
        }
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if importResources(from: pasteboard) {
            return true
        }
        return super.readSelection(from: pasteboard, type: type)
    }

    func importResources(from pasteboard: NSPasteboard, at range: NSRange? = nil) -> Bool {
        guard let resource = ResourcePasteboard(pasteboard) else {
            return false
        }
        // Consume file/image payloads even when input is blocked. Falling back
        // to NSTextView would turn the same payload into literal file paths.
        guard isEditable, !hasMarkedText(), let workspace,
              !workspace.applyingCommand, !workspace.documentTransitionInProgress
        else {
            return true
        }
        let range = range ?? selectedRange()
        setSelectedRange(range)
        workspace.insertResources(resource.inputs, kind: resource.kind, replacing: range)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            return isEditable && !hasMarkedText() && workspace?.applyingCommand != true ? .copy : []
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            return draggingEntered(sender)
        }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            return !draggingEntered(sender).isEmpty
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            prepareForPointerInteraction()
            let point = convert(sender.draggingLocation, from: nil)
            let range = NSRange(location: characterIndexForInsertion(at: point), length: 0)
            return importResources(from: sender.draggingPasteboard, at: range)
        }
        return super.performDragOperation(sender)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Dynamic colors already live in storage and TextKit's temporary runs.
        // Repaint only: changing appearance must not reflow or touch source text.
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
    }

    weak var workspace: Workspace?
    var assistancePopover: NSPopover?
    lazy var sourceHover = SourceHoverController(editor: self)
    private var sourceTrackingArea: NSTrackingArea?
    private var selectingWithMouse = false
    private var placeholders: [NSRange] = []
    private var placeholderIndex = 0
    var typingTask: Task<Void, Never>?
    var typingRequestID = UUID()
    var typingPanel: NSPanel?
    var typingList = CompletionList(items: [], prefix: "")
    var typingSignature: LanguageSignature?
    var typingSource = ""
    var typingSelection = NSRange(location: 0, length: 0)
    private(set) var appliedFontSize: CGFloat = 0
    /// The top line to keep in place until the layout pass after a re-wrap.
    private var resizeAnchor: (offset: Int, y: CGFloat)?
    private var appliedSyntaxRevision = -1
    /// The visual layer: concealment, styles, chips, images and equations.
    var session: VisualEditorSession?
    var chipPopover: NSPopover?
    private weak var observedUndoManager: UndoManager?
    var workspaceRevision = -1
    private var loading = false
    private var characterEditCount = 0
    private var characterEdit: TextReplacement?

    private var viewportTask: Task<Void, Never>?
    private var hoverViewportBounds: NSRect?
    /// Whether AppKit switched this view to TextKit 1. Tests require false.
    var switchedToTextKit1 = false

    func observeViewport(_ clip: NSClipView) {
        hoverViewportBounds = clip.bounds
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip,
        )
    }

    @objc private func viewportChanged(_ notification: Notification) {
        if let clip = notification.object as? NSClipView, hoverViewportBounds != clip.bounds {
            if sourceHover.panel != nil {
                workspace?.recordOperation("hover.viewportChanged", [
                    "previous": hoverViewportBounds.map(NSStringFromRect) ?? "none",
                    "current": NSStringFromRect(clip.bounds),
                ])
            }
            hoverViewportBounds = clip.bounds
            sourceHover.dismiss()
        }
        guard viewportTask == nil else {
            return
        }
        // Clip notifications also occur during TextKit layout. Coalesce them and
        // inspect settled geometry outside the layout callback.
        viewportTask = Task { [weak self] in
            await Task.yield()
            guard let self else {
                return
            }
            viewportTask = nil
            updateOutlineForViewport()
        }
    }

    func updateOutlineForViewport() {
        guard !loading, let workspace, !workspace.outline.isEmpty, let characters = visibleCharacterRange() else {
            return
        }
        let caret = selectedRange().location
        // Keep the editing section while the caret is visible. Once scrolling
        // carries it off screen, follow the first visible text instead.
        workspace.trackOutline(at: NSLocationInRange(caret, characters) ? caret : characters.location)
    }

    func recordCharacterEdit(in storage: NSTextStorage, range: NSRange, delta: Int) {
        guard !loading else {
            return
        }
        session?.textDidChange(edited: range, delta: delta)
        characterEditCount += 1
        guard characterEditCount == 1, range.length - delta >= 0,
              NSMaxRange(range) <= storage.length
        else {
            characterEdit = nil
            return
        }
        characterEdit = TextReplacement(
            range: NSRange(location: range.location, length: range.length - delta),
            text: (storage.string as NSString).substring(with: range),
        )
    }

    func takeCharacterEdit() -> TextReplacement? {
        defer { characterEditCount = 0
            characterEdit = nil
        }
        return characterEditCount == 1 ? characterEdit : nil
    }

    override func layout() {
        super.layout()
        // The pass after re-wrapping sizes the view from a partial estimate
        // first, and the clip view clamps the scroll to it.
        if let anchor = resizeAnchor {
            resizeAnchor = nil
            keepAtTop(anchor)
            // This pass is over; lay out the viewport where it now is.
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sourceHover.observeWindow()
        observeUndoManager()
        window?.invalidateCursorRects(for: self)
    }

    private func observeUndoManager() {
        let manager = window == nil ? nil : undoManager
        guard observedUndoManager !== manager else {
            return
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.NSUndoManagerDidUndoChange,
            object: nil,
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.NSUndoManagerDidRedoChange,
            object: nil,
        )
        observedUndoManager = manager
        if let undoManager = manager {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoOrRedoCompleted),
                name: NSNotification.Name.NSUndoManagerDidUndoChange,
                object: undoManager,
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoOrRedoCompleted),
                name: NSNotification.Name.NSUndoManagerDidRedoChange,
                object: undoManager,
            )
        }
    }

    @objc private func undoOrRedoCompleted(_ notification: Notification) {
        // AppKit can restore the text storage without a delegate textDidChange
        // after grouped programmatic edits. Reconcile only after the whole group.
        placeholders = []
        if let workspace, workspace.text != string {
            workspace.edited(string, change: takeCharacterEdit())
        } else {
            _ = takeCharacterEdit()
        }
        workspaceRevision = workspace?.revision ?? -1
        workspace?.selection = selectedRange()
        selectionChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Re-wrapping discards TextKit 2's layout, and the next pass finds the
        // viewport by laying out every paragraph above it (all 80,000 of a long
        // document; each later edit then walks them). Keep the top line in
        // place by location instead, which also keeps the reader's place.
        let anchor = newSize.width != frame.width ? resizeAnchor ?? topLine() : nil
        super.setFrameSize(newSize)
        let inset = NSSize(width: ManuscriptLayout.horizontalInset(for: newSize.width), height: 42)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        if let anchor {
            resizeAnchor = anchor
            keepAtTop(anchor)
        }
    }

    /// Lays out the text around `anchor` and scrolls its line back to where it
    /// was in the viewport.
    private func keepAtTop(_ anchor: (offset: Int, y: CGFloat)) {
        guard let manager = textLayoutManager else {
            return
        }
        TextKit2Geometry.layOutContext(around: anchor.offset, in: manager)
        if let line = TextKit2Geometry.caretRect(at: anchor.offset, in: manager) {
            scrollContainer(to: line.minY - anchor.y)
        }
    }

    /// The first visible line's offset and its height within the viewport,
    /// from the laid-out viewport; nil before the first layout or at the top.
    private func topLine() -> (offset: Int, y: CGFloat)? {
        let visible = containerVisibleRect()
        let top = CGPoint(x: 0, y: visible.minY)
        guard visible.minY > 0, let manager = textLayoutManager,
              let offset = TextKit2Geometry.viewportInsertionOffset(at: top, in: manager),
              let line = TextKit2Geometry.caretRect(at: offset, in: manager)
        else {
            return nil
        }
        return (offset, line.minY - visible.minY)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEditable {
            addCursorRect(visibleRect, cursor: .iBeam)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let sourceTrackingArea {
            removeTrackingArea(sourceTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        sourceTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Global button state can belong to another window or the test host.
        // AppKit sends drags separately; track only selection in this editor.
        guard !hasMarkedText(), !selectingWithMouse else {
            sourceHover.dismiss()
            return
        }
        prepareForPointerInteraction()
        sourceHover.move(to: sourceOffset(at: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        sourceHover.scheduleDismissal()
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEditable {
            NSCursor.iBeam.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        workspace?.dismissAssistance()
        prepareForPointerInteraction()
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
           !hasMarkedText(), workspace?.canNavigateSource == true,
           let offset = sourceOffset(at: event)
        {
            setSelectedRange(NSRange(location: offset, length: 0))
            window?.makeFirstResponder(self)
            workspace?.goToDefinition()
            return
        }
        selectingWithMouse = true
        defer { selectingWithMouse = false
            selectionChanged()
        }
        super.mouseDown(with: event)
    }

    func load(_ content: String, selection: NSRange) {
        dismissTypingAssistance()
        chipPopover?.close()
        loading = true
        defer { loading = false
            _ = takeCharacterEdit()
        }
        workspaceRevision = workspace?.revision ?? 0
        string = content
        let size = workspace?.fontSize ?? 16
        textStorage?.setAttributes(
            Self.visualStyle(size).baseAttributes,
            range: NSRange(location: 0, length: textStorage?.length ?? 0),
        )
        placeholders = []
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: min(selection.location, (content as NSString).length), length: 0))
        appliedSyntaxRevision = -1
        // Another file of the project may have changed what equations import.
        (session?.mathRenderer as? EngineMathRenderer)?.cache.removeAll()
        session?.documentURL = workspace?.documentURL
        session?.open(selection: selectedRange())
        highlight()
        // After the first layout pass. Revealing a distant caret before it
        // makes TextKit 2 lay out every paragraph above it, and each later
        // keystroke then pays for all of them (40 ms in War and Peace).
        let revision = workspaceRevision
        Task { [weak self] in
            guard let self, workspaceRevision == revision else {
                return
            }
            reveal(selectedRange())
        }
    }

    /// The selection moved: reveal the constructs it touches. A mouse drag
    /// updates once it ends, so text never moves under the pointer.
    func selectionChanged() {
        if !selectingWithMouse {
            session?.selectionDidChange(selectedRange())
        }
    }

    /// Brings the visual layer up to date with the workspace: font size,
    /// reading mode and the latest semantic colours for exactly this text.
    func highlight() {
        guard let session else {
            return
        }
        let size = workspace?.fontSize ?? 16
        if appliedFontSize != size {
            // Explicit font changes are rare and must take effect immediately.
            let style = Self.visualStyle(size)
            let base = style.baseAttributes
            textStorage?.addAttributes(base, range: NSRange(location: 0, length: textStorage?.length ?? 0))
            typingAttributes = base
            session.style = style
            appliedFontSize = size
        }
        session.isEnabled = workspace?.styledSource ?? true
        if let workspace, let snapshot = workspace.syntaxSnapshot, workspace.syntaxRevision != appliedSyntaxRevision,
           workspace.syntaxDocumentRevision == workspaceRevision, snapshot.source.utf16.count == string.utf16.count
        {
            session.colors.setColors(snapshot.tokens.map { ($0.range, Theme.color(for: $0)) })
            appliedSyntaxRevision = workspace.syntaxRevision
        }
    }

    func insertSnippet(_ snippet: Snippet, replacing range: NSRange, focus: Bool = true) {
        guard workspace?.canEditSource != false, range.location >= 0, range.location <= string.utf16.count,
              range.length >= 0, range.length <= string.utf16.count - range.location
        else {
            return
        }
        observeUndoManager()
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        // Use the native editing path so undo/redo also delivers textDidChange.
        // Direct NSTextStorage mutation only undid the buffer, leaving the model stale.
        insertText(snippet.text, replacementRange: range)
        observeUndoManager()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(L10n.text("Insert Content"))
        placeholders = snippet.selections.map { NSRange(location: range.location + $0.location, length: $0.length) }
        placeholderIndex = 0
        setSelectedRange(placeholders.first ?? NSRange(location: range.location + snippet.text.utf16.count, length: 0))
        if focus {
            reveal(selectedRange())
        }
        highlight()
        if focus {
            window?.makeFirstResponder(self)
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard workspace?.canEditSource != false else {
            return false
        }
        let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if accepted {
            observeUndoManager()
        }
        if accepted, !placeholders.isEmpty {
            let delta = (replacementString ?? "").utf16.count - affectedCharRange.length
            if placeholderIndex < placeholders.count,
               affectedCharRange.location >= placeholders[placeholderIndex].location,
               NSMaxRange(affectedCharRange) <= NSMaxRange(placeholders[placeholderIndex])
            {
                placeholders[placeholderIndex].length += delta
                for index in (placeholderIndex + 1) ..< placeholders.count {
                    placeholders[index].location += delta
                }
            } else {
                placeholders = []
            }
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let hadHover = sourceHover.panel != nil
        sourceHover.dismiss()
        if hadHover, event.keyCode == 53, !hasMarkedText() {
            return
        }
        if handleTypingKey(event) {
            return
        }
        if event.keyCode == 111, event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
           !hasMarkedText(), workspace?.canNavigateSource == true
        {
            workspace?.goToDefinition()
            return
        }
        if !hasMarkedText(), event.keyCode == 48, !placeholders.isEmpty {
            placeholderIndex += event.modifierFlags.contains(.shift) ? -1 : 1
            if placeholderIndex >= 0, placeholderIndex < placeholders.count {
                setSelectedRange(placeholders[placeholderIndex])
                reveal(selectedRange())
            } else {
                let end = placeholders.last.map(NSMaxRange) ?? selectedRange().location
                placeholders = []
                setSelectedRange(NSRange(location: end, length: 0))
            }
            return
        }
        if !hasMarkedText(), event.keyCode == 53, !placeholders.isEmpty {
            placeholders = []
            setSelectedRange(NSRange(
                location: NSMaxRange(selectedRange()),
                length: 0,
            ))
            return
        }
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == "."
        {
            workspace?.requestCompletion()
            return
        }
        super.keyDown(with: event)
    }

    func setCompletionPlaceholders(_ selections: [NSRange]) {
        placeholders = selections
        placeholderIndex = 0
    }
}
