import AppKit
import Combine
import LeftBlankCore
import PDFKit
import UniformTypeIdentifiers

struct DiagnosticItem: Identifiable {
    let id = UUID()
    let message: String
    let severity: Int
    let position: TextPosition
    let url: URL
}

enum EditorLayout: String { case writing, split, preview }
enum SidePanel { case outline }

@MainActor
final class Workspace: ObservableObject {
    @Published var text = "" {
        didSet { textMetrics = nil }
    }

    @Published var fileURL: URL? {
        didSet { updateSourceAccess() }
    }

    @Published private(set) var isPackageSource = false

    var packageCache: URL {
        stateDirectory.appendingPathComponent("PackageCache")
    }

    var canEditSource: Bool {
        !isLibraryHome && !isPackageSource
    }

    var editorIsEditable: Bool {
        canEditSource && layout != .preview && !paletteOpen && !documentTransitionInProgress
    }

    private func updateSourceAccess() {
        isPackageSource = fileURL.map { PackageSource.isReadOnly($0, packageCache: packageCache) } ?? false
        editor?.isEditable = editorIsEditable
    }

    @Published var mainFileURL: URL?
    @Published var savedText: String?
    @Published var objectEditSession: ObjectEditSession?
    let previewReading = PreviewReadingSession()
    private var previewFollowTask: Task<Void, Never>?
    var previewReturnLayout: EditorLayout?
    private var previewCompilationURL: URL?
    @Published var historyOpen = false
    @Published var historyInterval: HistoryInterval = .hourly
    lazy var history = DocumentHistoryController(workspace: self)
    lazy var agentConnection = MCPConnection(workspace: self)
    @Published var saveStatus = "Draft"
    @Published var serviceStatus = "Connecting"
    @Published var serviceReady = false
    @Published var previewURL: URL? {
        didSet {
            if previewURL != oldValue {
                previewReadyForNavigation = false
            }
        }
    }

    private var previewReadyForNavigation = false
    private var pendingPreviewNavigation: (
        url: URL,
        position: TextPosition,
        version: Int,
        reportFailure: Bool,
        following: Bool,
    )?
    @Published var diagnostics: [DiagnosticItem] = []
    @Published var layout: EditorLayout = .writing {
        didSet {
            recordOperation("layout.changed", ["layout": layout.rawValue])
            dismissAssistance()
            editor?.isEditable = editorIsEditable
            if !paletteOpen {
                editor?.window?.makeFirstResponder(layout == .preview ? nil : editor)
            }
        }
    }

    @Published var sidePanel: SidePanel? {
        didSet { recordOperation("sidebar.changed", ["panel": sidePanel == .outline ? "outline" : "closed"]) }
    }

    @Published var checksOpen = false {
        didSet { recordOperation("checks.visibility", ["open": String(checksOpen)]) }
    }

    @Published var appearance: AppAppearance = .system {
        didSet { Theme.apply(appearance) }
    }

    @Published var fontSize: CGFloat = 16
    @Published var selection = NSRange(location: 0, length: 0) {
        didSet {
            if selection != oldValue {
                dismissAssistance()
                trackOutline(at: selection.location)
                schedulePreviewFollow()
            }
        }
    }

    @Published var message: String?
    @Published var paletteOpen = false
    @Published var paletteGroup: String?
    @Published var searchMode = false
    @Published var query = ""
    @Published var activeCommand: WritingCommand?
    @Published var fieldValues: [String: String] = [:]
    @Published var resourceSelection: ResourceSelection?
    @Published var availableResources: [DocumentResource] = []
    @Published var availableLibraryDocuments: [LibraryDocument] = []
    let resourceStore = DocumentResourceStore()
    @Published var commandError: String?
    @Published var selectedCommandIndex = 0
    @Published var exporting = false
    @Published var previewZoom: CGFloat = 1
    @Published var previewDark = false
    @Published var styledSource = true {
        didSet { editor?.highlight() }
    }

    @Published var discoveryMode: UniverseDiscoveryMode?
    @Published var libraryOpen = false
    @Published private(set) var isLibraryHome = false
    @Published var documentTemplate: DocumentTemplate = .blank
    @Published var managedDocumentID: UUID?
    @Published var managedTitle: String?
    @Published var documentTransitionInProgress = false
    var agentMetadataChangeInProgress = false
    @Published var previewStale = true
    @Published var hasSuccessfulPreview = false
    @Published var outline: [OutlineItem] = [] {
        didSet { rebuildOutline() }
    }

