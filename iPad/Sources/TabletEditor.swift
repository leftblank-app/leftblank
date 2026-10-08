import LeftBlankCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct TabletEditor: UIViewRepresentable {
    @ObservedObject var workspace: TabletWorkspace

    func makeUIView(context: Context) -> UITextView {
        // TextKit 2: the visual layer (VisualEditorSession) is shared with the Mac.
        let view = TabletTextView(usingTextLayoutManager: true)
        view.workspace = workspace
        view.installVisualLayer(style: TabletTheme.visualStyle(workspace.fontSize))
        view.session?.mathRenderer = workspace.makeInlineMathRenderer()
        view.textStorage.delegate = context.coordinator
        context.coordinator.textView = view
        view.sourceHover.install()
        view.delegate = context.coordinator
        view.addInteraction(UIDropInteraction(delegate: view))
        view.backgroundColor = TabletTheme.nativeEditor
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.adjustsFontForContentSizeCategory = true
        view.isFindInteractionEnabled = true
        view.textContainerInset = UIEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        view.accessibilityLabel = L10n.text("Writing")
        view.accessibilityIdentifier = "manuscript"
        workspace.assistance.onInvalidate = { [weak view] in view?.dismissTypingAssistance()
            view?.sourceHover.dismiss()
        }
        workspace.editor = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.workspace = workspace
        (view as? TabletTextView)?.workspace = workspace
        workspace.assistance.onInvalidate = { [weak view] in
            (view as? TabletTextView)?.dismissTypingAssistance()
            (view as? TabletTextView)?.sourceHover.dismiss()
        }
        guard view.markedTextRange == nil else {
            return
        }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for:
            .monospacedSystemFont(ofSize: workspace.fontSize, weight: .regular))
        // Comparing a book's text costs milliseconds per update; a version this
        // view produced needs no comparison.
        let synced = coordinator.synced?.generation == workspace.generation
            && coordinator.synced?.version == workspace.version
        let replaced = !synced && !TextIdentity.equal(workspace.text, view.textStorage.string)
        coordinator.synced = (workspace.generation, workspace.version)
        if replaced {
            (view as? TabletTextView)?.clearSnippet()
            view.text = workspace.text
            view.selectedRange = NSRange(
                location: min(workspace.selection.location, workspace.text.utf16.count),
                length: 0,
            )
        }
        let editable = workspace.canEditSource && !workspace.busy && workspace.layout != .preview
        if view.isEditable != editable {
            view.isEditable = editable
            if !editable {
                workspace.assistance.invalidate()
            }
        }
        let syntaxReady = workspace.highlightedVersion == workspace.version
        let syntaxChanged = syntaxReady && coordinator.styledRevision != workspace.highlightRevision
        guard replaced || coordinator.fontSize != font.pointSize || syntaxChanged else {
            return
        }
        let session = (view as? TabletTextView)?.session
        if replaced || coordinator.fontSize != font.pointSize {
            // Font changes are rare; the source keeps one base style, and the
            // visual layer draws reading styles in its display paragraphs.
            var style = TabletTheme.visualStyle(font.pointSize)
            style.text = TabletTheme.sourceText
            var base = style.baseAttributes
            base[.font] = font
            let selected = view.selectedRange
            view.textStorage.setAttributes(base, range: NSRange(location: 0, length: view.textStorage.length))
            view.selectedRange = selected
            view.typingAttributes = base
            session?.style = style
        }
        coordinator.fontSize = font.pointSize
        if replaced {
            // Another file of the project may have changed what equations import.
            (session?.mathRenderer as? EngineMathRenderer)?.cache.removeAll()
            session?.documentURL = workspace.sourceURL
            session?.open(selection: view.selectedRange)
        }
        if syntaxReady {
            coordinator.styledRevision = workspace.highlightRevision
            // Semantic colours are rendering attributes: no re-layout, no undo.
            session?.colors.setColors(workspace.tokens.map { ($0.range, TabletTheme.color(for: $0)) })
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var workspace: TabletWorkspace
        weak var textView: TabletTextView?
        var updating = false
        var styledRevision = -1
        /// The workspace generation and version whose text this view shows.
        var synced: (generation: UUID, version: Int)?
        /// Characters changed since the workspace last received the text.
        var unsynced = false
        /// The native replacement since then, while there is exactly one.
        private var change: TextReplacement?
        private var changes = 0
        var fontSize: CGFloat = 0
        init(_ workspace: TabletWorkspace) {
            self.workspace = workspace
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard workspace.canEditSource, !workspace.busy else {
                return false
            }
            (textView as? TabletTextView)?.snippet?.edit(range, replacement: text)
            return true
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorage.EditActions,
            range editedRange: NSRange,
            changeInLength delta: Int,
        ) {
            guard editedMask.contains(.editedCharacters), !updating else {
                return
            }
            unsynced = true
            changes += 1
            change = changes == 1 && editedRange.length - delta >= 0 ? TextReplacement(
                range: NSRange(location: editedRange.location, length: editedRange.length - delta),
                text: (textStorage.string as NSString).substring(with: editedRange),
            ) : nil
            textView?.session?.textDidChange(edited: editedRange, delta: delta)
        }

        /// Whether the view's text is ahead of the workspace. As the storage's
        /// delegate this is known; otherwise (a bare coordinator) compare.
        private func changed(_ textView: UITextView) -> Bool {
            textView.textStorage.delegate === self ? unsynced : !TextIdentity.equal(textView.text, workspace.text)
        }

        private func takeChange() -> TextReplacement? {
            defer {
                unsynced = false
                change = nil
                changes = 0
            }
            return change
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? TabletTextView)?.sourceHover.viewportChanged()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !updating, textView.markedTextRange == nil else {
                return
            }
            // UIKit reports the selection first, which may already have synced.
            if changed(textView) {
                workspace.edited(textView.text, selection: textView.selectedRange, change: takeChange())
                synced = (workspace.generation, workspace.version)
            }
            (textView as? TabletTextView)?.scheduleTypingAssistance()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else {
                return
            }
            if textView.markedTextRange == nil {
                (textView as? TabletTextView)?.session?.selectionDidChange(textView.selectedRange)
            }
            if textView.markedTextRange == nil, changed(textView) {
                workspace.edited(textView.text, selection: textView.selectedRange, change: takeChange())
                synced = (workspace.generation, workspace.version)
            } else if workspace.selection != textView.selectedRange {
                workspace.assistance.invalidate()
                workspace.selection = textView.selectedRange
            }
            (textView as? TabletTextView)?.scheduleTypingAssistance()
        }
    }
}

