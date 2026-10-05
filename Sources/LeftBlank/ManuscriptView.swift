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
        // Explicit TextKit 1: native selection/IME plus NSLayoutManager's
        // drawing-only syntax attributes, with no implicit engine fallback.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        // Keep TextKit's default contiguous geometry. With styled paragraphs,
        // noncontiguous layout can shift an already drawn line during a hit test
        // after a distant jump (covered by the real-book benchmark).
        manager.allowsNonContiguousLayout = false
        let container = NSTextContainer(size: NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let editor = ManuscriptTextView(
            frame: NSRect(origin: .zero, size: scroll.contentSize),
            textContainer: container,
        )
        editor.workspace = workspace
        editor.delegate = context.coordinator
        storage.delegate = context.coordinator
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
        if editor.appliedFontSize != workspace.fontSize {
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
            editor.scheduleHighlight()
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
            editor.scheduleHighlight()
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
    private var selectingWithMouse = false
    private var highlightTask: Task<Void, Never>?
    private var placeholders: [NSRange] = []
    private var placeholderIndex = 0
    private var completionItems: [JSONValue] = []
    private var highlighting = false
    private(set) var appliedFontSize: CGFloat = 0
    private var styler = ManuscriptStyler()
    private let readingAnalysis = ReadingAnalysis()
    private weak var observedUndoManager: UndoManager?
    var workspaceRevision = -1
    private var loading = false
    private var characterEditCount = 0
    private var characterEdit: TextReplacement?

    private var viewportTask: Task<Void, Never>?

    func observeViewport(_ clip: NSClipView) {
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip,
        )
    }

    @objc private func viewportChanged(_ notification: Notification) {
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
        guard !loading, let workspace, !workspace.outline.isEmpty,
              let manager = layoutManager, let container = textContainer
        else {
            return
        }
        let rect = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caret = selectedRange().location
        // Keep the editing section while the caret is visible. Once scrolling
        // carries it off screen, follow the first visible text instead.
        workspace.trackOutline(at: NSLocationInRange(caret, characters) ? caret : characters.location)
    }

    func recordCharacterEdit(in storage: NSTextStorage, range: NSRange, delta: Int) {
        guard !loading else {
            return
        }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        scheduleHighlight()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let inset = NSSize(width: ManuscriptLayout.horizontalInset(for: newSize.width), height: 42)
        if textContainerInset != inset {
            textContainerInset = inset
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEditable {
            addCursorRect(visibleRect, cursor: .iBeam)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEditable {
            NSCursor.iBeam.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Attribute-only reading styles can invalidate glyph geometry between
    /// events. Resolve the visible layout before AppKit interprets a pointer.
    func prepareForPointerInteraction() {
        guard let container = textContainer, let manager = layoutManager else {
            return
        }
        let visible = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        manager.ensureLayout(forBoundingRect: visible, in: container)
    }

    override func mouseDown(with event: NSEvent) {
        workspace?.dismissAssistance()
        prepareForPointerInteraction()
        selectingWithMouse = true
        defer { selectingWithMouse = false
            scheduleHighlight()
        }
        super.mouseDown(with: event)
    }

    func load(_ content: String, selection: NSRange) {
        highlightTask?.cancel()
        loading = true
        defer { loading = false
            _ = takeCharacterEdit()
        }
        workspaceRevision = workspace?.revision ?? 0
        layoutManager?.setTemporaryAttributes(
            [:],
            forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
        )
        styler = ManuscriptStyler()
        styler.prepare(content, revision: workspaceRevision, decorations: SourcePresentation.decorations(in: content))
        string = content
        placeholders = []
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: min(selection.location, (content as NSString).length), length: 0))
        highlight()
        scrollRangeToVisible(selectedRange())
    }

    func scheduleHighlight() {
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else {
                return
            }
            let revision = workspaceRevision
            if styler.sourceRevision != revision {
                let source = workspace?.text ?? string
                // Parsing has no AppKit dependencies. Typing and IME never wait
                // for this work; a superseded result cannot touch native ranges.
                guard let decorations = await readingAnalysis.decorations(in: source),
                      !Task.isCancelled, workspaceRevision == revision
                else {
                    return
                }
                styler.prepare(source, revision: revision, decorations: decorations)
            }
            highlight()
        }
    }

    func highlight() {
        guard !highlighting, !selectingWithMouse, !hasMarkedText() else {
            return
        }
        highlighting = true
        defer { highlighting = false }
        let size = workspace?.fontSize ?? 16
        if appliedFontSize != size {
            // Explicit font changes are rare and must take effect immediately.
            if styler.sourceRevision != workspaceRevision {
                let source = workspace?.text ?? string
                styler.prepare(
                    source,
                    revision: workspaceRevision,
                    decorations: SourcePresentation.decorations(in: source),
                )
            }
            typingAttributes = ManuscriptStyler.baseAttributes(size: size)
            textColor = ManuscriptStyler.baseColor
            appliedFontSize = size
        }
        if styler.sourceRevision != workspaceRevision {
            scheduleHighlight()
        }
        let geometryChanged = styler.apply(
            to: self,
            size: size,
            styled: workspace?.styledSource == true,
            snapshot: workspace?.syntaxSnapshot,
            revision: workspace?.syntaxRevision ?? 0,
            documentRevision: workspaceRevision,
            syntaxDocumentRevision: workspace?.syntaxDocumentRevision ?? -1,
        )
        if geometryChanged {
            prepareForPointerInteraction()
            window?.invalidateCursorRects(for: self)
        }
        // Native typing must not inherit a hidden marker or heading font.
        typingAttributes = ManuscriptStyler.baseAttributes(size: size)
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
            scrollRangeToVisible(selectedRange())
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
        if !hasMarkedText(), event.keyCode == 48, !placeholders.isEmpty {
            placeholderIndex += event.modifierFlags.contains(.shift) ? -1 : 1
            if placeholderIndex >= 0, placeholderIndex < placeholders.count {
                setSelectedRange(placeholders[placeholderIndex])
                scrollRangeToVisible(selectedRange())
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

    func presentCompletions(_ items: [JSONValue]) {
        guard !items.isEmpty else {
            workspace?.showMessage(L10n.text("No completions are available here."))
            return
        }
        completionItems = items
        let menu = NSMenu()
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(
                title: item["label"].string ?? L10n.text("Complete"),
                action: #selector(applyCompletion(_:)),
                keyEquivalent: "",
            )
            entry.target = self
            entry.tag = index
            menu.addItem(entry)
        }
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let windowRect = window?.convertFromScreen(rect) ?? .zero
        let point = convert(windowRect.origin, from: nil)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func applyCompletion(_ sender: NSMenuItem) {
        guard completionItems.indices.contains(sender.tag) else {
            return
        }
        let item = completionItems[sender.tag]
        let edit = item["textEdit"]
        let content = edit["newText"].string ?? item["insertText"].string ?? item["label"].string ?? ""
        var range = selectedRange()
        let sourceRange = edit["range"].isNull ? edit["replace"] : edit["range"]
        if !sourceRange.isNull {
            let start = TextPosition(
                line: sourceRange["start"]["line"].int ?? 0,
                character: sourceRange["start"]["character"].int ?? 0,
            ).offset(in: string)
            let end = TextPosition(
                line: sourceRange["end"]["line"].int ?? 0,
                character: sourceRange["end"]["character"].int ?? 0,
            ).offset(in: string)
            range = NSRange(location: start, length: max(0, end - start))
        }
        insertSnippet(Snippet(text: content), replacing: range)
    }
}
