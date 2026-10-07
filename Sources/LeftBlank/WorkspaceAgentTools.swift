import AppKit
import Foundation
import LeftBlankCore

extension Workspace: AgentToolHost {
    func agentState() -> JSONValue {
        .object(["platform": .string("macos"), "app_bundle_id": .string(AppDistribution.current.bundleIdentifier),
                 "app_version": .string(Bundle.main
                     .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"),
                 "distribution": .string(AppDistribution.current == .preview ? "preview" : "standard"),
                 "engine_ready": .bool(serviceReady),
                 "open_documents": .array(managedDocumentID.map { [.string($0.uuidString)] } ?? [])])
    }

    func agentLiveText(in document: LibraryDocument) throws -> (path: String, text: String)? {
        guard !isLibraryHome, documentURL.path.hasPrefix(document.folderURL.path + "/") else {
            return nil
        }
        let path = String(documentURL.path.dropFirst(document.folderURL.path.count + 1))
        _ = try AgentProjectFiles.url(path, in: document.folderURL)
        return (path, text)
    }

    func agentValidate(_ changes: [AgentPatch.Change], document: LibraryDocument) throws {
        guard !documentTransitionInProgress, !library.busy else {
            throw AgentToolError(
                "busy",
                "The library is changing.",
            )
        }
        for change in changes {
            let url = try AgentProjectFiles.url(change.path, in: document.folderURL)
            try PackageSource.requireWritable(url, packageCache: packageCache)
            if !isLibraryHome, documentURL.standardizedFileURL == url.standardizedFileURL {
                guard change.text != nil
                else {
                    throw AgentToolError("file_open", "Close the file before deleting it.")
                }
                guard let editor, editor.isEditable, !editor.hasMarkedText(), !paletteOpen, objectEditSession == nil,
                      editor.string == text
                else {
                    throw AgentToolError("editor_busy", "Finish the current native edit before applying agent changes.")
                }
            }
        }
    }

    func agentApply(_ change: AgentPatch.Change, before: Data?, document: LibraryDocument) throws -> String {
        guard !documentTransitionInProgress, !library.busy else {
            throw AgentToolError(
                "busy",
                "The application is changing documents.",
            )
        }
        let url = try AgentProjectFiles.url(change.path, in: document.folderURL)
        try PackageSource.requireWritable(url, packageCache: packageCache)
        if !isLibraryHome, documentURL.standardizedFileURL == url.standardizedFileURL {
            guard let replacement = change.text else {
                throw AgentToolError(
                    "file_open",
                    "Close the source file before deleting it.",
                )
            }
            guard Data(text.utf8) == before
            else {
                throw AgentToolError("revision_conflict", "The live buffer changed.")
            }
            guard let editor, !editor.hasMarkedText(), !paletteOpen, objectEditSession == nil,
                  editor.string == text
            else {
                throw AgentToolError("editor_busy", "Finish the current native edit before applying agent changes.")
            }
            guard replacement != text else {
                return text == savedText ? "saved" : "unsaved"
            }
            // Use one minimal replacement, preserving native undo and caret handling.
            let old = Array(text.utf16), new = Array(replacement.utf16)
            var start = 0, suffix = 0
            while start < min(old.count, new.count), old[start] == new[start] {
                start += 1
            }
            while suffix < min(old.count, new.count) - start,
                  old[old.count - suffix - 1] == new[new.count - suffix - 1]
            {
                suffix += 1
            }
            // Do not split surrogate pairs at the changed span boundaries.
            if start > 0, start < old.count, (0xDC00 ... 0xDFFF).contains(old[start]) {
                start -= 1
            }
            if suffix > 0, suffix < old.count, (0xDC00 ... 0xDFFF).contains(old[old.count - suffix]) {
                suffix -= 1
            }
            let content = (replacement as NSString).substring(with: NSRange(
                location: start,
                length: new.count - start - suffix,
            ))
            editor.insertSnippet(
                Snippet(text: content),
                replacing: NSRange(location: start, length: old.count - start - suffix),
            )
            editor.undoManager?.setActionName(L10n.text("Agent Edit"))
            guard text == replacement
            else {
                throw AgentToolError("editor_busy", "The editor did not accept the change.")
            }
            save()
            return savedText == replacement ? "saved" : "save_failed"
        }
        try AgentProjectFiles.write(change.text, path: change.path, root: document.folderURL, expected: before)
        return "saved"
    }

    func agentPrepareMetadataChange(_ document: LibraryDocument?, trashing: Bool) throws {
        guard !documentTransitionInProgress, !library.busy else {
            throw AgentToolError(
                "busy",
                "The library is changing.",
            )
        }
        if let document, managedDocumentID == document.id {
            guard editor?.hasMarkedText() != true else {
                throw AgentToolError(
                    "editor_busy",
                    "Finish input method composition first.",
                )
            }
            if trashing, text != savedText {
                throw AgentToolError(
                    "unsaved_changes",
                    "Save the open document before moving it to trash.",
                )
            }
        }
        agentMetadataChangeInProgress = true
        documentTransitionInProgress = true
        editor?.isEditable = false
    }

    func agentFinishMetadataChange(_ document: LibraryDocument?) async {
        if let document, managedDocumentID == document.id, document.isTrashed {
            showLibraryHome()
        }
        await library.refresh()
        agentMetadataChangeInProgress = false
        documentTransitionInProgress = false
        editor?.isEditable = editorIsEditable
        onTitleChange?(title)
    }

    func agentDiagnostics(in document: LibraryDocument) -> [JSONValue] {
        diagnostics.compactMap { diagnostic in
            guard diagnostic.url.path.hasPrefix(document.folderURL.path + "/") else {
                return nil
            }
            let path = String(diagnostic.url.path.dropFirst(document.folderURL.path.count + 1))
            let severity = [1: "error", 2: "warning", 3: "info", 4: "hint"][diagnostic.severity] ?? "info"
            let position: JSONValue = .object([
                "line": .number(Double(diagnostic.position.line)),
                "character": .number(Double(diagnostic.position.character)),
            ])
            return .object([
                "path": .string(path),
                "message": .string(AgentTools.excerpt(diagnostic.message, limit: 2000)),
                "severity": .string(severity),
                "range": .object(["start": position, "end": position]),
                "position_encoding": .string("utf-16"),
                "freshness": .string("unknown"),
                "range_is_point": .bool(true),
            ])
        }
    }

    func agentCompile(_ snapshot: AgentProjectSnapshot, entry: String) async throws -> JSONValue {
        try await agentEngine(snapshot, entry: entry) { session in
            guard let session = session as? IsolatedAgentEngine else {
                throw ServiceError.unavailable
            }
            let output = try await session.run(command: "tinymist.exportPdf", options: nil)
            let diagnostics = JSONValue.array(output.diagnostics)
            guard output.status == .completed else {
                return .object(["status": .string(output.status.rawValue), "project_sources_compiled": .bool(false),
                                "engine_message": output.message.map(JSONValue.string) ?? .null,
                                "diagnostics": diagnostics])
            }
            let pdf = output.response["path"].string.flatMap { path -> Data? in
                let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(session.directory.path + "/") else {
                    return nil
                }
                return try? Data(contentsOf: url)
            }
            let successful = pdf?.starts(with: Data("%PDF".utf8)) == true
            // A fresh engine/output directory rules out stale PDFs. Package and system-font
            // inputs are not yet frozen, so do not claim the stronger design guarantee.
            return .object(["status": .string(successful ? "unverified" : "failed"),
                            "project_sources_compiled": .bool(successful),
                            "verification": .string("project_snapshot"),
                            "limitation": .string(
                                "Project files and unsaved text were captured. External packages and system fonts are not pinned yet; strict compilation verification is unavailable.",
                            ),
                            "diagnostics": diagnostics])
        }
    }

    /// Copies the snapshot to a private folder and starts a fresh engine, so neither the live engine
    /// nor an earlier export can affect results. The engine and folder end with the call.
    func agentEngine<T>(
        _ snapshot: AgentProjectSnapshot,
        entry: String,
        _ body: (any AgentEngineSession) async throws -> T,
    ) async throws -> T {
        let directory = stateDirectory.appendingPathComponent("AgentCompiles/" + UUID().uuidString)
        let root = directory.appendingPathComponent("Project"), output = directory.appendingPathComponent("Output")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (path, data) in snapshot.files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try data.write(to: file, options: .atomic)
            }
        }.value
        try Task.checkCancellation()
        let session = IsolatedAgentEngine(directory: directory, source: root.appendingPathComponent(entry))
        defer { session.engine.stop() }
        await session.start(text: snapshot.texts[entry] ?? "", output: output)
        return try await body(session)
    }

    func agentEditorContext(in document: LibraryDocument) -> AgentEditorContext? {
        guard !isLibraryHome, managedDocumentID == document.id else {
            return nil
        }
        // A hidden preview keeps its last position, which the user no longer sees.
        let page = layout == .writing ? nil : previewReading.anchor.map { $0.page + 1 }
        var file: AgentEditorContext.File?
        if documentURL.path.hasPrefix(document.folderURL.path + "/") {
            let path = String(documentURL.path.dropFirst(document.folderURL.path.count + 1))
            if (try? AgentProjectFiles.url(path, in: document.folderURL)) != nil {
                file = AgentEditorContext.File(
                    path: path,
                    text: text,
                    selection: editor?.selectedRange() ?? selection,
                    visible: visibleSourceRange(),
                    saved: text == savedText,
                )
            }
        }
        return AgentEditorContext(layout: layout.rawValue, previewPage: page, file: file)
    }

    private func visibleSourceRange() -> NSRange? {
        guard layout != .preview, let editor, let manager = editor.layoutManager, let container = editor.textContainer
        else {
            return nil
        }
        let rect = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        guard !rect.isEmpty else {
            return nil
        }
        let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
        return manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }
}

