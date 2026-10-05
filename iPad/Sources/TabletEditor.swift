import LeftBlankCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct TabletEditor: UIViewRepresentable {
    @ObservedObject var workspace: TabletWorkspace

    func makeUIView(context: Context) -> UITextView {
        let view = TabletTextView()
        view.workspace = workspace
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
        workspace.assistance.onInvalidate = { [weak view] in view?.dismissTypingAssistance() }
        workspace.editor = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.workspace = workspace
        (view as? TabletTextView)?.workspace = workspace
        workspace.assistance.onInvalidate = { [weak view] in (view as? TabletTextView)?.dismissTypingAssistance() }
        guard view.markedTextRange == nil else {
            return
        }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for:
            .monospacedSystemFont(ofSize: workspace.fontSize, weight: .regular))
        let replaced = view.text != workspace.text
        if replaced {
            (view as? TabletTextView)?.clearSnippet()
            view.text = workspace.text
            view.selectedRange = NSRange(
                location: min(workspace.selection.location, workspace.text.utf16.count),
                length: 0,
            )
        }
        let editable = workspace.canWrite && !workspace.busy && workspace.layout != .preview
        if view.isEditable != editable {
            view.isEditable = editable
            if !editable {
                workspace.assistance.invalidate()
            }
        }
        let syntaxReady = workspace.highlightedText == workspace.text
        let syntaxChanged = syntaxReady && coordinator.styledText != workspace.highlightedText
        guard replaced || coordinator.fontSize != font.pointSize || syntaxChanged else {
            return
        }
        coordinator.fontSize = font.pointSize
        if syntaxReady {
            coordinator.styledText = workspace.highlightedText
        }
        // Recolor on settled syntax revisions, never on caret movement or every
        // keystroke. UIKit preserves composition, typing attributes and undo.
        let storage = view.textStorage
        let selected = view.selectedRange
        storage.beginEditing()
        storage.addAttributes(
            [.foregroundColor: TabletTheme.nativeText, .font: font],
            range: NSRange(location: 0, length: storage.length),
        )
        for token in syntaxReady ? workspace.tokens : [] where NSMaxRange(token.range) <= storage.length {
            let color = TabletTheme.color(for: token)
            storage.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        storage.endEditing()
        view.selectedRange = selected
        view.typingAttributes = [.foregroundColor: TabletTheme.nativeText, .font: font]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var workspace: TabletWorkspace
        var updating = false
        var styledText: String?
        var fontSize: CGFloat = 0
        init(_ workspace: TabletWorkspace) {
            self.workspace = workspace
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard workspace.canWrite, !workspace.busy else {
                return false
            }
            (textView as? TabletTextView)?.snippet?.edit(range, replacement: text)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !updating, textView.markedTextRange == nil else {
                return
            }
            workspace.edited(textView.text, selection: textView.selectedRange)
            (textView as? TabletTextView)?.scheduleTypingAssistance()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else {
                return
            }
            if textView.markedTextRange == nil, textView.text != workspace.text {
                workspace.edited(textView.text, selection: textView.selectedRange)
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
    var snippet: SnippetNavigation?
    var typingTask: Task<Void, Never>?
    var typingRequestID = UUID()
    var typingOverlay: UIView?
    var typingList = CompletionList(items: [], prefix: "")
    var typingSignature: LanguageSignature?

    override func layoutSubviews() {
        super.layoutSubviews()
        positionTypingAssistance()
    }

    func clearSnippet() {
        snippet = nil
    }

    override func selectAll(_ sender: Any?) {
        guard isSelectable, markedTextRange == nil else {
            return
        }
        workspace?.assistance.invalidate()
        dismissTypingAssistance()
        clearSnippet()
        selectedRange = NSRange(location: 0, length: text.utf16.count)
        workspace?.selection = selectedRange
    }

    func setSnippet(_ value: Snippet, at offset: Int) {
        snippet = SnippetNavigation(value, at: offset)
        if let range = snippet?.current {
            selectedRange = range
            workspace?.selection = range
            scrollRangeToVisible(range)
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
            ("[", [.control, .command], #selector(back), "Navigate Back"),
            ("]", .command, #selector(indentSource), "Indent"),
            ("[", .command, #selector(outdentSource), "Outdent"),
            ("/", .command, #selector(commentSource), "Toggle Comment"),
            ("f", [.alternate, .shift], #selector(formatSource), "Format Document"),
        ]
        var commands = definitions.map { key, flags, selector, title in
            let command = UIKeyCommand(input: key, modifierFlags: flags, action: selector)
            command.discoverabilityTitle = L10n.text(title)
            return command
        }
        if isSelectable, markedTextRange == nil {
            // Keep Select All with the source editor when a split preview or
            // an inline completion is also in the responder chain.
            let selectAll = UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:)))
            selectAll.wantsPriorityOverSystemBehavior = true
            commands.append(selectAll)
        }
        if typingOverlay != nil || typingTask != nil || workspace?.assistance.loading == true, markedTextRange == nil {
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
        if action == #selector(selectAll(_:)) {
            return isSelectable && markedTextRange == nil && !text.isEmpty
        }
        if [#selector(dismissTypingFromKeyboard), #selector(nextTypingCompletion),
            #selector(previousTypingCompletion), #selector(acceptTypingFromKeyboard)].contains(action)
        {
            return markedTextRange == nil && isEditable
                && (typingOverlay != nil || typingTask != nil || workspace?.assistance.loading == true)
        }
        if [#selector(completeSource), #selector(explainSource), #selector(sourceActions), #selector(definition)]
            .contains(action)
        {
            return workspace?.serviceReady == true && workspace?.busy == false && markedTextRange == nil
        }
        if [#selector(indentSource), #selector(outdentSource), #selector(commentSource), #selector(formatSource),
            #selector(nextPlaceholder(_:))].contains(action)
        {
            return isEditable && markedTextRange == nil
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
        scrollRangeToVisible(range)
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
