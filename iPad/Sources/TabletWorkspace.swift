import Combine
import Foundation
import LeftBlankCore
import UIKit

@MainActor
final class TabletWorkspace: ObservableObject {
    enum Layout: String, CaseIterable { case writing, split, preview }
    enum Panel: String,
        Identifiable
    { case commands, outline, checks, history, settings, universe, trash, subscription, files,
           projectEntry, assistance, objectEditor
        var id: String {
            rawValue
        }
    }

    @Published var objectEditSession: ObjectEditSession?
    let previewReading = PreviewReadingSession()
    var previewFollowTask: Task<Void, Never>?
    var followingPreviewNavigation = false
    var previewReturnLayout: Layout?
    @Published var previewZoom: CGFloat = 1
    @Published var trashedDocuments: [LibraryDocument] = []
    @Published var documents: [LibraryDocument] = []
    @Published var document: LibraryDocument?
    @Published var activeSourceURL: URL?
    @Published var projectSources: [URL] = []
    @Published var importSources: [URL] = []
    private var pendingProjectURL: URL?
    private var pendingProjectAccess = false
    var sourceURL: URL? {
        activeSourceURL ?? document?.sourceURL
    }

    var entryURL: URL? {
        document?.sourceURL
    }

    var resourceRoot: URL? {
        document?.folderURL
    }

    var historyKey: String? {
        guard let document, let sourceURL else {
            return nil
        }
        return try? ProjectSources.historyKey(
            documentID: document.id, source: sourceURL, entry: document.sourceURL, root: document.folderURL,
        )
    }

    var navigationHistory: [(URL, TextPosition)] = []
    let assistance = TabletAssistance()
    @Published var historyInterval = HistoryInterval(
        rawValue: UserDefaults.standard.string(forKey: "iPadHistoryInterval") ?? "hourly",
    ) ?? .hourly {
        didSet { UserDefaults.standard.set(historyInterval.rawValue, forKey: "iPadHistoryInterval") }
    }

    @Published var text = "" {
        didSet { metrics = DocumentMetrics(text) }
    }

    private(set) var metrics = DocumentMetrics("")
    @Published var selection = NSRange(location: 0, length: 0) {
        didSet {
            if selection != oldValue {
                schedulePreviewFollow()
            }
        }
    }

    @Published var layout: Layout = .split {
        didSet {
            if layout != oldValue {
                assistance.invalidate()
            }
            if layout != .split {
                previewFollowTask?.cancel()
            }
        }
    }

    @Published var panel: Panel? {
        didSet {
            if panel != nil, panel != .assistance {
                assistance.invalidate()
            }
        }
    }

    @Published var previewURL: URL?
    @Published var previewReady = false
    @Published var previewIssue: String?
    @Published var serviceReady = false
    @Published var serviceStatus = "Connecting"
    @Published var saveStatus = "Saved"
    @Published var message: String?
    @Published var busy = false {
        didSet {
            if busy {
                assistance.invalidate()
                previewFollowTask?.cancel()
            }
        }
    }