@MainActor final class TabletTextView: UITextView, UIDropInteractionDelegate {
    weak var workspace: TabletWorkspace?
    lazy var sourceHover = TabletSourceHover(editor: self)
    /// The visual layer: concealment, styles, chips, images and equations.
    var session: VisualEditorSession?
    lazy var chipTap = TabletChipTap()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        sourceHover.dismiss()
        super.touchesBegan(touches, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            sourceHover.dismiss()
        }
    }

    var snippet: SnippetNavigation?
    var typingTask: Task<Void, Never>?
    var typingRequestID = UUID()
    var typingOverlay: UIView?
    var typingList = CompletionList(items: [], prefix: "")
    var typingSignature: LanguageSignature?

    /// The top line to put back after UIKit re-wraps for a new width
    /// (rotation, Split View): its first sizing of the re-wrapped text clamps
    /// the scroll, which threw the reader back to the start of a book.
    private var resizeAnchor: Int?

    override var frame: CGRect {
        get { super.frame }
        set {
            noteWidth(newValue.width)
            super.frame = newValue
        }
    }

    override var bounds: CGRect {
        get { super.bounds }
        set {
            noteWidth(newValue.width)
            super.bounds = newValue
        }
    }

    private func noteWidth(_ width: CGFloat) {
        guard resizeAnchor == nil, width != bounds.width, bounds.width > 0, contentOffset.y > 0,
              let manager = textLayoutManager
        else {
            return
        }
        resizeAnchor = TextKit2Geometry.viewportInsertionOffset(at: containerVisibleRect().origin, in: manager)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let anchor = resizeAnchor, let manager = textLayoutManager {
            resizeAnchor = nil
            TextKit2Geometry.revealByRelocating(
                anchor, in: manager, visible: containerVisibleRect, scroll: scrollContainer, margins: [0],
            )
        }
        positionTypingAssistance()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if markedTextRange == nil, workspace?.serviceReady == true, workspace?.busy == false,
           presses.contains(where: { press in
               press.key?.keyCode == .keyboardF12 &&
                   press.key?.modifierFlags.isDisjoint(with: [.command, .control, .alternate, .shift]) == true
           })
        {
            workspace?.goToDefinition()
            return
        }
        let hadHover = sourceHover.host != nil
        sourceHover.dismiss()
        if hadHover, markedTextRange == nil, presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) {
            return
        }
        if presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) {
            cancelPendingTypingAssistance()
        }
        super.pressesBegan(presses, with: event)
    }

    func clearSnippet() {
        snippet = nil
    }

    func setSnippet(_ value: Snippet, at offset: Int) {
        snippet = SnippetNavigation(value, at: offset)
        if let range = snippet?.current {
            selectedRange = range
            workspace?.selection = range
            reveal(range)
        }
    }

    override func paste(_ sender: Any?) {
        guard isEditable, markedTextRange == nil, let workspace else {
            return
        }
        guard !UIPasteboard.general.hasStrings, let image = UIPasteboard.general.image,
              let data = image.pngData()
        else {
            super.paste(sender)
            return
        }
        let range = selectedRange, source = workspace.text, generation = workspace.generation
        Task {
            guard workspace.generation == generation, workspace.text == source,
                  workspace.selection == range, selectedRange == range, isEditable,
                  markedTextRange == nil
            else {
                return
            }
            do { try await workspace.importAndInsertResources([.image(data)], kind: .image, replacing: range) }
            catch { workspace.message = error.localizedDescription }
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        isEditable && markedTextRange == nil && !session.items.isEmpty
            && session.items.allSatisfy { imageType($0.itemProvider) != nil }
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: any UIDropSession,
    ) -> UIDropProposal {
        UIDropProposal(operation: isEditable && markedTextRange == nil ? .copy : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard isEditable, markedTextRange == nil, let workspace, !workspace.busy else {
            return
        }
        let position = closestPosition(to: session.location(in: self)) ?? selectedTextRange?.start
        guard let position else {
            return
        }
        selectedRange = NSRange(location: offset(from: beginningOfDocument, to: position), length: 0)
        workspace.selection = selectedRange
        let range = selectedRange, source = workspace.text, url = workspace.sourceURL
        let generation = workspace.generation, revision = workspace.version
        let providers = Array(session.items.prefix(12).map(\.itemProvider))
        Task {
            do {
                var inputs: [DocumentResourceInput] = []
                for provider in providers {
                    guard let type = imageType(provider) else {
                        continue
                    }
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        TabletImageLoader.load(from: provider, type: type, continuation: continuation)
                    }
                    inputs.append(.image(data))
                }
                guard workspace.generation == generation, workspace.version == revision,
                      workspace.sourceURL == url, workspace.text == source, workspace.selection == range,
                      self.selectedRange == range, isEditable, markedTextRange == nil
                else {
                    return
                }
                try await workspace.importAndInsertResources(inputs, kind: .image, replacing: range)
            } catch {
                if workspace.generation == generation {
                    workspace.message = error.localizedDescription
                }
            }
        }
    }

    private func imageType(_ provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    override var keyCommands: [UIKeyCommand]? {
        let definitions: [(String, UIKeyModifierFlags, Selector, String)] = [
            (".", .control, #selector(completeSource), "Complete"),
            ("h", [.control, .alternate], #selector(explainSource), "Explain at Cursor"),
            (".", .command, #selector(sourceActions), "Actions at Cursor"),
            ("j", [.control, .command], #selector(definition), "Go to Definition"),
            ("w", .command, #selector(closeSource), "Close Document"),
            ("[", [.control, .command], #selector(back), "Navigate Back"),
            ("]", .command, #selector(indentSource), "Indent"),
            ("[", .command, #selector(outdentSource), "Outdent"),
            ("/", .command, #selector(commentSource), "Toggle Comment"),
            ("f", [.alternate, .shift], #selector(formatSource), "Format Document"),
            ("r", [.control, .command], #selector(repeatCall), "Repeat Previous Call"),
        ]
        var commands = definitions.map { key, flags, selector, title in
            let command = UIKeyCommand(input: key, modifierFlags: flags, action: selector)
            command.discoverabilityTitle = L10n.text(title)
            return command
        }
        // Only visible suggestions take Escape. Pending requests are cancelled in pressesBegan.
        if typingOverlay != nil, markedTextRange == nil {
            let bindings: [(String, Selector)] = [
                (UIKeyCommand.inputEscape, #selector(dismissTypingFromKeyboard)),
                (UIKeyCommand.inputDownArrow, #selector(nextTypingCompletion)),
                (UIKeyCommand.inputUpArrow, #selector(previousTypingCompletion)),
                ("\t", #selector(acceptTypingFromKeyboard)),
            ]
            for (input, action) in bindings where input == UIKeyCommand.inputEscape || typingList.selected != nil {
                let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        if snippet?.current != nil, markedTextRange == nil {
            for flags in [UIKeyModifierFlags(), UIKeyModifierFlags.shift]
                where flags == .shift || typingList.selected == nil
            {
                let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: #selector(nextPlaceholder(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return (super.keyCommands ?? []) + commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if [#selector(dismissTypingFromKeyboard), #selector(nextTypingCompletion),
            #selector(previousTypingCompletion), #selector(acceptTypingFromKeyboard)].contains(action)
        {
            return markedTextRange == nil && isEditable && typingOverlay != nil
        }
        if [#selector(completeSource), #selector(explainSource), #selector(sourceActions), #selector(definition)]
            .contains(action)
        {
            return workspace?.serviceReady == true && workspace?.busy == false && markedTextRange == nil
        }
        if [#selector(indentSource), #selector(outdentSource), #selector(commentSource), #selector(formatSource),
            #selector(nextPlaceholder(_:)), #selector(repeatCall)].contains(action)
        {
            return isEditable && markedTextRange == nil
        }
        if action == #selector(closeSource) {
            return workspace?.document != nil && workspace?.busy == false && markedTextRange == nil
        }
        if action ==
            #selector(back)
        {
            return workspace?.navigationHistory.isEmpty == false && workspace?.busy == false
        }
        if !isEditable, ["undo:", "redo:", "cut:", "paste:", "delete:"].contains(NSStringFromSelector(action)) {
            return false
        }
        if action == #selector(paste(_:)),
           UIPasteboard.general.hasImages
        {
            return isEditable && markedTextRange == nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func completeSource() {
        workspace?.requestAssistance(.completion)
    }

    @objc private func explainSource() {
        workspace?.requestAssistance(.help)
    }

    @objc private func sourceActions() {
        workspace?.requestAssistance(.actions)
    }

    @objc private func definition() {
        workspace?.goToDefinition()
    }

    @objc private func closeSource() {
        Task { await workspace?.closeSource() }
    }

    @objc private func back() {
        workspace?.navigateBack()
    }

    @objc private func indentSource() {
        workspace?.lineAction(.indent)
    }

    @objc private func outdentSource() {
        workspace?.lineAction(.outdent)
    }

    @objc private func commentSource() {
        workspace?.lineAction(.comment)
    }

    @objc private func formatSource() {
        Task { await workspace?.format() }
    }

    @objc private func nextPlaceholder(_ command: UIKeyCommand) {
        guard markedTextRange == nil, isEditable,
              let range = snippet?.move(backward: command.modifierFlags.contains(.shift))
        else {
            return
        }
        selectedRange = range
        workspace?.selection = range
        reveal(range)
    }

    @objc private func repeatCall() {
        Task { await repeatPreviousCall() }
    }
}

struct TabletShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Foundation calls this handler on its own queue. Keep its lexical context
/// outside the main-actor editor, including when compiled by Swift 6.2.
private nonisolated enum TabletImageLoader {
    static func load(
        from provider: NSItemProvider,
        type: String,
        continuation: CheckedContinuation<Data, any Error>,
    ) {
        let completion: @Sendable (Data?, (any Error)?) -> Void = { data, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: DocumentResourceError.invalidImage)
            }
        }
        provider.loadDataRepresentation(forTypeIdentifier: type, completionHandler: completion)
    }
}
