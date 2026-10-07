import AppKit
import Combine
import LeftBlankCore
import UniformTypeIdentifiers

/// Keeps library navigation separate from the live editor buffer. Disk operations
/// run on the library actor; switching documents always passes through Workspace.
@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var cloudEnabled = false
    @Published private(set) var syncMessage = ""
    let store: DocumentLibrary
    private weak var workspace: Workspace?
    private var monitor: LibraryFileMonitor?
    private var cloudQuery: LibraryCloudQuery?
    private var refreshTask: Task<Void, Never>?
    private var started = false
    private var accountMonitor: LibraryAccountMonitor?
    private let locationURL: URL
    private let recentURL: URL
    /// Library documents opened and not yet closed, most recent first; Command-W returns to the next one.
    private(set) var recentDocumentIDs: [UUID]
    static let recentLimit = 50
    var onSyncChange: ((Bool) -> Void)?

    init(
        workspace: Workspace,
        cloudResolver: @escaping DocumentLibrary.CloudResolver = { try LibraryCloudEnvironment.containerURL() },
    ) {
        self.workspace = workspace
        locationURL = workspace.stateDirectory.appendingPathComponent("library-location.json")
        recentURL = workspace.stateDirectory.appendingPathComponent("recent-documents.json")
        recentDocumentIDs = (try? JSONDecoder().decode([UUID].self, from: Data(contentsOf: recentURL))) ?? []
        store = DocumentLibrary(
            rootURL: workspace.stateDirectory.appendingPathComponent("Library"),
            cloudResolver: cloudResolver,
        )
    }

    func start() async {
        guard !started else {
            return
        }
        started = true
        let savedLocation = try? Data(contentsOf: locationURL)
        if savedLocation == Data("icloud".utf8) {
            do { _ = try await store.resumeICloud()
                cloudEnabled = true
                onSyncChange?(true)
            } catch {
                self.error = error.localizedDescription
                // The cached recovery buffer remains open; a stale local backup
                // must never masquerade as the current cloud library.
                started = false
                return
            }
        }
        await refresh()
        if let workspace, let url = workspace.fileURL {
            associate(url)
            if documents.contains(where: { $0.id == workspace.managedDocumentID && $0.trashedAt != nil }) {
                workspace.showLibraryHome()
            }
        } else if let workspace, !workspace.isLibraryHome {
            // One-time adoption of the previous single-draft model.
            do {
                let mark = workspace.stateDirectory.appendingPathComponent(WelcomeDocument.markFilename)
                let assets = (try? Data(contentsOf: mark)).map { [WelcomeDocument.markFilename: $0] } ?? [:]
                try await create(title: L10n.text("Welcome"), text: workspace.text, assets: assets)
            } catch { self.error = error.localizedDescription }
        }
        if savedLocation == nil {
            do { try await setCloudEnabled(true) }
            catch { syncMessage = error.localizedDescription }
        }
        await observeRoot()
        accountMonitor = LibraryAccountMonitor { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncMessage = L10n.text("iCloud account changed. Check sync in Settings.")
                self?.onSyncChange?(false)
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        do {
            documents = try await store.list(includeTrashed: true)
            error = await store.issues.first?.message
            if let workspace, let url = workspace.fileURL {
                associate(url)
            }
        } catch { self.error = error.localizedDescription }
    }

    func associate(_ url: URL) {
        let entry = (workspace?.mainFileURL ?? url).resolvingSymlinksInPath().standardizedFileURL
        let document = documents.first { $0.sourceURL.resolvingSymlinksInPath().standardizedFileURL == entry }
        workspace?.managedDocumentID = document?.id
        workspace?.managedTitle = document?.title
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, workspace?.agentMetadataChangeInProgress != true else {
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do { try await action()
                error = nil
            } catch { self.error = error.localizedDescription
                workspace?.showMessage(error.localizedDescription, persistent: true)
            }
        }
    }

    func create(
        title: String? = nil,
        text: String? = nil,
        template: DocumentTemplate? = nil,
        assets: [String: Data] = [:],
    ) async throws {
        let selected = template ?? .blank
        let content = text ?? selected.source
        let document = try await store.create(
            title: title ?? L10n.text(selected == .codeNotes ? "Code notes" : "Untitled"),
            text: content,
            assets: assets,
        )
        await refresh()
        try await open(document.id)
    }

    func create(builtIn template: BuiltInTemplate) async throws {
        let assets = template == .welcome ? try WelcomeDocument.assets() : [:]
        try await create(
            title: template == .welcome ? L10n.text("Welcome") : nil,
            text: template.source,
            assets: assets,
        )
        if template == .welcome {
            workspace?.layout = .split
        }
    }

    /// A dedicated resolver keeps template downloads independent of the live
    /// document service, including when the library is empty or compilation is busy.
    func create(from package: UniversePackage) async throws {
        guard let workspace, !busy else {
            throw LibraryInteractionError.operationInProgress
        }
        busy = true
        defer { busy = false }
        let staging = workspace.stateDirectory.appendingPathComponent("TemplateDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let client = TinymistClient()
        defer { client.stop() }
        let project = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await client.start(
                root: staging,
                outputDirectory: workspace.stateDirectory.appendingPathComponent("Exports"),
            )
            return try await UniverseTemplateInstaller.materialize(package, using: client, in: staging)
        } onCancel: {
            Task { @MainActor in client.stop() }
        }
        defer { try? FileManager.default.removeItem(at: project.directoryURL) }
        try Task.checkCancellation()
        let document = try await store.importProject(
            at: project.directoryURL,
            mainFile: project.mainFileURL,
            title: package.name,
        )
        await refresh()
        try await open(document.id)
        workspace.recordOperation("library.createTemplate", ["package": package.name, "version": package.version])
    }

    func create(sample: SampleBook, using suppliedStore: SampleBookStore? = nil) async throws {
        guard let workspace, !busy else {
            throw LibraryInteractionError.operationInProgress
        }
        busy = true
        defer { busy = false }
        let books = suppliedStore ??
            SampleBookStore(cacheURL: workspace.stateDirectory.appendingPathComponent("SampleBooks"))
        let project = try await books.materialize(
            sample,
            in: workspace.stateDirectory.appendingPathComponent("SampleDownloads"),
        )
        defer { try? FileManager.default.removeItem(at: project.directoryURL) }
        try Task.checkCancellation()
        let document = try await store.importProject(
            at: project.directoryURL,
            mainFile: project.mainFileURL,
            title: sample.title,
        )
        await refresh()
        try await open(document.id)
        workspace.recordOperation("library.createExample", ["book": sample.rawValue])
    }

    func open(_ id: UUID) async throws {
        guard let workspace else {
            return
        }
        let result = try await store.read(id)
        guard result.document.trashedAt == nil else {
            throw LibraryInteractionError.restoreFirst
        }
        guard workspace.open(result.document.sourceURL) else {
            throw LibraryInteractionError.couldNotOpen
        }
        workspace.managedDocumentID = result.document.id
        workspace.managedTitle = result.document.title
        noteOpened(result.document.id)
        workspace.onTitleChange?(workspace.title)
        workspace.libraryOpen = false
    }

    func noteOpened(_ id: UUID) {
        guard recentDocumentIDs.first != id else {
            return
        }
        updateRecent { $0 = [id] + $0.filter { $0 != id } }
    }

    func forgetRecent(_ id: UUID) {
        updateRecent { $0.removeAll { $0 == id } }
    }

    /// Recently opened documents that can still be reopened, most recent first.
    var reopenableRecentIDs: [UUID] {
        let available = Set(documents.filter { !$0.isTrashed }.map(\.id))
        return recentDocumentIDs.filter { available.contains($0) }
    }

    /// Opens the first recent document that still reads; unreadable entries are dropped.
    func reopenRecent(_ candidates: [UUID]) async -> Bool {
        for id in candidates {
            do { try await open(id)
                return true
            } catch {
                workspace?.recordOperation("library.reopenFailed", ["documentID": id.uuidString])
                forgetRecent(id)
            }
        }
        return false
    }

    private func updateRecent(_ change: (inout [UUID]) -> Void) {
        let previous = recentDocumentIDs
        change(&recentDocumentIDs)
        recentDocumentIDs = Array(recentDocumentIDs.prefix(Self.recentLimit))
        guard recentDocumentIDs != previous else {
            return
        }
        do { try JSONEncoder().encode(recentDocumentIDs).write(to: recentURL, options: .atomic) }
        catch { workspace?.recordOperation("library.recentFailed", ["error": error.localizedDescription]) }
    }

    func rename(_ id: UUID, title: String) async throws {
        _ = try await store.rename(id, title: title)
        await refresh()
        if workspace?.managedDocumentID == id, let workspace {
            workspace.onTitleChange?(workspace.title)
        }
        workspace?.recordOperation("library.rename", ["documentID": id.uuidString])
    }

    func moveToTrash(_ id: UUID) async throws {
        guard let workspace else {
            return
        }
        let wasActive = workspace.managedDocumentID == id
        if wasActive {
            workspace.documentTransitionInProgress = true
            workspace.editor?.isEditable = false
        }
        defer {
            if wasActive {
                workspace.documentTransitionInProgress = false
                workspace.editor?.isEditable = workspace.editorIsEditable
            }
        }
        if wasActive {
            workspace.save()
            guard workspace.text == workspace.savedText else {
                throw LibraryInteractionError.saveFirst
            }
        }
        _ = try await store.trash(id)
        forgetRecent(id)
        workspace.recordOperation("library.trash", ["documentID": id.uuidString, "active": String(wasActive)])
        await refresh()
        if wasActive {
            // Clear the trashed buffer first, so an unavailable replacement can
            // safely leave the library open without editing a trashed document.
            workspace.showLibraryHome()
            if let next = reopenableRecentIDs.first ?? documents.first(where: { $0.trashedAt == nil })?.id {
                try await open(next)
                workspace.libraryOpen = true
            }
        }
    }

    func restore(_ id: UUID) async throws {
        _ = try await store.restore(id)
        await refresh()
        workspace?.recordOperation("library.restore", ["documentID": id.uuidString])
    }

    func confirmEmptyTrash() {
        guard let owner = workspace?.window ?? workspace?.editor?.window else {
            return
        }
        let window = owner.attachedSheet ?? owner
        guard window.attachedSheet == nil else {
            return
        }
        perform { [self] in
            let snapshot = try await store.trashSnapshot()
            guard !snapshot.isEmpty else {
                await refresh()
                return
            }
            let alert = NSAlert()
            alert.messageText = L10n.text("Empty Trash?")
            alert.informativeText = L10n.format(
                "Permanently delete %d documents and their attachments? This cannot be undone.",
                snapshot.count,
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.text("Cancel"))
            alert.addButton(withTitle: L10n.text("Empty Trash"))
            alert.buttons[1].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, let self else {
                    return
                }
                perform { try await self.emptyTrash(snapshot) }
            }
        }
    }

    func emptyTrash(_ snapshot: LibraryTrashSnapshot) async throws {
        let result = try await store.emptyTrash(snapshot)
        await refresh()
        workspace?.recordOperation(
            "library.emptyTrash",
            ["deleted": String(result.deletedCount), "failed": String(result.issues.count)],
        )
        if let issue = result.issues.first {
            throw CommandError.invalid(L10n.format(
                "%d documents deleted. Some items could not be removed: %@",
                result.deletedCount,
                issue.message,
            ))
        }
    }

    func importDocument(_ url: URL) async throws {
        let document = try await store.importDocument(at: url)
        await refresh()
        try await open(document.id)
    }

    func importProject(_ folder: URL, mainFile: URL) async throws {
        let document = try await store.importProject(at: folder, mainFile: mainFile)
        await refresh()
        try await open(document.id)
    }

    func importPanel(project: Bool = false) {
        guard let owner = workspace?.window ?? workspace?.editor?.window else {
            return
        }
        let window = owner.attachedSheet ?? owner
        guard window.attachedSheet == nil else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.text(project ? "Import project folder" : "Import a document")
        panel.canChooseDirectories = project
        panel.canChooseFiles = !project
        panel.allowsMultipleSelection = false
        if !project {
            panel.allowedContentTypes = [UTType(filenameExtension: "typ") ?? .plainText]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            if project {
                chooseProjectEntry(in: url, window: window)
            } else {
                perform { try await self.importDocument(url) }
            }
        }
    }

    private func chooseProjectEntry(in folder: URL, window: NSWindow) {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose the project's main document")
        panel.directoryURL = folder
        panel.allowedContentTypes = [UTType(filenameExtension: "typ") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let mainFile = panel.url, let self else {
                return
            }
            perform { try await self.importProject(folder, mainFile: mainFile) }
        }
    }

    func exportProject(_ id: UUID, to destination: URL) async throws {
        if workspace?.managedDocumentID == id {
            workspace?.save()
            guard workspace?.text == workspace?.savedText else {
                throw LibraryInteractionError.saveFirst
            }
        }
        try await store.exportProject(id, to: destination)
    }

    func exportPanel(_ document: LibraryDocument) {
        guard let owner = workspace?.window ?? workspace?.editor?.window else {
            return
        }
        let window = owner.attachedSheet ?? owner
        guard window.attachedSheet == nil else {
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("Export source project")
        panel.nameFieldStringValue = document.title
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            perform { try await self.exportProject(document.id, to: url) }
        }
    }

    func setCloudEnabled(_ enabled: Bool) async throws {
        guard let workspace else {
            return
        }
        guard !workspace.agentMetadataChangeInProgress else {
            throw AgentToolError("busy", "An agent is updating the document library. Try again after it finishes.")
        }
        if enabled == cloudEnabled {
            try Data(enabled ? "icloud".utf8 : "local".utf8).write(to: locationURL, options: .atomic)
            return
        }
        if workspace.fileURL != nil {
            workspace.save()
        }
        guard workspace.fileURL == nil || workspace.text == workspace.savedText
        else {
            throw LibraryInteractionError.saveFirst
        }
        let currentID = workspace.managedDocumentID
        workspace.documentTransitionInProgress = true
        workspace.editor?.isEditable = false
        defer {
            workspace.documentTransitionInProgress = false
            workspace.editor?.isEditable = workspace.editorIsEditable
        }
        let report = try await store.setICloudEnabled(enabled)
        updateRecent { $0 = $0.map { report.idMappings[$0] ?? $0 } }
        cloudEnabled = report.isICloud
        try Data(enabled ? "icloud".utf8 : "local".utf8).write(to: locationURL, options: .atomic)
        onSyncChange?(enabled)
        syncMessage = enabled ? L10n.text("iCloud Drive manages uploads and downloads.") : L10n
            .text("Saved on this Mac")
        await refresh()
        await observeRoot()
        if let currentID {
            try await open(report.idMappings[currentID] ?? currentID)
        }
    }

    private func observeRoot() async {
        monitor?.stop()
        cloudQuery = nil
        let root = await store.rootURL
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                refreshTask?.cancel()
                refreshTask = Task {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    await self.refresh()
                    await self.workspace?.refreshFromLibrary()
                }
            }
        }
        monitor = LibraryFileMonitor(rootURL: root, onChange: changed)
        if cloudEnabled {
            cloudQuery = LibraryCloudQuery(rootURL: root, onChange: changed)
        }
    }

    func stop() {
        refreshTask?.cancel()
        monitor?.stop()
        monitor = nil
        accountMonitor = nil
        cloudQuery = nil
    }
}

enum LibraryInteractionError: LocalizedError {
    case saveFirst
    case restoreFirst
    case couldNotOpen
    case operationInProgress
    var errorDescription: String? {
        switch self {
        case .operationInProgress: L10n.text("Another library operation is in progress. Try again in a moment.")
        case .saveFirst: L10n.text("Resolve the current save conflict before continuing.")
        case .restoreFirst: L10n.text("Restore this document from Trash before opening it.")
        case .couldNotOpen: L10n.text("The document could not be opened. Your current writing is preserved.")
        }
    }
}