    @Published var revisions: [DocumentRevision] = []
    @Published var outline: [JSONValue] = []
    @Published var diagnostics: [JSONValue] = []
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "iPadEditorFontSize") as? Double ?? 15 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "iPadEditorFontSize") }
    }

    @Published var highlightedText = ""
    @Published var tokens: [HighlightToken] = []
    @Published var shareURL: URL?
    @Published private(set) var canWrite = false
    let subscription: TabletSubscription
    private var subscriptionObserver: AnyCancellable?
    @Published var cloudEnabled = false
    weak var editor: UITextView?
    let stateDirectory: URL
    let library: DocumentLibrary
    let history: DocumentHistory
    let client = TinymistClient(makeTransport: { EmbeddedTinymist() })
    var baseline: DiskBaseline?
    var savedText = ""
    var version = 1
    var generation = UUID()
    private var debounce: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var started = false
    var changing = false
    let exportDirectory: URL
    let recoveryURL: URL

    init(
        subscription: TabletSubscription = TabletSubscription(),
        sessionID: UUID = UUID(),
        stateDirectory: URL = AppDistribution.defaultStateDirectory,
    ) {
        self.stateDirectory = stateDirectory
        library = DocumentLibrary(rootURL: stateDirectory.appendingPathComponent("Library"))
        history = TabletWindowRegistry.windows(in: stateDirectory).first?.history
            ?? DocumentHistory(root: stateDirectory.appendingPathComponent("History"))
        recoveryURL = stateDirectory.appendingPathComponent("iPadRecovery-\(sessionID).json")
        exportDirectory = stateDirectory.appendingPathComponent("Exports").appendingPathComponent(sessionID.uuidString)
        self.subscription = subscription
        TabletWindowRegistry.register(self)
        subscriptionObserver = subscription.$access.sink { [weak self] access in
            guard let self else {
                return
            }
            let allowed = access.permitsWriting(at: Date())
            if canWrite, !allowed {
                commitComposition()
            }
            canWrite = allowed
            editor?.isEditable = allowed && !busy && layout != .preview
        }
    }

    @discardableResult
    func requireWriting() -> Bool {
        guard subscription.canWrite else {
            panel = .subscription
            return false
        }
        return true
    }

    func start() async {
        guard !started else {
            return
        }
        started = true
        do {
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true,
            )
            let legacy = stateDirectory.appendingPathComponent("iPadRecovery.json")
            if !FileManager.default.fileExists(atPath: recoveryURL.path),
               FileManager.default.fileExists(atPath: legacy.path)
            {
                try FileManager.default.moveItem(at: legacy, to: recoveryURL)
            }
            if UserDefaults.standard.object(forKey: "iPadCloudEnabled") == nil || UserDefaults.standard
                .bool(forKey: "iPadCloudEnabled")
            {
                _ = try? await library.resumeICloud()
            }
            cloudEnabled = await library.isICloud
            try await reloadLibrary()
            if documents.isEmpty {
                let item = try await library.create(
                    title: BuiltInTemplate.welcome.title,
                    text: BuiltInTemplate.welcome.source,
                    assets: WelcomeDocument.assets(),
                )
                try await reloadLibrary()
                await open(item)
                // Opening Welcome creates this scene's recovery file. It is not
                // a previous session to reopen and start a second engine for.
                return
            }
            if let data = try? Data(contentsOf: recoveryURL),
               let snapshot = try? JSONDecoder().decode(RecoverySnapshot.self, from: data),
               let file = snapshot.fileURL,
               let item = documents.first(where: {
                   $0.sourceURL == (snapshot.mainFileURL ?? file)
               })
            {
                if snapshot.text != snapshot.savedText {
                    // Copy the complete project so recovered chapters retain their assets.
                    let relative = try ProjectSources.relativePath(of: file, in: item.folderURL)
                    let recovered = try await library.importProject(
                        at: item.folderURL, mainFile: item.sourceURL, title: L10n.text("Recovered Draft"),
                    )
                    let recoveredSource = recovered.folderURL.appendingPathComponent("Project")
                        .appendingPathComponent(relative)
                    let disk = try DocumentStorage.read(recoveredSource).1
                    _ = try DocumentStorage.write(snapshot.text, to: recoveredSource, baseline: disk)
                    try await reloadLibrary()
                    await open(recovered)
                    await openSource(recoveredSource)
                } else {
                    await open(item)
                    await openSource(file)
                }
                jump(metrics.position(at: min(snapshot.selection, text.utf16.count)))
            }
        } catch { message = error.localizedDescription }
    }

    func reloadLibrary() async throws {
        documents = try await library.list()
    }

    func open(_ item: LibraryDocument) async {
        guard !changing else {
            return
        }
        commitComposition()
        changing = true
        defer { changing = false }
        busy = true
        defer { busy = false }
        guard await save() else {
            return
        }
        do {
            let result = try await library.read(item.id)
            // Repair starter documents created before iPad copied their mark.
            // Keep user edits and any existing asset intact.
            if result.text.hasPrefix("// A LeftBlank original."),
               result.text.contains("image(\"" + WelcomeDocument.markFilename + "\"")
            {
                try WelcomeDocument.prepareAssets(in: result.document.folderURL)
            }
            let sources = try ProjectSources.list(in: result.document.folderURL)
            generation = UUID()
            debounce?.cancel()
            client.stop()
            previewFollowTask?.cancel()
            previewReading.reset()
            previewReturnLayout = nil
            followingPreviewNavigation = false
            document = result.document
            activeSourceURL = result.document.sourceURL
            projectSources = sources
            navigationHistory = []
            assistance.invalidate()
            (editor as? TabletTextView)?.clearSnippet()
            text = result.text
            savedText = text
            baseline = result.baseline
            selection = NSRange(location: 0, length: 0)
            version = 1
            tokens = []
            highlightedText = ""
            revisions = []
            outline = []
            diagnostics = []
            previewURL = nil
            previewReady = false
            previewIssue = nil
            serviceReady = false
            saveStatus = "Saved"
            editor?.undoManager?.removeAllActions()
            editor?.text = text
            editor?.selectedRange = selection
            persistRecovery()
            await connect()
        } catch { message = error.localizedDescription }
    }

    func connect() async {
        guard let document, let sourceURL else {
            return
        }
        let session = generation
        serviceStatus = "Connecting"
        client.onShowDocument = { [weak self] params in
            guard let self, generation == session, let target = SourceLocation(params) else {
                return
            }
            previewReturnLayout = layout
            previewReading.rememberReturnPosition()
            Task { await self.jump(to: target) }
        }
        client.onDisconnect = { [weak self] error in
            guard let self, generation == session else {
                return
            }
            serviceReady = false
            message = error
        }
        client.onNotification = { [weak self] method, params in
            guard let self, generation == session else {
                return
            }
            if method == "textDocument/publishDiagnostics",
               params["uri"].string == self.sourceURL?.absoluteString
            {
                diagnostics = params["diagnostics"].array
            }
            if method == "tinymist/compileStatus" || method == "tinymist/status" {
                switch params["status"].string {
                case "compiling": serviceStatus = "Typesetting"
                case "compileSuccess": serviceStatus = "Preview Updated"
                    sendPendingPreviewNavigation()
                case "compileError": serviceStatus = "Document Needs Attention"
                default: break
                }
            }
        }
        do {
            let exports = exportDirectory
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            try await client.start(
                root: document.folderURL,
                outputDirectory: exports,
                fontPaths: [EmbeddedTinymist.fontCacheURL],
            )
            guard generation == session else {
                return
            }
            try client.open(sourceURL, text: text, version: version)
            if sourceURL != document.sourceURL {
                let entryText = try DocumentStorage.read(document.sourceURL).0
                try client.open(document.sourceURL, text: entryText, version: 1)
            }
            serviceReady = true
            serviceStatus = "Ready"
            previewURL = try await client.startPreview(document.sourceURL)
            guard generation == session else {
                return
            }
            await refresh()
        } catch {
            guard generation == session else {
                return
            }
            serviceReady = false
            serviceStatus = "Unavailable"
            message = error.localizedDescription
        }
    }

    func edited(_ source: String, selection: NSRange) {
        guard canWrite else {
            return
        }
        self.selection = selection
        guard source != text else {
            return
        }
        let previous = text
        text = source
        version += 1
        schedulePreviewFollow()
        assistance.invalidate()
        saveStatus = "Saving"
        persistRecovery()
        if let sourceURL, let historyKey {
            let interval = historyInterval
            Task {
                do { try await history.recordEdit(
                    key: historyKey,
                    previous: previous,
                    current: source,
                    at: Date(),
                    interval: interval,
                ) } catch { message = error.localizedDescription }
            }
            if serviceReady {
                do {
                    serviceStatus = "Typesetting"
                    try client.change(sourceURL, text: source, version: version)
                } catch { message = error.localizedDescription }
            }
        }
        debounce?.cancel()
        let session = generation
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, generation == session else {
                return
            }
            await save()
            await refresh()
        }
    }

    func commitComposition() {
        guard let editor, editor.markedTextRange != nil else {
            return
        }
        editor.unmarkText()
        edited(editor.text, selection: editor.selectedRange)
    }

    func persistRecovery() {
        let snapshot = RecoverySnapshot(
            fileURL: sourceURL,
            text: text,
            savedText: savedText,
            selection: selection.location,
            mainFileURL: entryURL,
        )
        do { try JSONEncoder().encode(snapshot).write(to: recoveryURL, options: .atomic) }
        catch { message = error.localizedDescription }
    }

    @discardableResult
    func save() async -> Bool {
        guard let document, let sourceURL else {
            return true
        }
        let session = generation
        let previousTask = saveTask
        let source = text
        let task = Task { [self] in
            _ = await previousTask?.value
            guard self.document?.id == document.id, generation == session, self.sourceURL == sourceURL else {
                return true
            }
            guard savedText != source else {
                return true
            }
            do {
                if sourceURL == document.sourceURL {
                    let result = try await library.save(document.id, text: source, baseline: baseline)
                    baseline = result.baseline
                } else {
                    _ = try ProjectSources.relativePath(of: sourceURL, in: document.folderURL)
                    baseline = try DocumentStorage.write(source, to: sourceURL, baseline: baseline)
                }
                savedText = source
                saveStatus = text == source ? "Saved" : "Saving"
                persistRecovery()
                try await reloadLibrary()
                return true
            } catch {
                saveStatus = "Save Needs Attention"
                message = error.localizedDescription
                return false
            }
        }
        saveTask = task
        return await task.value
    }

    func refresh() async {
        guard let sourceURL, serviceReady else {
            return
        }
        let session = generation, revision = version, source = text
        do {
            async let symbols = client.request(
                "textDocument/documentSymbol",
                ["textDocument": ["uri": sourceURL.absoluteString]],
            )
            let response = try await client.request(
                "textDocument/semanticTokens/full",
                ["textDocument": ["uri": sourceURL.absoluteString]],
            )
            let result = SemanticHighlighting.decode(
                response["data"].array.compactMap(\.int),
                source: source,
                types: client.semanticTokenTypes,
                modifiers: client.semanticTokenModifiers,
            )
            let headings = try await symbols
            guard session == generation, revision == version else {
                return
            }
            tokens = result
            highlightedText = source
            outline = headings.array
        } catch { /* Retain the last valid outline and coloring while editing. */ }
    }

    func create(_ template: BuiltInTemplate) async {
        guard requireWriting(), !busy else {
            return
        }
        do {
            let item = try await library.create(
                title: template.title,
                text: template.source,
                assets: template == .welcome ? WelcomeDocument.assets() : [:],
            )
            try await reloadLibrary()
            if panel == .universe {
                panel = nil
            }
            await open(item)
        } catch { message = error.localizedDescription }
    }

    func importDocument(_ url: URL) async {
        guard requireWriting() else {
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let item = try await library.importDocument(at: url)
            try await reloadLibrary()
            await open(item)
        } catch { message = error.localizedDescription }
    }

    func rename(_ title: String) async {
        guard let document else {
            return
        }
        do { self.document = try await library.rename(document.id, title: title)
            try await reloadLibrary()
        } catch { message = error.localizedDescription }
    }

    func compiledPDF() async throws -> URL {
        guard let document, let sourceURL, serviceReady else {
            throw ServiceError.remote(L10n.text("Waiting for Typesetting"))
        }
        let session = generation, revision = version
        try client.change(sourceURL, text: text, version: version)
        let response = try await client.command("tinymist.exportPdf", arguments: [document.sourceURL.path])
        guard session == generation, revision == version else {
            throw CancellationError()
        }
        guard let path = response["path"].string else {
            throw ServiceError.remote(
                L10n.text("The document cannot be compiled. Resolve the errors before exporting."),
            )
        }
        let url = URL(fileURLWithPath: path)
        guard try Data(contentsOf: url).starts(with: Data("%PDF".utf8)) else {
            throw ServiceError.remote("Invalid PDF")
        }
        return url
    }

    func exportPDF() async {
        commitComposition()
        guard serviceReady, !busy else {
            return
        }
        busy = true
        defer { busy = false }
        do { shareURL = try await compiledPDF() }
        catch { message = error.localizedDescription }
    }

    func exportProject() async {
        commitComposition()
        guard let document, !busy, await save() else {
            return
        }
        busy = true
        defer { busy = false }
        let directory = stateDirectory.appendingPathComponent("Exports")
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let project = directory.appendingPathComponent("Project")
            try await library.exportProject(document.id, to: project)
            defer { try? FileManager.default.removeItem(at: project) }
            let destination = directory.appendingPathComponent("LeftBlank-project.zip")
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator()
                .coordinate(readingItemAt: project, options: .forUploading, error: &coordinationError) { archive in
                    do { try FileManager.default.copyItem(at: archive, to: destination) }
                    catch { copyError = error }
                }
            if let error = coordinationError ?? copyError {
                throw error
            }
            shareURL = destination
        } catch { message = error.localizedDescription }
    }

    func showHistory() async {
        guard let historyKey else {
            return
        }
        let session = generation
        do { let result = try await history.revisions(for: historyKey)
            guard session == generation else {
                return
            }
            revisions = result
            panel = .history
        } catch { message = error.localizedDescription }
    }

    func restore(_ revision: DocumentRevision) async {
        guard requireWriting(), let historyKey, !busy else {
            return
        }
        commitComposition()
        let session = generation, currentVersion = version, previous = text
        do {
            let source = try await history.source(for: revision, key: historyKey)
            try await history.preserveBeforeRestore(previous, key: historyKey, at: Date())
            guard session == generation, currentVersion == version else {
                return
            }
            replace(source)
            panel = nil
            await save()
        } catch { message = error.localizedDescription }
    }

    func setCloud(_ enabled: Bool) async {
        guard TabletWindowRegistry.windows(in: stateDirectory).count == 1 else {
            message = L10n.text("Close other windows before changing iCloud Sync.")
            return
        }
        guard !busy, await save() else {
            return
        }
        busy = true
        defer { busy = false }
        let previousSelection = selection
        let relative = sourceURL.flatMap { source in
            resourceRoot.flatMap { try? ProjectSources.relativePath(of: source, in: $0) }
        }
        do {
            let report = try await library.setICloudEnabled(enabled)
            cloudEnabled = report.isICloud
            UserDefaults.standard.set(report.isICloud, forKey: "iPadCloudEnabled")
            try await reloadLibrary()
            let oldID = document?.id
            if let id = oldID.map({ report.idMappings[$0] ?? $0 }), let item = documents.first(where: { $0.id == id }) {
                await open(item)
                busy = false
                if let relative {
                    await openSource(item.folderURL.appendingPathComponent(relative))
                    jump(metrics.position(at: min(previousSelection.location, text.utf16.count)))
                }
            }
        } catch { message = error.localizedDescription }
    }

    func jump(_ position: TextPosition) {
        let offset = metrics.offset(at: position)
        selection = NSRange(location: offset, length: 0)
        if layout == .preview {
            layout = .writing
        }
        panel = nil
        editor?.isEditable = canWrite && !busy
        editor?.selectedRange = selection
        editor?.scrollRangeToVisible(selection)
        editor?.becomeFirstResponder()
    }

    func replace(_ source: String) {
        apply(TextReplacement(range: NSRange(location: 0, length: text.utf16.count), text: source))
    }

    func revisionSource(_ revision: DocumentRevision) async throws -> String {
        guard let historyKey else {
            throw HistoryError.unavailable
        }
        return try await history.source(for: revision, key: historyKey)
    }
}

