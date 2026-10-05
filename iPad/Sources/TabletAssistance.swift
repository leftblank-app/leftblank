import Combine
import LeftBlankCore
import SwiftUI
import UIKit

@MainActor
final class TabletAssistance: ObservableObject {
    enum Kind { case completion, help, actions }
    struct Snapshot {
        let source: String
        let url: URL
        let version: Int
        let generation: UUID
        let selection: NSRange
    }

    @Published var kind = Kind.help
    @Published var loading = false
    @Published var hover: LanguageHover?
    @Published var signature: LanguageSignature?
    @Published var actions: [SourceCodeAction] = []
    @Published var completions: [SourceCompletion] = []
    var snapshot: Snapshot?
    var task: Task<Void, Never>?
    var requestID = UUID()
    var onInvalidate: (() -> Void)?
    var pendingPreview: Snapshot?

    func invalidate() {
        onInvalidate?()
        task?.cancel()
        task = nil
        requestID = UUID()
        snapshot = nil
        loading = false
        hover = nil
        signature = nil
        actions = []
        completions = []
    }
}

extension TabletWorkspace {
    func assistanceSnapshot() -> TabletAssistance.Snapshot? {
        guard let url = sourceURL, serviceReady, !busy, editor?.markedTextRange == nil else {
            return nil
        }
        return .init(source: text, url: url, version: version, generation: generation, selection: selection)
    }

    func accepts(_ snapshot: TabletAssistance.Snapshot) -> Bool {
        snapshot.url == sourceURL && snapshot.version == version && snapshot.generation == generation
            && snapshot.source == text && snapshot.selection == selection
            && !busy && editor?.markedTextRange == nil
    }

    func requestAssistance(_ kind: TabletAssistance.Kind) {
        if kind == .completion {
            requestTypingAssistance(automatic: false)
            return
        }
        guard let snapshot = assistanceSnapshot(), layout != .preview else {
            return
        }
        assistance.invalidate()
        assistance.kind = kind
        assistance.loading = true
        panel = .assistance
        let request = assistance.requestID
        assistance.task = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let start = TextPosition(offset: snapshot.selection.location, in: snapshot.source)
                let params: [String: Any] = [
                    "textDocument": ["uri": snapshot.url.absoluteString],
                    "position": start.json,
                ]
                var hover: LanguageHover?, signature: LanguageSignature?
                var actions: [SourceCodeAction] = []
                switch kind {
                case .completion: return
                case .help:
                    if client.supports("hoverProvider") {
                        hover = try await LanguageAssistance.hover(client.request("textDocument/hover", params))
                    }
                    if client.supports("signatureHelpProvider"), !Task.isCancelled {
                        signature = try await LanguageAssistance.signatureHelp(client.request(
                            "textDocument/signatureHelp",
                            params,
                        ))
                    }
                case .actions:
                    if client.supports("codeActionProvider") {
                        let end = TextPosition(offset: NSMaxRange(snapshot.selection), in: snapshot.source)
                        let result = try await client.request("textDocument/codeAction", [
                            "textDocument": ["uri": snapshot.url.absoluteString],
                            "range": ["start": start.json, "end": end.json],
                            "context": ["diagnostics": [], "triggerKind": 1],
                        ])
                        actions = LanguageAssistance.codeActions(
                            result,
                            source: snapshot.source,
                            documentURL: snapshot.url,
                            version: snapshot.version,
                        )
                    }
                }
                guard !Task.isCancelled, request == assistance.requestID, accepts(snapshot),
                      panel == .assistance
                else {
                    return
                }
                assistance.snapshot = snapshot
                assistance.hover = hover
                assistance.signature = signature
                assistance.actions = actions
                assistance.loading = false
            } catch {
                guard request == assistance.requestID, accepts(snapshot), !Task.isCancelled else {
                    return
                }
                assistance.loading = false
                message = error.localizedDescription
            }
        }
    }

    func applyCompletion(_ completion: SourceCompletion) {
        guard let snapshot = assistance.snapshot, accepts(snapshot),
              assistance.completions.contains(completion), requireWriting()
        else {
            return
        }
        applyAssistanceEdits(
            completion.edits,
            selection: completion.selections.first ?? NSRange(location: completion.insertionEnd, length: 0),
        )
        if !completion.selections.isEmpty {
            (editor as? TabletTextView)?.setSnippet(Snippet(text: "", selections: completion.selections), at: 0)
        }
    }

    func applyContextAction(_ action: SourceCodeAction) {
        guard let snapshot = assistance.snapshot, accepts(snapshot), assistance.actions.contains(action),
              action.documentURL == sourceURL, action.sourceVersion == version, requireWriting()
        else {
            return
        }
        applyAssistanceEdits(action.edits)
    }

    private func applyAssistanceEdits(_ edits: [TextReplacement], selection: NSRange? = nil) {
        do {
            let updated = try TextEditing.applying(edits, to: text)
            let start = edits.map(\.range.location).min() ?? 0
            let end = edits.map { NSMaxRange($0.range) }.max() ?? start
            let length = end - start + updated.utf16.count - text.utf16.count
            let replacement = (updated as NSString).substring(with: NSRange(location: start, length: length))
            assistance.invalidate()
            (editor as? TabletTextView)?.clearSnippet()
            apply(
                TextReplacement(range: NSRange(location: start, length: end - start), text: replacement),
                restoringSelection: selection,
            )
            panel = nil
            editor?.becomeFirstResponder()
        } catch { message = error.localizedDescription }
    }

    func goToDefinition() {
        guard let snapshot = assistanceSnapshot(), client.supports("definitionProvider") else {
            return
        }
        assistance.invalidate()
        let request = assistance.requestID
        assistance.task = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let origin = TextPosition(offset: snapshot.selection.location, in: snapshot.source)
                let response = try await client.request("textDocument/definition", [
                    "textDocument": ["uri": snapshot.url.absoluteString], "position": origin.json,
                ])
                guard !Task.isCancelled, request == assistance.requestID, accepts(snapshot) else {
                    return
                }
                let destination = response.array.first ?? response
                guard let uri = destination["uri"].string ?? destination["targetUri"].string,
                      let url = URL(string: uri), url.isFileURL,
                      url.host?.isEmpty != false || url.host == "localhost",
                      url.query == nil, url.fragment == nil
                else {
                    requestAssistance(.help)
                    return
                }
                let range = destination["targetSelectionRange"]
                    .isNull ? destination["range"] : destination["targetSelectionRange"]
                guard let line = range["start"]["line"].int, let column = range["start"]["character"].int,
                      line >= 0, column >= 0,
                      let target = SourceLocation(.object(["uri": .string(uri), "selection": range]))
                else {
                    return
                }
                await jump(to: target)
                guard sourceURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else {
                    return
                }
                navigationHistory.append((snapshot.url, origin))
                if navigationHistory.count > 32 {
                    navigationHistory.removeFirst()
                }
            } catch {
                if accepts(snapshot), !Task.isCancelled {
                    message = error.localizedDescription
                }
            }
        }
    }

    func navigateBack() {
        guard let (url, position) = navigationHistory.last, !busy, editor?.markedTextRange == nil,
              let target = SourceLocation(.object([
                  "uri": .string(url.absoluteString),
                  "selection": .object(["start": .object([
                      "line": .number(Double(position.line)), "character": .number(Double(position.character)),
                  ])]),
              ]))
        else {
            return
        }
        Task {
            await jump(to: target)
            if sourceURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath(),
               navigationHistory.last?.0 == url, navigationHistory.last?.1 == position
            {
                navigationHistory.removeLast()
            }
        }
    }

    func revealPreview() {
        guard let snapshot = assistanceSnapshot() else {
            return
        }
        followingPreviewNavigation = false
        assistance.pendingPreview = snapshot
        panel = nil
        if layout == .writing {
            layout = (editor?.bounds.width ?? 0) >= 800 ? .split : .preview
        }
        sendPendingPreviewNavigation()
    }

    func sendPendingPreviewNavigation() {
        guard let snapshot = assistance.pendingPreview else {
            return
        }
        guard snapshot.url == sourceURL, snapshot.version == version, snapshot.generation == generation,
              !followingPreviewNavigation || previewReading.followsWriting
        else {
            assistance.pendingPreview = nil
            return
        }
        guard serviceReady, previewReady, serviceStatus != "Typesetting",
              serviceStatus != "Document Needs Attention"
        else {
            return
        }
        assistance.pendingPreview = nil
        let following = followingPreviewNavigation
        followingPreviewNavigation = false
        let source = snapshot.source as NSString
        let offset = min(snapshot.selection.location, source.length)
        let queryOffset = offset < source.length && source.character(at: offset) != 10 && source
            .character(at: offset) != 13
            ? NSMaxRange(source.rangeOfComposedCharacterSequence(at: offset)) : offset
        let position = TextPosition(offset: queryOffset, in: snapshot.source)
        let start = TextPosition(line: position.line, character: 0).offset(in: snapshot.source)
        let column = source.substring(with: NSRange(location: start, length: queryOffset - start)).utf8.count
        Task {
            do {
                guard snapshot.generation == generation, snapshot.url == sourceURL,
                      snapshot.version == version, !following || previewReading.followsWriting
                else {
                    return
                }
                _ = try await client.command("tinymist.scrollPreview", arguments: ["leftblank", [
                    "event": "panelScrollTo", "filepath": snapshot.url.path,
                    "line": position.line, "character": column,
                ]])
            } catch {
                if snapshot.generation == generation {
                    message = error.localizedDescription
                }
            }
        }
    }
}