    @Published private(set) var outlineNavigation = OutlineNavigation()
    @Published private(set) var activeOutlineIndex: Int?
    private var readingOffset = 0
    private lazy var outlineExpansions: [String: OutlineNavigation.Expansion] = {
        guard let data = try? Data(contentsOf: outlineStateURL) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: OutlineNavigation.Expansion].self, from: data)) ?? [:]
    }()

    private var outlineStateURL: URL {
        stateDirectory.appendingPathComponent("outline-folds.json")
    }

    private func rebuildOutline() {
        let key = documentURL.absoluteString
        outlineNavigation = OutlineNavigation(
            items: outline,
            expansion: outlineExpansions[key],
            anchor: selection.location,
        )
        if !outline.isEmpty {
            outlineExpansions[key] = outlineNavigation.expansion
        }
        trackOutline(at: readingOffset)
    }

    func trackOutline(at offset: Int) {
        readingOffset = offset
        let index = outlineNavigation.index(at: offset)
        if activeOutlineIndex != index {
            activeOutlineIndex = index
        }
    }

    func toggleOutlineSection(_ index: Int) {
        outlineNavigation.toggle(index)
        rememberOutlineExpansion()
    }

    func expandOutline(_ expanded: Bool) {
        outlineNavigation.setAll(expanded: expanded)
        rememberOutlineExpansion()
    }

    private func rememberOutlineExpansion() {
        outlineExpansions[documentURL.absoluteString] = outlineNavigation.expansion
        if let data = try? JSONEncoder().encode(outlineExpansions) {
            try? data.write(
                to: outlineStateURL,
                options: .atomic,
            )
        }
    }

    @Published var applyingCommand = false
    @Published var commandKey: String = UserDefaults.standard.string(forKey: "commandKey") ?? "j" {
        didSet { UserDefaults.standard.set(commandKey, forKey: "commandKey")
            onShortcutChange?()
        }
    }

    @Published private(set) var assistance: WritingAssistance?
    private var assistanceTask: Task<Void, Never>?
    private var assistanceRequest = UUID()
    private var navigationHistory: [(url: URL, position: TextPosition, main: URL?)] = []
    weak var editor: ManuscriptTextView?
    weak var window: NSWindow?
    var onTitleChange: ((String) -> Void)?
    var onShortcutChange: (() -> Void)?
    private let client = TinymistClient()
    private var baseline: DiskBaseline?
    private var diagnosticsByURI: [String: [DiagnosticItem]] = [:]
    private var documentVersion = 1
    private var serviceGeneration = UUID()
    private var saveTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var syntaxTask: Task<Void, Never>?
    private let codeHighlighter = CodeBlockHighlighting()
    private(set) var syntaxSnapshot: (source: String, tokens: [HighlightToken])?
    private(set) var syntaxRevision = 0
    private(set) var syntaxDocumentRevision = -1
    private var messageTask: Task<Void, Never>?
    private var sentVersion = 0
    let stateDirectory: URL
    lazy var library = LibraryController(workspace: self)
    private let actionLog: ActionLog?
    private var recoveryURL: URL {
        stateDirectory.appendingPathComponent("recovery.json")
    }

    var draftURL: URL {
        stateDirectory.appendingPathComponent("Draft.typ")
    }

    var documentURL: URL {
        fileURL ?? draftURL
    }

    var compilationURL: URL {
        mainFileURL ?? documentURL
    }

    var title: String {
        if isPackageSource, let fileURL {
            return fileURL.lastPathComponent
        }
        return isLibraryHome ? L10n
            .text("Your writing") :
            (managedTitle ?? fileURL?.deletingPathExtension().lastPathComponent ?? L10n.text("Untitled"))
    }

    var revision: Int {
        documentVersion
    }

    private var textMetrics: DocumentMetrics?
    private var metrics: DocumentMetrics {
        if let textMetrics {
            return textMetrics
        }
        let value = DocumentMetrics(text)
        textMetrics = value
        return value
    }

    var position: TextPosition {
        metrics.position(at: selection.location)
    }

    var wordCount: Int {
        metrics.wordCount
    }

    private var commandResults: (query: String, group: String?, searching: Bool, commands: [WritingCommand])?

    var filteredCommands: [WritingCommand] {
        if let cached = commandResults, cached.query == query, cached.group == paletteGroup,
           cached.searching == searchMode
        {
            return cached.commands
        }
        let commands = searchMode ? WritingCommand.search(query) : WritingCommand.all
            .filter { $0.group == paletteGroup }
        commandResults = (query, paletteGroup, searchMode, commands)
        return commands
    }

    var paletteGroups: [CommandGroup] {
        searchMode ? [] : CommandGroup.children(of: paletteGroup)
    }

    var paletteEntryCount: Int {
        paletteGroups.count + filteredCommands.count
    }

    var highlightedCommand: WritingCommand? {
        let index = selectedCommandIndex - paletteGroups.count
        return filteredCommands.indices.contains(index) ? filteredCommands[index] : nil
    }

    func keyPath(for command: WritingCommand) -> String {
        command.keyPath
    }

    init(stateDirectory directory: URL? = nil) {
        if let directory {
            stateDirectory = directory
        } else {
            stateDirectory = AppDistribution.defaultStateDirectory
        }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("Exports"),
            withIntermediateDirectories: true,
        )
        actionLog = try? ActionLog(directory: stateDirectory.appendingPathComponent("Logs"))
        actionLog?.record(
            "session.start",
            fields: [
                "version": Bundle.main
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "pid": String(ProcessInfo.processInfo.processIdentifier),
            ],
        )
        if let data = try? Data(contentsOf: stateDirectory.appendingPathComponent("recovery.json")),
           let snapshot = try? JSONDecoder().decode(
               RecoverySnapshot.self,
               from: data,
           )
        {
            fileURL = snapshot.fileURL
            mainFileURL = snapshot.mainFileURL
            text = snapshot.text
            savedText = snapshot.savedText
            selection = NSRange(location: min(snapshot.selection, text.utf16.count), length: 0)
            isLibraryHome = snapshot.libraryHome == true
            if let fileURL {
                baseline = DiskBaseline(data: snapshot.savedText.map { Data($0.utf8) })
                if let disk = try? DocumentStorage.read(fileURL), snapshot.text == snapshot.savedText {
                    text = disk.0
                    savedText = disk.0
                    baseline = disk.1
                }
            }
        } else {
            text = Self.welcome
            try? WelcomeDocument.prepareAssets(in: stateDirectory)
            layout = .split
        }
        saveStatus = fileURL == nil ? "Local Draft" : (text == savedText ? "Saved" : "Unsaved Work Restored")
        client.onNotification = { [weak self] method, params in self?.receive(method, params) }
        client.onDisconnect = { [weak self] message in
            self?.recordOperation("service.disconnected", ["reason": message])
            self?.serviceReady = false
            self?.serviceStatus = "Disconnected"
            self?.message = message
        }
        client.onShowDocument = { [weak self] params in self?.showDocument(params) }
        updateSourceAccess()
    }

    func startService() {
        guard !isLibraryHome else {
            return
        }
        if previewCompilationURL != compilationURL {
            previewCompilationURL = compilationURL
            previewReading.reset()
            previewReturnLayout = nil
        }
        recordOperation("service.start")
        checksOpen = false
        dismissAssistance()
        let generation = UUID()
        serviceGeneration = generation
        syntaxTask?.cancel()
        syntaxTask = nil
        syntaxSnapshot = nil
        syntaxRevision += 1
        serviceReady = false
        serviceStatus = "Connecting"
        diagnostics = []
        diagnosticsByURI = [:]
        outline = []
        previewURL = nil
        hasSuccessfulPreview = false
        previewStale = true
        sentVersion = 0
        Task {
            do {
                if fileURL == nil {
                    _ = try DocumentStorage.write(text, to: draftURL, baseline: nil)
                }
                let root = try await library.store.compilationRoot(for: compilationURL)
                guard serviceGeneration == generation else {
                    return
                }
                try await client.start(
                    root: root,
                    outputDirectory: stateDirectory.appendingPathComponent("Exports"),
                )
                guard serviceGeneration == generation else {
                    return
                }
                try client.open(documentURL, text: text, version: documentVersion)
                if compilationURL != documentURL {
                    try client.open(compilationURL, text: DocumentStorage.read(compilationURL).0, version: 1)
                }
                sentVersion = documentVersion
                serviceReady = true
                serviceStatus = "Ready"
                let url = try await client.startPreview(compilationURL)
                guard serviceGeneration == generation else {
                    return
                }
                previewURL = url
                recordOperation("service.ready")
                try flushChanges()
                refreshSyntax()
                await refreshOutline()
            } catch {
                guard serviceGeneration == generation else {
                    return
                }
                serviceStatus = "Unavailable"
                recordOperation("service.failed", ["error": error.localizedDescription])
                showMessage(error.localizedDescription, persistent: true)
            }
        }
    }

    func edited(_ newText: String, change: TextReplacement? = nil) {
        guard canEditSource else {
            return
        }
        history.willEdit(previous: text)
        dismissAssistance()
        var updatedMetrics: DocumentMetrics?
        if let change, var current = textMetrics, current.apply(change, to: text) {
            updatedMetrics = current
        }
        text = newText
        textMetrics = updatedMetrics
        documentVersion += 1
        schedulePreviewFollow()
        previewStale = true
        saveStatus = fileURL == nil ? "Saving Draft" : "Unsaved"
        if serviceReady {
            serviceStatus = "Typesetting"
        }
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            let recovered = saveRecovery()
            if fileURL != nil {
                save()
            } else {
                saveStatus = recovered ? "Draft Saved" : "Draft Save Failed"
            }
        }
        syncTask?.cancel()
        syncTask = Task {
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            try? flushChanges()
            refreshSyntax()
            await refreshOutline()
        }
    }

    /// At most one request is in flight. If typing overtakes it, discard its
    /// ranges and immediately request the latest buffer without blocking input.
    private func refreshSyntax() {
        guard serviceReady, syntaxTask == nil else {
            return
        }
        let generation = serviceGeneration
        syntaxTask = Task {
            defer {
                if generation == serviceGeneration {
                    syntaxTask = nil
                }
            }
            while !Task.isCancelled, serviceReady, generation == serviceGeneration {
                let version = documentVersion, source = text
                do {
                    try flushChanges()
                    async let embedded = codeHighlighter.tokens(in: source)
                    let response = try await client.request(
                        "textDocument/semanticTokens/full",
                        ["textDocument": ["uri": documentURL.absoluteString]],
                    )
                    let encoded = response["data"].array.compactMap(\.int)
                    let types = client.semanticTokenTypes, modifiers = client.semanticTokenModifiers
                    let tokens = await Task.detached(priority: .userInitiated) {
                        SemanticHighlighting.decode(encoded, source: source, types: types, modifiers: modifiers)
                    }.value
                    let combined = await tokens + embedded
                    guard !Task.isCancelled, generation == serviceGeneration else {
                        return
                    }
                    if version != documentVersion {
                        continue
                    }
                    syntaxSnapshot = (source, combined)
                    syntaxDocumentRevision = version
                    syntaxRevision += 1
                    editor?.highlight()
                } catch { /* Keep editing with the lightweight local styles. */ }
                return
            }
        }
    }

    private func refreshOutline() async {
        guard serviceReady else {
            return
        }
        let version = documentVersion, generation = serviceGeneration
        do {
            let symbols = try await client.request(
                "textDocument/documentSymbol",
                ["textDocument": ["uri": documentURL.absoluteString]],
            )
            guard version == documentVersion, generation == serviceGeneration else {
                return
            }
            let index = metrics
            func headings(_ nodes: [JSONValue], level: Int) -> [OutlineItem] {
                nodes.flatMap { node -> [OutlineItem] in
                    let isHeading = node["kind"].int == 3
                    let start = node["range"]["start"]
                    let position = TextPosition(line: start["line"].int ?? 0, character: start["character"].int ?? 0)
                    let current = isHeading ? [OutlineItem(
                        title: node["name"].string ?? L10n.text("Heading"),
                        level: level,
                        offset: index.offset(at: position),
                    )] : []
                    return current + headings(node["children"].array, level: isHeading ? level + 1 : level)
                }
            }
            outline = headings(symbols.array, level: 1)
        } catch { /* A failed outline refresh leaves the last valid outline visible. */ }
    }

    func flushChanges() throws {
        guard serviceReady, documentVersion != sentVersion else {
            return
        }
        try client.change(documentURL, text: text, version: documentVersion)
        sentVersion = documentVersion
    }

    @discardableResult func saveRecovery() -> Bool {
        history.flush(current: text)
        let snapshot = RecoverySnapshot(
            fileURL: fileURL,
            text: text,
            savedText: savedText,
            selection: selection.location,
            mainFileURL: mainFileURL,
            libraryHome: isLibraryHome,
        )
        do { try JSONEncoder().encode(snapshot).write(to: recoveryURL, options: .atomic)
            return true
        } catch { recordOperation("recovery.failed", ["error": error.localizedDescription])
            showMessage(
                L10n.format("Could not save the recovery copy: %@", error.localizedDescription),
                persistent: true,
            )
            return false
        }
    }

    func save() {
        guard !isLibraryHome else {
            return
        }
        guard let fileURL else {
            saveAs()
            return
        }
        if isPackageSource {
            saveStatus = "Read-only Package"
            return
        }
        history.flush(current: text)
        do {
            baseline = try DocumentStorage.write(text, to: fileURL, baseline: baseline, packageCache: packageCache)
            savedText = text
            saveStatus = "Saved"
            recordOperation("save.finished")
            saveRecovery()
            try? client.notify("textDocument/didSave", ["textDocument": ["uri": fileURL.absoluteString]])
        } catch {
            saveStatus = "Save Needs Attention"
            recordOperation("save.failed", ["error": error.localizedDescription])
            saveRecovery()
            showMessage(error.localizedDescription, persistent: true)
        }
    }

    private func present(_ panel: NSSavePanel, completion: @escaping @MainActor (URL) -> Void) {
        guard let window = window ?? editor?.window, window.attachedSheet == nil else {
            return
        }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                completion(url)
            }
        }
    }

    func saveAs() {
        guard !isLibraryHome else {
            return
        }
        recordOperation("saveAs.dialog")
        let panel = NSSavePanel()
        panel.title = L10n.text("Save Document")
        panel.nameFieldStringValue = managedTitle.map { $0.replacingOccurrences(of: "/", with: "-") + ".typ" }
            ?? fileURL?.lastPathComponent ?? L10n.text("Untitled.typ")
        panel.directoryURL = managedDocumentID == nil && !isPackageSource ? fileURL?.deletingLastPathComponent() : nil
        panel.allowedContentTypes = [UTType(filenameExtension: "typ") ?? .plainText]
        present(panel) { [weak self] url in
            guard let self else {
                return
            }
            do {
                try save(to: url)
            } catch { recordOperation("saveAs.failed", ["error": error.localizedDescription])
                showMessage(error.localizedDescription, persistent: true)
            }
        }
    }

    func save(to url: URL) throws {
        history.flush(current: text)
        baseline = try DocumentStorage.write(
            text,
            to: url,
            baseline: url == fileURL ? baseline : nil,
            packageCache: packageCache,
        )
        navigationHistory.removeAll()
        fileURL = url
        mainFileURL = nil
        savedText = text
        saveStatus = "Saved"
        library.associate(url)
        recordOperation("saveAs.finished")
        saveRecovery()
        onTitleChange?(title)
        startService()
    }

    func openPanel(recovery: Bool = false) {
        recordOperation("open.dialog", ["recovery": String(recovery)])
        let panel = NSOpenPanel()
        panel.title = recovery ? L10n.text("Recover Draft Copy") : L10n.text("Open Document")
        panel.directoryURL = recovery ? stateDirectory : fileURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "typ") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        present(panel) { [weak self] url in self?.open(url) }
    }

    private func preserveCurrent() -> Bool {
        guard !isLibraryHome else {
            return true
        }
        saveTask?.cancel()
        saveRecovery()
        if fileURL != nil, text != savedText {
            save()
        }
        if text != savedText {
            let date = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let backup = stateDirectory.appendingPathComponent("Draft-\(date)-\(UUID().uuidString.prefix(6)).typ")
            do {
                _ = try DocumentStorage.write(text, to: backup, baseline: nil)
                showMessage(L10n
                    .text("Your previous document is preserved. Reopen it from Documents → Recover Draft Copy."))
            } catch { showMessage(error.localizedDescription, persistent: true)
                return false
            }
        }
        return true
    }

    @discardableResult func open(_ url: URL, preservingMain: Bool = false, rememberSource: Bool = true) -> Bool {
        guard !agentMetadataChangeInProgress else {
            return false
        }
        recordOperation("document.open", ["preservingMain": String(preservingMain)])
        do {
            guard preserveCurrent() else {
                return false
            }
            let (content, disk) = try DocumentStorage.read(url)
            let previousMain = compilationURL
            if preservingMain, rememberSource, url.standardizedFileURL != documentURL.standardizedFileURL {
                navigationHistory.append((documentURL, metrics.position(at: selection.location), mainFileURL))
            } else if !preservingMain {
                navigationHistory.removeAll()
            }
            mainFileURL = preservingMain && url != previousMain ? previousMain : nil
            fileURL = url
            text = content
            savedText = content
            baseline = disk
            isLibraryHome = false
            library.associate(url)
            if let managedDocumentID {
                library.noteOpened(managedDocumentID)
            }
            documentVersion += 1
            selection = NSRange(location: 0, length: 0)
            editor?.load(content, selection: selection)
            editor?.isEditable = editorIsEditable
            saveStatus = isPackageSource ? "Read-only Package" : "Saved"
            saveRecovery()
            onTitleChange?(title)
            startService()
            return true
        } catch { showMessage(error.localizedDescription, persistent: true)
            return false
        }
    }

    func newDocument() {
        recordOperation("document.new")
        openDiscovery(.templates)
    }

    func openLibrary() {
        discoveryMode = nil
        if !isLibraryHome {
            libraryOpen = true
        }
    }

    /// Discovery and the library share one presentation, including on an empty library.
    func openDiscovery(_ mode: UniverseDiscoveryMode) {
        closePalette()
        discoveryMode = mode
        if !isLibraryHome {
            libraryOpen = true
        }
    }

    /// No replacement draft is created when the last document is trashed.
    func showLibraryHome() {
        navigationHistory.removeAll()
        dismissAssistance()
        saveTask?.cancel()
        syncTask?.cancel()
        syntaxTask?.cancel()
        syntaxTask = nil
        messageTask?.cancel()
        syntaxSnapshot = nil
        syntaxRevision += 1
        serviceGeneration = UUID()
        client.stop()
        historyOpen = false
        isLibraryHome = true
        fileURL = nil
        mainFileURL = nil
        managedDocumentID = nil
        managedTitle = nil
        text = ""
        savedText = ""
        baseline = nil
        selection = NSRange(location: 0, length: 0)
        documentVersion += 1
        editor?.load("", selection: selection)
        editor?.isEditable = false
        previewURL = nil
        diagnostics = []
        diagnosticsByURI = [:]
        outline = []
        serviceReady = false
        hasSuccessfulPreview = false
        previewStale = true
        paletteOpen = false
        checksOpen = false
        sidePanel = nil
        message = nil
        libraryOpen = false
        saveRecovery()
        onTitleChange?(title)
        recordOperation("library.home")
    }

    func reload() {
        guard let fileURL else {
            return
        }
        do {
            let backup = stateDirectory.appendingPathComponent("Before-reload-\(UUID().uuidString).typ")
            _ = try DocumentStorage.write(text, to: backup, baseline: nil)
            let (content, disk) = try DocumentStorage.read(fileURL)
            text = content
            savedText = content
            baseline = disk
            documentVersion += 1
            editor?.load(content, selection: NSRange(location: 0, length: 0))
            saveStatus = "Saved"
            saveRecovery()
            startService()
            showMessage(L10n.text("Loaded the disk version. Your edits are preserved in a draft copy."))
        } catch { showMessage(error.localizedDescription, persistent: true) }
    }

    /// Incorporate an external save without replacing the text view or moving the
    /// viewport. Conflicting paragraphs stay in the live buffer and recovery file.
    func refreshFromLibrary() async {
        guard managedDocumentID != nil, let url = fileURL, let base = savedText,
              !documentTransitionInProgress, editor?.hasMarkedText() != true
        else {
            return
        }
        let result = await Task.detached { try? DocumentStorage.read(url) }.value
        guard let (remote, disk) = result, fileURL == url, savedText == base, remote != base else {
            return
        }
        let local = text, caret = selection, version = documentVersion
        let merge = await Task.detached(priority: .utility) {
            DocumentMerge.merge(base: base, local: local, remote: remote, selection: caret)
        }.value
        guard fileURL == url, savedText == base, documentVersion == version,
              selection == caret, editor?.hasMarkedText() != true, !documentTransitionInProgress
        else {
            return
        }
        guard let merged = merge else {
            saveRecovery()
            showMessage(
                L10n
                    .text(
                        "This paragraph changed on another device. Your writing is safe; resolve the conflict before saving.",
                    ),
                persistent: true,
            )
            return
        }
        let scrollView = editor?.enclosingScrollView
        let origin = scrollView?.contentView.bounds.origin
        let wasClean = text == base
        baseline = disk
        savedText = remote
        guard merged.text != text else {
            saveStatus = "Saved"
            saveRecovery()
            return
        }
        if let editor {
            editor.insertSnippet(
                Snippet(text: merged.text),
                replacing: NSRange(location: 0, length: text.utf16.count),
                focus: false,
            )
            editor.undoManager?.setActionName(L10n.text("Sync update"))
            editor.setSelectedRange(merged.selection)
        } else {
            edited(merged.text)
            selection = merged.selection
        }
        if wasClean {
            saveStatus = "Saved"
        }
        if let origin {
            scrollView?.contentView.scroll(to: origin)
            if let clip = scrollView?.contentView {
                scrollView?.reflectScrolledClipView(clip)
            }
        }
        saveRecovery()
        recordOperation("document.remoteUpdate", ["merged": String(!wasClean)])
    }

    func togglePalette() {
        dismissAssistance()
        checksOpen = false
        guard !isLibraryHome else {
            return
        }
        recordOperation("palette.toggle")
        if paletteOpen {
            closePalette()
        } else {
            guard editor?.hasMarkedText() != true else {
                return
            }
            editor?.isEditable = false
            editor?.window?.makeFirstResponder(nil)
            paletteOpen = true
            paletteGroup = nil
            searchMode = false
            activeCommand = nil
            query = ""
            commandError = nil
            selectedCommandIndex = 0
        }
    }

    func closePalette() {
        recordOperation("palette.close")
        paletteOpen = false
        activeCommand = nil
        resourceSelection = nil
        availableResources = []
        availableLibraryDocuments = []
        commandError = nil
        editor?.isEditable = editorIsEditable
        if layout != .preview, let editor {
            editor.window?.makeFirstResponder(editor)
        }
    }

    func backPalette() {
        commandError = nil
        if activeCommand != nil {
            activeCommand = nil
        } else if searchMode {
            searchMode = false
            query = ""
        } else if let group = paletteGroup {
            paletteGroup = CommandGroup.all.first { $0.id == group }?.parentID
        } else {
            closePalette()
        }
        selectedCommandIndex = 0
    }

    func enterGroup(_ id: String) {
        paletteGroup = id
        searchMode = false
        activeCommand = nil
        selectedCommandIndex = 0
    }

    func selectCommand(_ command: WritingCommand) {
        recordOperation("command.selected", ["command": command.id, "source": searchMode ? "search" : "group"])
        commandError = nil
        fieldValues = Dictionary(uniqueKeysWithValues: command.fields.map { ($0.id, $0.initial) })
        resourceSelection = nil
        availableResources = []
        availableLibraryDocuments = []
        if command.fields.isEmpty {
            execute(command)
        } else {
            activeCommand = command
            loadResources(for: command)
        }
    }

    func handlePaletteKey(_ event: NSEvent) -> Bool {
        guard paletteOpen else {
            return false
        }
        if (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true {
            return false
        }
        if event.keyCode == 53 {
            backPalette()
            return true
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
            return false
        }
        if activeCommand != nil {
            return false
        }
        let grid = !searchMode && paletteGroup == nil
        let step = grid ? 3 : 1
        if event.keyCode == 125 {
            selectedCommandIndex = min(selectedCommandIndex + step, max(0, paletteEntryCount - 1))
            return true
        }
        if event.keyCode == 126 {
            selectedCommandIndex = max(0, selectedCommandIndex - step)
            return true
        }
        if grid, event.keyCode == 124 {
            selectedCommandIndex = min(
                selectedCommandIndex + 1,
                max(0, paletteEntryCount - 1),
            )
            return true
        }
        if grid, event.keyCode == 123 {
            selectedCommandIndex = max(0, selectedCommandIndex - 1)
            return true
        }
        if event.keyCode == 36, paletteEntryCount > 0 {
            if paletteGroups.indices
                .contains(selectedCommandIndex)
            {
                enterGroup(paletteGroups[selectedCommandIndex].id)
            } else if let command = highlightedCommand {
                selectCommand(command)
            }
            return true
        }
        if searchMode {
            return false
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        if key == "/" {
            searchMode = true
            paletteGroup = nil
            return true
        }
        if let group = paletteGroup,
           let command = WritingCommand.all
           .first(where: { $0.group == group && $0.key == key })
        {
            selectCommand(command)
            return true
        }
        if let group = paletteGroups.first(where: { $0.key == key }) {
            enterGroup(group.id)
            return true
        }
        return true
    }

    func execute(_ command: WritingCommand) {
        recordOperation("command.execute", ["command": command.id])
        switch command.id {
        case "undo": closePalette()
            editor?.undoManager?.undo()
        case "redo": closePalette()
            editor?.undoManager?.redo()
        case "cut": closePalette()
            editor?.cut(nil)
        case "copy": closePalette()
            editor?.copy(nil)
        case "paste": closePalette()
            editor?.paste(nil)
        case "selectAll": closePalette()
            editor?.selectAll(nil)
        case "find":
            closePalette()
            if layout == .preview {
                layout = .split
            }
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            editor?.performFindPanelAction(sender)
        case "fontLarger": closePalette()
            fontSize = min(28, fontSize + 1)
        case "fontSmaller": closePalette()
            fontSize = max(12, fontSize - 1)
        case "new": closePalette()
            newDocument()
        case "open": closePalette()
            openLibrary()
        case "importDocument": closePalette()
            library.importPanel()
        case "revealSource": closePalette()
            NSWorkspace.shared.activateFileViewerSelecting([documentURL])
        case "history": openHistory()
        case "save": closePalette()
            save()
        case "saveAs": closePalette()
            saveAs()
        case "reload": closePalette()
            reload()
        case "drafts": closePalette()
            openPanel(recovery: true)
        case "export": closePalette()
            exportPDF()
        case "writing": layout = .writing
            closePalette()
        case "split": layout = .split
            closePalette()
        case "preview": layout = .preview
            closePalette()
        case "outline": sidePanel = sidePanel == .outline ? nil : .outline
            closePalette()
        case "outlineExpand", "outlineCollapse": expandOutline(command.id == "outlineExpand")
            sidePanel = .outline
            closePalette()
        case "diagnostics": closePalette()
            checksOpen.toggle()
        case "restart": closePalette()
            startService()
        case "revealPreview": closePalette()
            revealPreview()
        case "logs": closePalette()
            revealLogs()
        case "universe": openDiscovery(.packages)
        case "previewDark": previewDark.toggle()
            closePalette()
        case "format": closePalette()
            formatDocument()
        case "indent": closePalette()
            editLines(.indent)
        case "outdent": closePalette()
            editLines(.outdent)
        case "comment": closePalette()
            editLines(.comment)
        case "completion": closePalette()
            requestCompletion()
        case "quickHelp": closePalette()
            requestAssistance(.help)
        case "editObject": closePalette()
            editObjectAtCursor()
        case "contextActions": closePalette()
            requestAssistance(.actions)
        case "definition": closePalette()
            goToDefinition()
        case "navigateBack": closePalette()
            navigateBack()
        default: insert(command)
        }
    }

    func editLines(_ action: LineAction) {
        guard canEditSource, let editor, !editor.hasMarkedText() else {
            return
        }
        let replacement = TextEditing.lines(action, text: text, selection: editor.selectedRange())
        editor.insertSnippet(Snippet(text: replacement.text), replacing: replacement.range)
        editor.setSelectedRange(NSRange(location: replacement.range.location, length: replacement.text.utf16.count))
    }

    func formatDocument() {
        guard canEditSource, serviceReady, let editor, !editor.hasMarkedText() else {
            return
        }
        let caret = editor.selectedRange()
        Task {
            do {
                let formatted = try await formattedSource()
                guard !editor.hasMarkedText() else {
                    return
                }
                guard formatted != text else {
                    showMessage(L10n.text("The document is already formatted."))
                    return
                }
                editor.insertSnippet(
                    Snippet(text: formatted),
                    replacing: NSRange(location: 0, length: text.utf16.count),
                )
                editor.setSelectedRange(NSRange(location: min(caret.location, formatted.utf16.count), length: 0))
                recordOperation("document.formatted")
            } catch { showMessage(error.localizedDescription) }
        }
    }

    private func formattedSource() async throws -> String {
        guard serviceReady else {
            throw ServiceError.remote(L10n.text("The typesetting service is not ready."))
        }
        let version = documentVersion, generation = serviceGeneration
        try flushChanges()
        let result = try await client.request(
            "textDocument/formatting",
            ["textDocument": ["uri": documentURL.absoluteString],
             "options": ["tabSize": 2, "insertSpaces": true]],
        )
        guard documentVersion == version, serviceGeneration == generation else {
            throw ServiceError.remote(L10n.text("The document changed during formatting."))
        }
        let replacements = result.array.map { edit in
            let range = edit["range"]
            let start = TextPosition(
                line: range["start"]["line"].int ?? 0,
                character: range["start"]["character"].int ?? 0,
            ).offset(in: text)
            let end = TextPosition(
                line: range["end"]["line"].int ?? 0,
                character: range["end"]["character"].int ?? 0,
            ).offset(in: text)
            return TextReplacement(
                range: NSRange(location: start, length: end - start),
                text: edit["newText"].string ?? "",
            )
        }
        return try TextEditing.applying(replacements, to: text)
    }

    func importPackage(_ package: UniversePackage) throws {
        try PackageSource.requireWritable(documentURL, packageCache: packageCache)
        guard let editor,
              !editor.hasMarkedText()
        else {
            throw CommandError.invalid(L10n.text("Finish the current input before inserting a package."))
        }
        guard package.isCompatible(with: "0.15.1")
        else {
            throw CommandError
                .invalid(L10n.text("This version requires a newer Typst. Check Universe for a compatible version."))
        }
        let snippet = try package.pinnedImport()
        if text
            .contains(TypstInsertion.quoted(package.reference))
        {
            throw CommandError.invalid(L10n.text("This package version is already imported."))
        }
        if layout == .preview {
            layout = .split
        }
        editor.insertSnippet(snippet.padded(before: "", after: "\n"), replacing: NSRange(location: 0, length: 0))
        recordOperation("package.imported", ["package": package.reference])
    }

    func insertionContext(for command: WritingCommand, range: NSRange) async throws -> InsertionContext {
        guard serviceReady else {
            throw CommandError
                .invalid(L10n
                    .text(
                        "The typesetting service is not ready to check the insertion position. You can still edit directly.",
                    ))
        }
        try flushChanges()
        var context = InsertionContext.markup
        if command.placement != .preamble {
            var offsets = [range.location]
            if range
                .length >
                0
            {
                offsets
                    .append((text as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
                        .location)
            }
            if range.location == text.utf16.count,
               !text
               .isEmpty
            {
                offsets
                    .append((text as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
                        .location)
            }
            let queries: [[String: Any]] = offsets.map { [
                "kind": "modeAt",
                "position": TextPosition(offset: $0, in: text).json,
            ] }
            let result = try await client.command(
                "tinymist.interactCodeContext",
                arguments: [["textDocument": ["uri": documentURL.absoluteString], "query": queries]],
            )
            let modes = result.array.compactMap { $0["mode"].string }
            guard modes.count == queries.count, Set(modes).count == 1,
                  modes.allSatisfy(command.acceptsContext)
            else {
                throw CommandError
                    .invalid(command.supportsMath ? L10n
                        .text(
                            "Insert within body text or a single equation, without crossing code or comments.",
                        ) :
                        L10n
                        .text(
                            "This command works in body text. Move out of equations, code or comments and try again. Your text is unchanged.",
                        ))
            }
            context = modes.first == "math" ? .math : .markup
        }
        return context
    }

    private func insert(_ command: WritingCommand) {
        guard canEditSource, !applyingCommand, let editor, !editor.hasMarkedText() else {
            return
        }
        guard serviceReady
        else {
            commandError = L10n
                .text(
                    "The typesetting service is not ready to check the insertion position. You can still edit directly.",
                )
            return
        }
        let range = editor.selectedRange()
        let version = documentVersion, generation = serviceGeneration
        var values = fieldValues
        let resourceSelection = resourceSelection
        if command.fields.first?.resourceKind != nil, resourceSelection == nil {
            chooseResource(for: command)
            return
        }
        applyingCommand = true
        recordOperation("insertion.begin", ["command": command.id])
        Task {
            defer { applyingCommand = false }
            var imported: [DocumentResource] = []
            do {
                let insertionContext = try await insertionContext(for: command, range: range)
                guard version == documentVersion, generation == serviceGeneration, paletteOpen,
                      editor.selectedRange() == range
                else {
                    recordOperation(
                        "insertion.cancelled",
                        ["command": command.id, "reason": "document, selection or panel changed"],
                    )
                    return
                }
                if let kind = command.fields.first?.resourceKind, let resourceSelection {
                    let resources = try await resolveResource(resourceSelection, kind: kind)
                    if case .file = resourceSelection {
                        imported = resources
                    }
                    guard version == documentVersion, generation == serviceGeneration, paletteOpen,
                          activeCommand?.id == command.id, editor.selectedRange() == range
                    else {
                        try await resourceStore.discardImport(imported)
                        return
                    }
                    values["path"] = resources.first?.relativePath
                }
                let selected = (text as NSString).substring(with: range)
                let snippet = try TypstInsertion.make(
                    command.id,
                    values: values,
                    selection: selected,
                    context: insertionContext,
                )
                let plan = InsertionPlan(command: command, snippet: snippet, text: text, selection: range)
                closePalette()
                if layout == .preview {
                    layout = .split
                }
                editor.insertSnippet(plan.snippet, replacing: plan.range)
                recordOperation(
                    "insertion.finished",
                    ["command": command.id, "insertedUTF16": String(plan.snippet.text.utf16.count)],
                )
            } catch { try? await resourceStore.discardImport(imported)
                recordOperation("insertion.failed", ["command": command.id, "error": error.localizedDescription])
                commandError = error.localizedDescription
            }
        }
    }

    func jump(to offset: Int, synchronizePreview: Bool = true) {
        if layout == .preview {
            layout = .split
        }
        selection = NSRange(location: min(max(0, offset), text.utf16.count), length: 0)
        editor?.setSelectedRange(selection)
        editor?.scrollRangeToVisible(selection)
        if let editor {
            editor.window?.makeFirstResponder(editor)
        }
        if synchronizePreview, layout == .split {
            queuePreviewNavigation(reportFailure: false)
        } else {
            pendingPreviewNavigation = nil
        }
    }

    func revealPreview() {
        if layout == .writing {
            layout = .split
        }
        queuePreviewNavigation(reportFailure: true)
    }

    func previewDidBecomeReady(at url: URL) {
        guard previewURL == url else {
            return
        }
        previewReadyForNavigation = true
        recordOperation("preview.ready")
        sendPendingPreviewNavigation()
    }

    func previewWillLoad(at url: URL) {
        guard previewURL == url else {
            return
        }
        previewReadyForNavigation = false
        recordOperation("preview.loading")
    }

    func schedulePreviewFollow() {
        previewFollowTask?.cancel()
        guard previewReading.followsWriting, layout == .split, !paletteOpen,
              editor?.hasMarkedText() != true
        else {
            return
        }
        let generation = serviceGeneration
        previewFollowTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, generation == serviceGeneration, previewReading.followsWriting,
                  layout == .split, !paletteOpen, editor?.hasMarkedText() != true
            else {
                return
            }
            queuePreviewNavigation(reportFailure: false, following: true)
        }
    }

    private func queuePreviewNavigation(reportFailure: Bool, following: Bool = false) {
        // Tinymist resolves the leaf before an exact token boundary. Step into
        // the selected character so heading/paragraph starts map to their text,
        // rather than the preceding newline (which has no rendered position).
        let source = text as NSString
        let offset = min(selection.location, source.length)
        let queryOffset = offset < source.length && source.character(at: offset) != 10 && source
            .character(at: offset) != 13
            ? NSMaxRange(source.rangeOfComposedCharacterSequence(at: offset)) : offset
        let target = metrics.position(at: queryOffset)
        pendingPreviewNavigation = (documentURL, target, documentVersion, reportFailure, following)
        recordOperation("preview.jump.queued", ["line": String(target.line), "version": String(documentVersion)])
        sendPendingPreviewNavigation()
    }

    private func sendPendingPreviewNavigation() {
        guard let pending = pendingPreviewNavigation else {
            return
        }
        guard pending.url == documentURL, pending.version == documentVersion,
              !pending.following || previewReading.followsWriting
        else {
            pendingPreviewNavigation = nil
            return
        }
        guard serviceReady, previewReadyForNavigation, !previewStale else {
            return
        }
        pendingPreviewNavigation = nil
        let generation = serviceGeneration
        let start = metrics.offset(at: TextPosition(line: pending.position.line, character: 0))
        let end = metrics.offset(at: pending.position)
        let column = (text as NSString).substring(with: NSRange(location: start, length: end - start)).utf8.count
        Task {
            guard generation == serviceGeneration, pending.url == documentURL,
                  pending.version == documentVersion, !pending.following || previewReading.followsWriting
            else {
                return
            }
            do {
                _ = try await client.command(
                    "tinymist.scrollPreview",
                    arguments: [
                        "leftblank",
                        [
                            "event": "panelScrollTo",
                            "filepath": pending.url.path,
                            "line": pending.position.line,
                            "character": column,
                        ],
                    ],
                )
                recordOperation(
                    "preview.jump.sent",
                    ["line": String(pending.position.line), "version": String(pending.version)],
                )
            } catch {
                recordOperation("preview.jump.failed", ["error": error.localizedDescription])
                if generation == serviceGeneration, pending.reportFailure {
                    showMessage(error.localizedDescription)
                }
            }
        }
    }

    func exportPDF() {
        recordOperation("export.dialog")
        guard serviceReady,
              !exporting
        else {
            showMessage(L10n.text("Please wait for the typesetting service to be ready."))
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("Export PDF")
        panel.nameFieldStringValue = (managedTitle?.replacingOccurrences(of: "/", with: "-")
            ?? compilationURL.deletingPathExtension().lastPathComponent) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        present(panel) { [weak self] destination in
            Task { @MainActor in
                guard let self else {
                    return
                }
                do { try await self.exportPDF(to: destination) }
                catch { self.showMessage(error.localizedDescription, persistent: true) }
            }
        }
    }

    func exportPDF(to destination: URL) async throws {
        try PackageSource.requireWritable(destination, packageCache: packageCache)
        guard serviceReady,
              !exporting
        else {
            throw ServiceError.remote(L10n.text("Please wait for the typesetting service to be ready."))
        }
        recordOperation("export.begin")
        exporting = true
        defer { exporting = false }
        do {
            let (data, version) = try await compiledPDF()
            try data.write(to: destination, options: .atomic)
            recordOperation("export.finished", ["exportedVersion": String(version)])
            showMessage(version == documentVersion ? L10n
                .format("PDF exported: %@", destination.lastPathComponent) : L10n
                .text("PDF exported using the document version from when export began."))
        } catch { recordOperation("export.failed", ["error": error.localizedDescription])
            throw error
        }
    }

    func printDocument() {
        Task { @MainActor in
            do {
                let operation = try await makePrintOperation()
                operation.run()
            } catch { showMessage(error.localizedDescription, persistent: true) }
        }
    }

    func makePrintOperation() async throws -> NSPrintOperation {
        guard serviceReady, !exporting,
              !isLibraryHome
        else {
            throw ServiceError.remote(L10n.text("Please wait for the typesetting service to be ready."))
        }
        exporting = true
        defer { exporting = false }
        let (data, _) = try await compiledPDF()
        guard let document = PDFDocument(data: data), document.pageCount > 0,
              let operation = document.printOperation(
                  for: NSPrintInfo.shared.copy() as? NSPrintInfo,
                  scalingMode: .pageScaleDownToFit,
                  autoRotate: true,
              )
        else {
            throw ServiceError.remote(L10n.text("The typesetting service did not produce a valid PDF."))
        }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    private func compiledPDF() async throws -> (Data, Int) {
        try flushChanges()
        let version = documentVersion
        let result = try await client.command("tinymist.exportPdf", arguments: [compilationURL.path])
        guard let path = result["path"].string
        else {
            throw ServiceError
                .remote(L10n.text("The document cannot be compiled. Resolve the errors before exporting."))
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.starts(with: Data("%PDF".utf8))
        else {
            throw ServiceError.remote(L10n.text("The typesetting service did not produce a valid PDF."))
        }
        return (data, version)
    }

    func requestCompletion(automatic: Bool = false) {
        guard serviceReady, !paletteOpen, !isLibraryHome, objectEditSession == nil, layout != .preview,
              let editor, !editor.hasMarkedText(), editor.string == text
        else {
            return
        }
        let version = documentVersion, generation = serviceGeneration
        let caret = selection, source = text, url = documentURL
        editor.dismissTypingAssistance()
        let requestID = editor.typingRequestID
        editor.typingTask = Task { [weak self, weak editor] in
            guard let self, let editor else {
                return
            }
            defer {
                // A finished request must not keep Escape bound to invisible assistance.
                if requestID == editor.typingRequestID {
                    editor.typingTask = nil
                }
            }
            let context = await TypingContext.resolve(source: source, selection: caret)
            guard !Task.isCancelled, !automatic || context != nil else {
                return
            }
            do {
                try flushChanges()
                let params: [String: Any] = [
                    "textDocument": ["uri": url.absoluteString],
                    "position": TextPosition(offset: caret.location, in: source).json,
                ]
                var items: [SourceCompletion] = []
                var signature: LanguageSignature?
                if !automatic || context?.wantsCompletion == true {
                    let result = try await client.request("textDocument/completion", params.merging([
                        "context": ["triggerKind": 1],
                    ]) { _, new in new })
                    items = LanguageAssistance.completions(result, source: source, selection: caret)
                }
                if !Task.isCancelled, context?.wantsSignature == true, client.supports("signatureHelpProvider") {
                    signature = try await LanguageAssistance.signatureHelp(client.request(
                        "textDocument/signatureHelp",
                        params,
                    ))
                }
                guard !Task.isCancelled, version == documentVersion, generation == serviceGeneration,
                      url == documentURL, source == text, caret == selection, !paletteOpen,
                      layout != .preview, !editor.hasMarkedText(), requestID == editor.typingRequestID
                else {
                    return
                }
                editor.presentTypingAssistance(
                    items,
                    signature: signature,
                    source: source,
                    selection: caret,
                    requestID: requestID,
                    prefix: context?.prefix ?? "",
                )
                if !automatic, items.isEmpty, signature == nil {
                    showMessage(L10n.text("No completions are available here."))
                }
            } catch {
                if !automatic, !Task.isCancelled, generation == serviceGeneration,
                   url == documentURL, version == documentVersion, requestID == editor.typingRequestID
                {
                    showMessage(error.localizedDescription)
                }
            }
        }
    }

    private func receive(_ method: String, _ params: JSONValue) {
        if method == "textDocument/publishDiagnostics", let uri = params["uri"].string, let url = URL(string: uri),
           url.isFileURL
        {
            if url == documentURL, let version = params["version"].int, version < documentVersion {
                return
            }
            diagnosticsByURI[uri] = params["diagnostics"].array.map { item in
                DiagnosticItem(
                    message: item["message"].string ?? L10n.text("Unknown Issue"),
                    severity: item["severity"].int ?? 1,
                    position: TextPosition(
                        line: item["range"]["start"]["line"].int ?? 0,
                        character: item["range"]["start"]["character"].int ?? 0,
                    ),
                    url: url,
                )
            }
            diagnostics = diagnosticsByURI.keys.sorted().flatMap { diagnosticsByURI[$0] ?? [] }
            recordOperation("diagnostics.updated", ["count": String(diagnostics.count)])
            if diagnostics.contains(where: { $0.severity == 1 }) {
                previewStale = true
                serviceStatus = hasSuccessfulPreview ? "Showing Last Preview · Check Source" : "Document Needs Attention"
            }
        } else if method == "tinymist/compileStatus" || method == "tinymist/status" {
            recordOperation("compile.status", ["status": params["status"].string ?? "unknown"])
            if let status = params["status"].string {
                switch status {
                case "compiling": previewStale = true
                    serviceStatus = "Typesetting"
                case "compileError":
                    previewStale = true
                    serviceStatus = hasSuccessfulPreview ? "Showing Last Preview · Check Source" : "Document Needs Attention"
                case "compileSuccess":
                    hasSuccessfulPreview = true
                    previewStale = documentVersion != sentVersion
                    serviceStatus = previewStale ? "Typesetting" : "Preview Updated"
                    sendPendingPreviewNavigation()
                default: break
                }
            }
        }
    }

    private func showDocument(_ params: JSONValue) {
        guard let target = SourceLocation(params) else {
            return
        }
        previewReturnLayout = layout
        previewReading.rememberReturnPosition()
        let url = target.url
        if url.standardizedFileURL != documentURL.standardizedFileURL, !open(url, preservingMain: true) {
            return
        }
        jump(to: target.position.offset(in: text), synchronizePreview: false)
    }

    func showDiagnostic(_ item: DiagnosticItem) {
        checksOpen = false
        if item.url != documentURL, !open(item.url, preservingMain: true) {
            return
        }
        jump(to: item.position.offset(in: text))
    }

    func showMessage(_ value: String, persistent: Bool = false) {
        messageTask?.cancel()
        message = value
        if !persistent {
            messageTask = Task {
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                message = nil
            }
        }
    }

    func prepareToClose() -> Bool {
        saveTask?.cancel()
        if fileURL != nil, text != savedText {
            save()
        }
        if saveRecovery() {
            return true
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("Your Document Has Not Been Saved Safely")
        alert.informativeText = L10n
            .text("The recovery copy could not be written. Save to a writable location before quitting.")
        alert.addButton(withTitle: L10n.text("Return to Document"))
        alert.addButton(withTitle: L10n.text("Save As…"))
        if alert.runModal() == .alertSecondButtonReturn {
            saveAs()
        }
        return false
    }

    func shutdown() {
        agentConnection.stop()
        dismissAssistance()
        previewFollowTask?.cancel()
        recordOperation("session.end")
        saveTask?.cancel()
        syncTask?.cancel()
        syntaxTask?.cancel()
        library.stop()
        client.stop()
    }

    func recordOperation(_ event: String, _ fields: [String: String] = [:]) {
        var context = fields
        context["documentVersion"] = String(documentVersion)
        context["selection"] = "\(selection.location):\(selection.length)"
        actionLog?.record(event, fields: context)
    }

    func recordKeyEvent(_ event: NSEvent, stage: String) {
        let special: [UInt16: String] = [
            36: "Return",
            48: "Tab",
            51: "Delete",
            53: "Escape",
            76: "Enter",
            115: "Home",
            116: "PageUp",
            117: "ForwardDelete",
            119: "End",
            121: "PageDown",
            123: "Left",
            124: "Right",
            125: "Down",
            126: "Up",
        ]
        let flags = event.modifierFlags
        let modifiers = [
            (NSEvent.ModifierFlags.command, "cmd"),
            (.control, "ctrl"),
            (.option, "option"),
            (.shift, "shift"),
        ].filter { flags.contains($0.0) }.map(\.1).joined(separator: "+")
        // Never retain printable input or search terms. Only shortcut chords and
        // navigation keys need their actual key identity for diagnosing routing.
        let shortcut = event.charactersIgnoringModifiers?.uppercased() ?? "keyCode:\(event.keyCode)"
        let key = special[event.keyCode] ?? (flags.isDisjoint(with: [.command, .control]) ? "text" : shortcut)
        recordOperation(
            "key.down",
            [
                "key": key,
                "modifiers": modifiers,
                "stage": stage,
                "panel": activeCommand != nil ? "parameters" :
                    (searchMode && paletteOpen ? "search" : (paletteOpen ? "groups" : "editor")),
                "markedText": String((event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true),
            ],
        )
    }

    func revealLogs() {
        guard let actionLog else {
            showMessage(
                L10n.text("The diagnostic log folder is not writable."),
                persistent: true,
            )
            return
        }
        recordOperation("logs.reveal")
        NSWorkspace.shared.activateFileViewerSelecting([actionLog.fileURL])
    }

    static var welcome: String {
        WelcomeDocument.source()
    }
}

extension Workspace {
    func hoverHelp(at offset: Int) async -> LanguageHover? {
        guard serviceReady, client.supports("hoverProvider"), !paletteOpen, !isLibraryHome,
              layout != .preview, !documentTransitionInProgress, !applyingCommand,
              assistance == nil, editor?.hasMarkedText() != true,
              offset >= 0, offset < text.utf16.count
        else {
            return nil
        }
        let generation = serviceGeneration, version = documentVersion, url = documentURL, caret = selection
        do {
            try flushChanges()
            let result = try await client.request("textDocument/hover", [
                "textDocument": ["uri": url.absoluteString],
                "position": TextPosition(offset: offset, in: text).json,
            ])
            guard !Task.isCancelled, generation == serviceGeneration, version == documentVersion,
                  url == documentURL, caret == selection, assistance == nil, !paletteOpen,
                  layout != .preview, !documentTransitionInProgress, editor?.hasMarkedText() != true
            else {
                return nil
            }
            let help = LanguageAssistance.hover(result)
            recordOperation("hover.response", ["hasHelp": String(help != nil)])
            return help
        } catch {
            recordOperation("hover.failed", ["error": error.localizedDescription])
            // Passive help never interrupts writing with connection/error messages.
            return nil
        }
    }

    func dismissAssistance() {
        editor?.dismissTypingAssistance()
        assistanceRequest = UUID()
        assistanceTask?.cancel()
        assistanceTask = nil
        assistance = nil
        editor?.dismissAssistance()
    }

    func requestAssistance(_ kind: WritingAssistance.Kind) {
        guard serviceReady, !paletteOpen, !isLibraryHome, objectEditSession == nil, layout != .preview,
              let editor, !editor.hasMarkedText()
        else {
            return
        }
        dismissAssistance()
        let requestID = assistanceRequest, generation = serviceGeneration
        let version = documentVersion, source = text, url = documentURL, caret = selection
        let start = TextPosition(offset: caret.location, in: source)
        let end = TextPosition(offset: NSMaxRange(caret), in: source)
        assistanceTask = Task {
            do {
                try flushChanges()
                var hover: LanguageHover?, signature: LanguageSignature?, actions: [SourceCodeAction] = []
                let params: [String: Any] = ["textDocument": ["uri": url.absoluteString], "position": start.json]
                if kind == .help {
                    if client.supports("hoverProvider") {
                        hover = try await LanguageAssistance.hover(client.request("textDocument/hover", params))
                    }
                    guard !Task.isCancelled else {
                        return
                    }
                    if client.supports("signatureHelpProvider") {
                        signature = try await LanguageAssistance.signatureHelp(client.request(
                            "textDocument/signatureHelp",
                            params,
                        ))
                    }
                } else if client.supports("codeActionProvider") {
                    let result = try await client.request(
                        "textDocument/codeAction",
                        ["textDocument": ["uri": url.absoluteString],
                         "range": [
                             "start": start.json,
                             "end": end.json,
                         ], "context": [
                             "diagnostics": [],
                             "triggerKind": 1,
                         ]],
                    )
                    actions = LanguageAssistance.codeActions(result, source: source, documentURL: url, version: version)
                }
                guard !Task.isCancelled, requestID == assistanceRequest, generation == serviceGeneration,
                      version == documentVersion, url == documentURL, caret == selection,
                      !paletteOpen, layout != .preview, !editor.hasMarkedText()
                else {
                    return
                }
                let result = WritingAssistance(
                    kind: kind,
                    source: source,
                    documentURL: url,
                    revision: version,
                    hover: hover,
                    signature: signature,
                    actions: actions,
                )
                assistance = result
                editor.presentAssistance(result)
                recordOperation("assistance.presented", ["kind": kind.rawValue, "actions": String(actions.count)])
            } catch {
                guard requestID == assistanceRequest, generation == serviceGeneration else {
                    return
                }
                showMessage(error.localizedDescription)
            }
        }
    }

    func applyContextAction(_ action: SourceCodeAction) {
        guard let context = assistance, context.source == text, context.documentURL == documentURL,
              action.documentURL == documentURL, action.sourceVersion == documentVersion,
              let editor, editor.isEditable, !editor.hasMarkedText(), !paletteOpen, !documentTransitionInProgress
        else {
            dismissAssistance()
            return
        }
        do {
            let updated = try TextEditing.applying(action.edits, to: text)
            let start = action.edits.map(\.range.location).min() ?? 0
            let end = action.edits.map { NSMaxRange($0.range) }.max() ?? start
            let length = end - start + updated.utf16.count - text.utf16.count
            let replacement = (updated as NSString).substring(with: NSRange(location: start, length: length))
            dismissAssistance()
            editor.insertSnippet(Snippet(text: replacement), replacing: NSRange(location: start, length: end - start))
            editor.undoManager?.setActionName(L10n.text("Actions at Cursor"))
            recordOperation("assistance.applied", ["kind": action.kind ?? "edit", "edits": String(action.edits.count)])
        } catch { showMessage(error.localizedDescription) }
    }

    var canNavigateSource: Bool {
        serviceReady && client.supports("definitionProvider") && !paletteOpen && !isLibraryHome &&
            !documentTransitionInProgress && !applyingCommand && editor?.hasMarkedText() != true
    }

    func goToDefinition() {
        guard canNavigateSource else {
            return
        }
        dismissAssistance()
        let requestID = assistanceRequest
        let version = documentVersion, generation = serviceGeneration, url = documentURL, caret = selection,
            origin = position
        assistanceTask = Task {
            do {
                try flushChanges()
                let response = try await client.request(
                    "textDocument/definition",
                    ["textDocument": ["uri": url.absoluteString], "position": origin.json],
                )
                guard !Task.isCancelled, requestID == assistanceRequest, url == documentURL,
                      generation == serviceGeneration, version == documentVersion, caret == selection,
                      canNavigateSource
                else {
                    return
                }
                let destination = response.array.first ?? response
                guard let uri = destination["uri"].string ?? destination["targetUri"].string,
                      let target = URL(string: uri), target.isFileURL,
                      target.host == nil || target.host?.isEmpty == true || target.host == "localhost",
                      target.query == nil, target.fragment == nil
                else {
                    requestAssistance(.help)
                    return
                }
                let range = destination["targetSelectionRange"]
                    .isNull ? destination["range"] : destination["targetSelectionRange"]
                guard let line = range["start"]["line"].int, let column = range["start"]["character"].int, line >= 0,
                      column >= 0
                else {
                    return
                }
                if target == documentURL {
                    navigationHistory.append((url, origin, mainFileURL))
                } else if !open(target, preservingMain: true) {
                    return
                }
                jump(to: TextPosition(line: line, character: column).offset(in: text))
                recordOperation("navigation.definition")
            } catch {
                if !Task.isCancelled, requestID == assistanceRequest, generation == serviceGeneration {
                    showMessage(error.localizedDescription)
                }
            }
        }
    }

    func navigateBack() {
        guard !documentTransitionInProgress, !applyingCommand, editor?.hasMarkedText() != true else {
            return
        }
        dismissAssistance()
        guard let index = navigationHistory.indices.last else {
            return
        }
        restoreNavigation(at: index)
    }

    private func restoreNavigation(at index: Int) {
        let destination = navigationHistory[index]
        if destination.url != documentURL,
           !open(destination.url, preservingMain: true, rememberSource: false)
        {
            return
        }
        mainFileURL = destination.main
        navigationHistory.removeSubrange(index...)
        jump(to: destination.position.offset(in: text))
    }

    func closeDocument() {
        guard !isLibraryHome, !documentTransitionInProgress, !applyingCommand else {
            return
        }
        window?.makeFirstResponder(nil)
        closePalette()
        if let index = navigationHistory.lastIndex(where: { $0.url != documentURL }) {
            restoreNavigation(at: index)
        } else if let mainFileURL, mainFileURL != documentURL {
            // A recovered session may have a compilation entry but no in-memory history.
            _ = open(mainFileURL)
        } else if preserveCurrent() {
            closeToRecentDocument()
        }
    }

    /// Closing a library document returns to the one opened before it, like closing a tab.
    /// With nothing left to return to, the template page offers a fresh start.
    private func closeToRecentDocument() {
        if let managedDocumentID {
            library.forgetRecent(managedDocumentID)
        }
        let candidates = library.reopenableRecentIDs
        guard !candidates.isEmpty else {
            showLibraryHome()
            openDiscovery(.templates)
            return
        }
        recordOperation("document.closeToRecent")
        if text != savedText {
            // Already preserved as a draft copy; clear it so the next open cannot copy it twice.
            showLibraryHome()
        }
        documentTransitionInProgress = true
        editor?.isEditable = false
        Task { [weak self] in
            guard let self else {
                return
            }
            let reopened = await library.reopenRecent(candidates)
            documentTransitionInProgress = false
            editor?.isEditable = editorIsEditable
            if !reopened {
                if !isLibraryHome {
                    showLibraryHome()
                }
                openDiscovery(.templates)
            }
        }
    }
}