extension TabletWorkspace {
    func insert(_ command: WritingCommand, values: [String: String]) {
        guard requireWriting(), let editor, editor.markedTextRange == nil else {
            return
        }
        do {
            let selected = (text as NSString).substring(with: selection)
            let snippet = try TypstInsertion.make(command.id, values: values, selection: selected)
            let plan = InsertionPlan(command: command, snippet: snippet, text: text, selection: selection)
            apply(TextReplacement(range: plan.range, text: plan.snippet.text))
            (editor as? TabletTextView)?.setSnippet(plan.snippet, at: plan.range.location)
            panel = nil
            editor.becomeFirstResponder()
        } catch { message = error.localizedDescription }
    }

    func lineAction(_ action: LineAction) {
        apply(TextEditing.lines(action, text: text, selection: selection))
    }

    func apply(_ edit: TextReplacement, restoringSelection: NSRange? = nil) {
        guard requireWriting(), !busy, let editor, editor.markedTextRange == nil,
              edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= editor.textStorage.length,
              edit.range.length <= editor.textStorage.length - edit.range.location
        else {
            return
        }
        (editor as? TabletTextView)?.clearSnippet()
        let previousSelection = editor.selectedRange
        let inverse = TextReplacement(
            range: NSRange(location: edit.range.location, length: edit.text.utf16.count),
            text: (editor.text as NSString).substring(with: edit.range),
        )
        editor.undoManager?.registerUndo(withTarget: self) { workspace in
            workspace.apply(inverse, restoringSelection: previousSelection)
        }
        // UITextInput replacement can apply typographic quote substitutions even
        // to programmatic code. Edit storage verbatim and retain native undo.
        editor.textStorage.replaceCharacters(in: edit.range, with: edit.text)
        editor.selectedRange = restoringSelection ?? NSRange(
            location: edit.range.location + edit.text.utf16.count,
            length: 0,
        )
        edited(editor.text, selection: editor.selectedRange)
    }

