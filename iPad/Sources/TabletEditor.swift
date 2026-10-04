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
        workspace.editor = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.workspace = workspace
        (view as? TabletTextView)?.workspace = workspace
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
        }
    }
}

@MainActor final class TabletTextView: UITextView, UIDropInteractionDelegate {
    weak var workspace: TabletWorkspace?
    var snippet: SnippetNavigation?

    func clearSnippet() {
        snippet = nil
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
                        Self.loadImageData(from: provider, type: type, continuation: continuation)
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

    /// Foundation invokes the callback on its own queue. Construct it outside the
    /// main actor so strict concurrency checks cannot inherit the editor's isolation.
    private nonisolated static func loadImageData(
        from provider: NSItemProvider,
        type: String,
        continuation: CheckedContinuation<Data, any Error>,
    ) {
        provider.loadDataRepresentation(forTypeIdentifier: type) { @Sendable data, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: DocumentResourceError.invalidImage)
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
        if snippet?.current != nil, markedTextRange == nil {
            for flags in [UIKeyModifierFlags(), UIKeyModifierFlags.shift] {
                let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: #selector(nextPlaceholder(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return (super.keyCommands ?? []) + commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
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

struct TabletPreview: UIViewRepresentable {
    @AppStorage("iPadPreviewDark") private var previewDark = false
    @ObservedObject var workspace: TabletWorkspace
    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "leftblankPreviewReady")
        config.userContentController.add(context.coordinator, name: "leftblankPreviewError")
        config.userContentController.addUserScript(WKUserScript(
            source: PreviewScripts.setup(
                canvas: scheme == .dark ? "#171a1d" : "#fafafa",
                scheme: scheme == .dark ? "dark" : "light",
            ),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true,
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: """
            const report = error => window.webkit.messageHandlers.leftblankPreviewError.postMessage(String(error).slice(0, 400));
            window.addEventListener('error', event => report(event.message));
            window.addEventListener('unhandledrejection', event => report(event.reason));
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true,
        ))
        let view = TabletPreviewWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = TabletTheme.nativeEditor
        view.accessibilityLabel = L10n.text("Document Preview")
        view.accessibilityIdentifier = "document-preview"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.workspace = workspace
        if context.coordinator.url != workspace.previewURL {
            context.coordinator.url = workspace.previewURL
            if let url = workspace.previewURL {
                view.load(URLRequest(url: url))
            } else {
                view.loadHTMLString("", baseURL: nil)
            }
        }
        if !view.isLoading {
            let dark = scheme == .dark
            view.evaluateJavaScript(
                "window.leftblankSetChrome?.('\(dark ? "#171a1d" : "#fafafa")', '\(dark ? "dark" : "light")'); window.leftblankSetDark?.(\(previewDark ? "true" : "false"));",
                completionHandler: nil,
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewReady")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewError")
        view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var workspace: TabletWorkspace
        var url: URL?
        private var recovered = false
        init(_ workspace: TabletWorkspace) {
            self.workspace = workspace
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.port == url?.port else {
                return
            }
            if message.name == "leftblankPreviewReady" {
                workspace.previewReady = true
                workspace.previewIssue = nil
                workspace.sendPendingPreviewNavigation()
            } else if let error = message.body as? String {
                workspace.previewIssue = error
            }
        }

        func webView(
            _ view: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error,
        ) {
            workspace.previewIssue = error.localizedDescription
        }

        func webView(_ view: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            workspace.previewIssue = error.localizedDescription
        }

        func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
            if !recovered {
                recovered = true
                view.reload()
            } else {
                workspace.previewIssue = L10n.text("Preview stopped unexpectedly. Reconnect typesetting to try again.")
            }
        }
    }
}

@MainActor final class TabletPreviewWebView: WKWebView {
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, lastSize != bounds.size else {
            return
        }
        lastSize = bounds.size
        // Hidden panes begin with no viewport; resizing must refit the actual
        // SVG page when preview is revealed or the iPad window changes size.
        evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
    }
}

struct TabletShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