@MainActor
private final class IsolatedAgentEngine: AgentEngineSession {
    let engine = TinymistClient()
    let directory: URL
    let source: URL
    private var root: URL {
        directory.appendingPathComponent("Project")
    }

    private var started = false
    private var issues: [String: [JSONValue]] = [:]

    init(directory: URL, source: URL) {
        self.directory = directory
        self.source = source
    }

    func start(text: String, output: URL) async {
        let root = root
        engine.onNotification = { [weak self] method, params in
            guard method == "textDocument/publishDiagnostics", let uri = params["uri"].string,
                  let url = URL(string: uri),
                  url.path.hasPrefix(root.path + "/")
            else {
                return
            }
            let path = String(url.path.dropFirst(root.path.count + 1))
            self?.issues[path] = params["diagnostics"].array.prefix(100).map { item in
                .object([
                    "path": .string(path),
                    "message": .string(AgentTools.excerpt(item["message"].string ?? "", limit: 2000)),
                    "severity": .string([1: "error", 2: "warning", 3: "info",
                                         4: "hint"][item["severity"].int ?? 1] ?? "info"),
                    "range": item["range"],
                    "position_encoding": .string("utf-16"),
                ])
            }
        }
        do {
            try await engine.start(root: root, outputDirectory: output)
            try engine.open(source, text: text, version: 1)
            started = true
        } catch {}
    }