    func format() async {
        guard requireWriting(), let sourceURL, serviceReady, editor?.markedTextRange == nil else {
            return
        }
        let revision = version, session = generation, original = text
        do {
            let response = try await client.request("textDocument/formatting", [
                "textDocument": ["uri": sourceURL.absoluteString],
                "options": ["tabSize": 2, "insertSpaces": true],
            ])
            guard revision == version, session == generation else {
                return
            }
            let index = TextLineIndex(original)
            let edits = response.array.map { edit in
                let start = edit["range"]["start"], end = edit["range"]["end"]
                let lower = index.offset(at: TextPosition(
                    line: start["line"].int ?? 0,
                    character: start["character"].int ?? 0,
                ))
                let upper = index.offset(at: TextPosition(
                    line: end["line"].int ?? 0,
                    character: end["character"].int ?? 0,
                ))
                return TextReplacement(
                    range: NSRange(location: lower, length: max(0, upper - lower)),
                    text: edit["newText"].string ?? "",
                )
            }
            try replace(TextEditing.applying(edits, to: original))
            panel = nil
        } catch { message = error.localizedDescription }
    }
}

extension TabletWorkspace {
    func showUniverse() {
        panel = .universe
    }

    func addPackage(_ package: UniversePackage) {
        guard requireWriting(), let editor, editor.markedTextRange == nil else {
            return
        }
        do {
            let snippet = try package.pinnedImport()
            let offset = InsertionPlan.preambleEnd(text)
            let prefix = (text as NSString).substring(to: offset)
            apply(TextReplacement(
                range: NSRange(location: offset, length: 0),
                text: (prefix.isEmpty || prefix.hasSuffix("\n") ? "" : "\n") + snippet.text + "\n",
            ))
            panel = nil
        } catch { message = error.localizedDescription }
    }

