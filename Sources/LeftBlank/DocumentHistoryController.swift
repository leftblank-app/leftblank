import AppKit
import Combine
import LeftBlankCore

@MainActor
final class DocumentHistoryController: ObservableObject {
    @Published private(set) var revisions: [DocumentRevision] = []
    @Published private(set) var comparison: HistoryComparison?
    @Published private(set) var selectedID: UUID?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    let store: DocumentHistory
    var now: () -> Date = Date.init
    private weak var workspace: Workspace?
    private var pending: (key: String, previous: String)?
    private var tail: Task<Void, Never>?
    private var request = UUID()
    private var pendingWrites = 0
    var hasPendingWrites: Bool {
        pendingWrites > 0
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        store = DocumentHistory(root: workspace.stateDirectory.appendingPathComponent("History"))
    }

    /// A Swift String value shares storage until edited. Only the first change
    /// in an autosave batch captures a baseline; typing does no I/O or hashing.
    func willEdit(previous: String) {
        guard pending == nil, let workspace, !workspace.isLibraryHome else {
            return
        }
        pending = (workspace.historyKey, previous)
    }

    func flush(current: String) {
        guard let pending, let workspace else {
            return
        }
        self.pending = nil
        let previousTask = tail, store = store, date = now(), interval = workspace.historyInterval
        pendingWrites += 1
        tail = Task { [weak self] in
            defer { self?.pendingWrites -= 1 }
            await previousTask?.value
            do {
                _ = try await store.recordEdit(
                    key: pending.key,
                    previous: pending.previous,
                    current: current,
                    at: date,
                    interval: interval,
                )
            } catch {
                guard let self else {
                    return
                }
                self.error = error.localizedDescription
                self.workspace?.recordOperation("history.failed", ["error": error.localizedDescription])
                self.workspace?.showMessage(
                    L10n.text("Could not save a history snapshot. Your document remains open."),
                    persistent: true,
                )
            }
        }
    }

    func drain() async {
        await tail?.value
    }

    func cancelPresentation() {
        request = UUID()
        busy = false
    }

    func load() async {
        guard let workspace, !workspace.isLibraryHome else {
            return
        }
        let key = workspace.historyKey, token = UUID()
        request = token
        busy = true
        error = nil
        comparison = nil
        selectedID = nil
        flush(current: workspace.text)
        await drain()
        do {
            let result = try await store.revisions(for: key)
            guard request == token, workspace.historyKey == key else {
                return
            }
            revisions = result
            busy = false
            if let first = result.first {
                await select(first)
            }
        } catch {
            if request == token {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    func select(_ revision: DocumentRevision) async {
        guard let workspace else {
            return
        }
        let key = workspace.historyKey, source = workspace.text, version = workspace.revision, token = UUID()
        request = token
        busy = true
        error = nil
        selectedID = revision.id
        comparison = nil
        do {
            let old = try await store.source(for: revision, key: key)
            let result = await Task.detached(priority: .utility) { HistoryComparison(before: old, after: source) }.value
            guard request == token, workspace.historyKey == key else {
                return
            }
            guard workspace.revision == version else {
                throw HistoryError.changed
            }
            comparison = result
        } catch {
            if request == token {
                self.error = error.localizedDescription
            }
        }
        if request == token {
            busy = false
        }
    }

    @discardableResult
    func restore(_ revision: DocumentRevision) async -> Bool {
        guard let workspace, workspace.canEditSource else {
            return false
        }
        let key = workspace.historyKey, source = workspace.text, version = workspace.revision
        busy = true
        error = nil
        defer { busy = false }
        do {
            flush(current: source)
            await drain()
            let restored = try await store.source(for: revision, key: key)
            guard source != restored else {
                return true
            }
            try await store.preserveBeforeRestore(source, key: key, at: now())
            guard workspace.historyKey == key, workspace.revision == version else {
                throw HistoryError.changed
            }
            if let editor = workspace.editor {
                editor.insertSnippet(
                    Snippet(text: restored),
                    replacing: NSRange(location: 0, length: source.utf16.count),
                )
                editor.undoManager?.setActionName(L10n.text("Restore Snapshot"))
            } else {
                workspace.edited(restored)
            }
            workspace.historyOpen = false
            workspace.recordOperation("history.restored")
            workspace
                .showMessage(L10n
                    .text(
                        "Snapshot restored. Your previous writing is saved in history, and you can undo this change.",
                    ))
            return true
        } catch {
            self.error = error.localizedDescription
            workspace.recordOperation("history.restoreFailed", ["error": error.localizedDescription])
            return false
        }
    }
}

extension Workspace {
    var historyKey: String {
        if let id = managedDocumentID {
            let root = compilationURL.deletingLastPathComponent().standardizedFileURL.path + "/"
            let path = documentURL.standardizedFileURL.path
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : "external:" + documentURL
                .resolvingSymlinksInPath().standardizedFileURL.absoluteString
            return "library:\(id.uuidString)/\(relative)"
        }
        return documentURL.resolvingSymlinksInPath().standardizedFileURL.absoluteString
    }

    func openHistory() {
        guard !isLibraryHome else {
            return
        }
        closePalette()
        historyOpen = true
    }
}