    func run(_ export: AgentEngineExport) async throws -> AgentEngineOutput {
        try await run(command: export.command, options: export.options)
    }

    /// Without options the command writes into the private output folder; with them, data stays in memory.
    func run(command: String, options: JSONValue?) async throws -> AgentEngineOutput {
        guard started else {
            return finish(.engineUnavailable)
        }
        let response: JSONValue
        do {
            let arguments: [Any] = options.map { [source.path, $0.foundationValue, ["write": false]] } ?? [source.path]
            response = try await engine.command(command, arguments: arguments)
        } catch ServiceError.timeout { return finish(.timeout) }
        catch let ServiceError.remote(message) { return finish(.failed, message: message) }
        catch { return finish(.engineUnavailable) }
        try Task.checkCancellation()
        return finish(.completed, response: response)
    }

    private func finish(
        _ status: AgentEngineOutput.Status,
        response: JSONValue = .null,
        message: String? = nil,
    ) -> AgentEngineOutput {
        AgentEngineOutput(
            status: status,
            response: response,
            message: message.map { AgentTools.excerpt(
                $0.replacingOccurrences(of: directory.path, with: "<compile>"), limit: 2000,
            ) },
            diagnostics: Array(issues.keys.sorted().flatMap { issues[$0] ?? [] }.prefix(100)),
        )
    }
}