    func createTemplate(_ package: UniversePackage) async {
        guard requireWriting(), !busy else {
            return
        }
        busy = true
        let staging = stateDirectory.appendingPathComponent("TemplateStaging")
        do {
            let installer = TinymistClient(makeTransport: { EmbeddedTinymist() })
            defer { installer.stop() }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try await installer.start(root: staging, outputDirectory: staging)
            let project = try await UniverseTemplateInstaller.materialize(package, using: installer, in: staging)
            defer { try? FileManager.default.removeItem(at: project.directoryURL) }
            let item = try await library.importProject(
                at: project.directoryURL,
                mainFile: project.mainFileURL,
                title: package.name,
            )
            try await reloadLibrary()
            busy = false
            panel = nil
            await open(item)
        } catch { busy = false
            message = error.localizedDescription
        }
    }

    func addSampleBook() async {
        guard requireWriting(), !busy else {
            return
        }
        busy = true
        let store = SampleBookStore(cacheURL: stateDirectory.appendingPathComponent("BookCache"))
        do {
            let project = try await store.materialize(
                .sicp,
                in: stateDirectory.appendingPathComponent("BookStaging"),
            )
            defer { try? FileManager.default.removeItem(at: project.directoryURL) }
            let item = try await library.importProject(
                at: project.directoryURL,
                mainFile: project.mainFileURL,
                title: SampleBook.sicp.title,
            )
            try await reloadLibrary()
            busy = false
            panel = nil
            await open(item)
        } catch { busy = false
            message = error.localizedDescription
        }
    }