struct TabletAssistanceView: View {
    @ObservedObject var workspace: TabletWorkspace
    @ObservedObject private var assistance: TabletAssistance

    init(workspace: TabletWorkspace) {
        self.workspace = workspace
        assistance = workspace.assistance
    }

    var body: some View {
        List {
            if assistance.loading {
                ProgressView().accessibilityLabel(L10n.text("Connecting"))
            } else {
                switch assistance.kind {
                case .completion: EmptyView()
                case .help:
                    if let signature = assistance.signature {
                        Text(signature.label).font(.system(.body, design: .monospaced))
                        if let parameter = signature.activeParameter {
                            Text(L10n.format("Parameter: %@", parameter))
                        }
                        if !signature.parameterDocumentation.isEmpty {
                            Text(signature.parameterDocumentation)
                        }
                        if !signature.documentation.isEmpty {
                            Text(signature.documentation)
                        }
                    }
                    if let hover = assistance.hover {
                        Text(hover.text)
                    }
                    if assistance.hover == nil, assistance.signature == nil {
                        Text(L10n.text("No explanation here yet. Try a function, variable or parameter."))
                    }
                case .actions:
                    if assistance.actions
                        .isEmpty
                    {
                        Text(L10n.text("No changes available here. Try a heading or an equation."))
                    }
                    ForEach(Array(assistance.actions.enumerated()), id: \.offset) { index, action in
                        Button(L10n.text(action.title)) { workspace.applyContextAction(action) }
                            .disabled(!workspace.canWrite).accessibilityIdentifier("context-action-\(index)")
                    }
                }
            }
        }.textSelection(.enabled).accessibilityIdentifier("writing-assistance")
    }
}