    func importProject(_ url: URL) async {
        guard requireWriting(), !busy else {
            return
        }
        cancelProjectImport()
        pendingProjectAccess = url.startAccessingSecurityScopedResource()
        pendingProjectURL = url
        do {
            importSources = try ProjectSources.list(in: url)
            guard !importSources.isEmpty else {
                throw LibraryError.invalidProject
            }
            if importSources.count == 1, let source = importSources.first {
                await finishProjectImport(source)
            } else {
                panel = .projectEntry
            }
        } catch {
            cancelProjectImport()
            message = error.localizedDescription
        }
    }

    func finishProjectImport(_ source: URL) async {
        guard requireWriting(), !busy, let directory = pendingProjectURL else {
            return
        }
        busy = true
        defer { busy = false
            cancelProjectImport()
        }
        do {
            _ = try ProjectSources.relativePath(of: source, in: directory)
            let item = try await library.importProject(at: directory, mainFile: source)
            try await reloadLibrary()
            panel = nil
            busy = false
            await open(item)
        } catch { message = error.localizedDescription }
    }

    func importSourceLabel(_ source: URL) -> String {
        guard let pendingProjectURL else {
            return source.lastPathComponent
        }
        return (try? ProjectSources.relativePath(of: source, in: pendingProjectURL)) ?? source.lastPathComponent
    }

    func cancelProjectImport() {
        if pendingProjectAccess {
            pendingProjectURL?.stopAccessingSecurityScopedResource()
        }
        pendingProjectAccess = false
        pendingProjectURL = nil
        importSources = []
    }

    func trash(_ item: LibraryDocument) async {
        guard !busy else {
            return
        }
        if item.id == document?.id, await !save() {
            return
        }
        do {
            _ = try await library.trash(item.id)
            if item.id == document?.id {
                generation = UUID()
                client.stop()
                document = nil
                activeSourceURL = nil
                projectSources = []
                previewURL = nil
                previewReady = false
                previewIssue = nil
                serviceReady = false
                text = ""
                savedText = ""
                baseline = nil
                try? FileManager.default.removeItem(at: recoveryURL)
            }
            try await reloadLibrary()
        } catch { message = error.localizedDescription }
    }

    func showTrash() async {
        do {
            trashedDocuments = try await library.list(includeTrashed: true).filter(\.isTrashed)
            panel = .trash
        } catch { message = error.localizedDescription }
    }

    func restoreDocument(_ item: LibraryDocument) async {
        do {
            _ = try await library.restore(item.id)
            try await reloadLibrary()
            await showTrash()
        } catch { message = error.localizedDescription }
    }
}

extension TabletWorkspace {
    func saveInBackground() {
        commitComposition()
        guard backgroundTask == .invalid else {
            return
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save writing") { [weak self] in
            Task { @MainActor [weak self] in self?.finishBackgroundSave() }
        }
        // A closing scene must retain its workspace until the last save completes.
        Task { [self] in
            await save()
            finishBackgroundSave()
        }
    }

    private func finishBackgroundSave() {
        guard backgroundTask != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension TabletWorkspace {
    func showProjectFiles() {
        guard let document else {
            return
        }
        do {
            projectSources = try ProjectSources.list(in: document.folderURL)
            panel = .files
        } catch { message = error.localizedDescription }
    }

    func sourceLabel(_ source: URL) -> String {
        guard let resourceRoot else {
            return source.lastPathComponent
        }
        return (try? ProjectSources.relativePath(of: source, in: resourceRoot)) ?? source.lastPathComponent
    }

    @discardableResult
    func openSource(_ url: URL) async -> Bool {
        guard let document, !changing, !busy else {
            return false
        }
        do {
            _ = try ProjectSources.relativePath(of: url, in: document.folderURL)
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            if target == sourceURL?.standardizedFileURL.resolvingSymlinksInPath() {
                return true
            }
            commitComposition()
            changing = true
            busy = true
            defer { changing = false
                busy = false
            }
            guard await save() else {
                return false
            }
            let (source, disk) = try DocumentStorage.read(target)
            debounce?.cancel()
            generation = UUID()
            client.stop()
            activeSourceURL = target
            text = source
            savedText = source
            baseline = disk
            version = 1
            selection = NSRange(location: 0, length: 0)
            tokens = []
            highlightedText = ""
            outline = []
            diagnostics = []
            revisions = []
            assistance.invalidate()
            (editor as? TabletTextView)?.clearSnippet()
            editor?.undoManager?.removeAllActions()
            editor?.text = source
            editor?.selectedRange = selection
            previewURL = nil
            previewReady = false
            previewIssue = nil
            serviceReady = false
            saveStatus = "Saved"
            persistRecovery()
            await connect()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func jump(to location: SourceLocation) async {
        guard await openSource(location.url) else {
            return
        }
        jump(location.position)
    }
}
