import Foundation

@MainActor
public protocol AgentToolHost: AnyObject {
    func agentState() -> JSONValue
    func agentLiveText(in document: LibraryDocument) throws -> (path: String, text: String)?
    func agentValidate(_ changes: [AgentPatch.Change], document: LibraryDocument) throws
    func agentApply(_ change: AgentPatch.Change, before: Data?, document: LibraryDocument) throws -> String
    func agentPrepareMetadataChange(_ document: LibraryDocument?, trashing: Bool) throws
    func agentFinishMetadataChange(_ document: LibraryDocument?) async
    func agentDiagnostics(in document: LibraryDocument) -> [JSONValue]
    func agentCompile(_ snapshot: AgentProjectSnapshot, entry: String) async throws -> JSONValue
    /// Runs `body` on a fresh engine over a private copy of the snapshot; both end with the call.
    func agentEngine<T>(
        _ snapshot: AgentProjectSnapshot,
        entry: String,
        _ body: (any AgentEngineSession) async throws -> T,
    ) async throws -> T
    /// Nil unless the document is open in this host.
    func agentEditorContext(in document: LibraryDocument) -> AgentEditorContext?
}

/// All callers use this dispatcher. The macOS transport supplies a trusted grant and a platform host.
@MainActor
public final class AgentToolDispatcher {
    let library: DocumentLibrary
    let history: DocumentHistory
    weak var host: (any AgentToolHost)?
    let epoch = UUID().uuidString
    /// Read-only tools share the gate; writes run alone so reads never see a half-applied change.
    let gate = AgentToolGate()
    /// Each compile starts its own engine, so compiles run one at a time beside other reads.
    let compiles = AgentToolGate()
    var cachedWrites: [String: (fingerprint: String, result: AgentToolResult)] = [:]
    var writeOrder: [String] = []
    var cursors: [String: (query: String, snapshot: String, offset: Int)] = [:]
    var cursorOrder: [String] = []

    public init(library: DocumentLibrary, history: DocumentHistory, host: any AgentToolHost) {
        self.library = library
        self.history = history
        self.host = host
    }

    public func call(_ name: String, arguments: JSONValue, access: AgentToolAccess) async -> AgentToolResult {
        let exclusive = AgentTools.definitions.first(where: { $0.name == name })?.readOnly != true
        let compiling = Self.engineTools.contains(name)
        if compiling {
            guard await compiles.acquire(exclusive: true) else {
                return AgentToolRecovery.enrich(failure(CancellationError()), tool: name, arguments: arguments)
            }
        }
        defer {
            if compiling {
                compiles.release(exclusive: true)
            }
        }
        guard await gate.acquire(exclusive: exclusive) else {
            return AgentToolRecovery.enrich(failure(CancellationError()), tool: name, arguments: arguments)
        }
        defer { gate.release(exclusive: exclusive) }
        do {
            try Task.checkCancellation()
            guard let definition = AgentTools.definitions.first(where: { $0.name == name }) else {
                throw AgentToolError("unknown_tool", "Unknown tool name.")
            }
            let args = try AgentArguments(arguments, definition: definition)
            guard definition.readOnly || access.canWrite else {
                throw AgentToolError(
                    "permission_denied",
                    "This connection is read-only.",
                )
            }
            var key: String?, fingerprint = ""
            if !definition.readOnly {
                let request = args.string("request_id")
                guard !request.isEmpty, request.utf8.count <= 128 else {
                    throw AgentToolError(
                        "invalid_params",
                        "request_id must contain 1–128 bytes.",
                    )
                }
                let cacheKey = access.id.uuidString + ":" + request
                key = cacheKey
                fingerprint = try AgentTools.digest(Data(name.utf8) + (AgentTools.canonical(arguments)))
                if let cached = cachedWrites[cacheKey] {
                    guard cached.fingerprint == fingerprint else {
                        throw AgentToolError(
                            "request_id_conflict",
                            "This request_id was already used for different arguments.",
                        )
                    }
                    return cached.result
                }
            }
            let result: AgentToolResult
            do { result = try await execute(name, args: args, access: access) }
            catch { result = failure(error) }
            let recovered = AgentToolRecovery.enrich(result, tool: name, arguments: arguments)
            if let key {
                cachedWrites[key] = (fingerprint, recovered)
                writeOrder.append(key)
                if writeOrder.count > 256 {
                    cachedWrites.removeValue(forKey: writeOrder.removeFirst())
                }
            }
            return recovered
        } catch { return AgentToolRecovery.enrich(failure(error), tool: name, arguments: arguments) }
    }

    func failure(_ error: Error) -> AgentToolResult {
        let issue: AgentToolError
        if let error = error as? AgentToolError {
            issue = error
        } else if error is CancellationError {
            issue = AgentToolError(
                "cancelled",
                "The request was cancelled. Check results before retrying writes.",
            )
        } else if let error = error as? DocumentStorageError {
            let code = switch error {
            case .externalChange: "revision_conflict"
            case .invalidUTF8: "not_text"
            case .readOnlyPackage: "read_only_package"
            }
            issue = AgentToolError(code, error.localizedDescription)
        } else if let error = error as? LibraryError {
            let code = switch error {
            case .notFound: "not_found"
            case .invalidTitle: "invalid_params"
            case .invalidMetadata: "invalid_metadata"
            case .invalidProject: "invalid_project"
            case .unsafeResource: "unsafe_path"
            case .destinationExists: "already_exists"
            case .libraryChanged: "revision_conflict"
            case .downloadPending: "download_pending"
            case .unresolvedConflict: "document_conflict"
            case .cloudNotConfigured, .cloudAccountUnavailable, .cloudUnavailable: "unavailable"
            }
            issue = AgentToolError(code, error.localizedDescription)
        } else {
            let native = error as NSError
            let missing = native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError]
                .contains(native.code) || native.domain == NSPOSIXErrorDomain && native.code == Int(ENOENT)
            let denied = native.domain == NSCocoaErrorDomain && [
                NSFileReadNoPermissionError,
                NSFileWriteNoPermissionError,
            ]
            .contains(native.code) || native.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)]
            .contains(native.code)
            issue = AgentToolError(
                missing ? "not_found" : denied ? "filesystem_permission_denied" : "unavailable",
                missing ? "The requested file or directory no longer exists. List current project paths." :
                    denied ? "LeftBlank does not have permission to access the requested file or directory." :
                    "The document operation could not complete. Check the application state and read again.",
            )
        }
        return AgentToolResult(.object(["error": issue.json]), isError: true)
    }

    func execute(_ name: String, args: AgentArguments, access: AgentToolAccess) async throws -> AgentToolResult {
        guard let host else {
            throw AgentToolError("unavailable", "The application has closed.")
        }
        if name == "get_app_state" {
            var state = host.agentState().objectValues
            state["available_tools"] = .array(AgentTools.definitions.filter { access.canWrite || $0.readOnly }
                .map { .string($0.name) })
            state["open_documents"] = .array(state["open_documents"]?.array.filter { value in
                value.string.flatMap(UUID.init(uuidString:)).map(access.permits) ?? false
            } ?? [])
            state["can_write"] = .bool(access.canWrite)
            state["authorized_document_ids"] = access.documentIDs
                .map { .array($0.map { .string($0.uuidString) }.sorted { ($0.string ?? "") < ($1.string ?? "") }) } ??
                .null
            return AgentToolResult(.object(state))
        }
        if name == "list_documents" {
            let docs = try await library.list(
                query: args.string("query"),
                includeTrashed: args.bool("include_trashed", default: false),
                allowedDocumentIDs: access.documentIDs,
            ).filter { access.permits($0.id) }
            let values = docs.map(metadata)
            return try AgentToolResult(page(
                values,
                args: args,
                name: name,
                snapshot: AgentTools.digest(AgentTools.canonical(.array(values))),
                access: access,
            ))
        }
        if name == "create_document" {
            guard access.documentIDs == nil else {
                throw AgentToolError(
                    "permission_denied",
                    "Creating a document requires library-wide access.",
                )
            }
            guard args.string("source").utf8.count <= AgentTools.maximumTextBytes else {
                throw AgentToolError("file_too_large", "Document source exceeds 2 MiB.")
            }
            try host.agentPrepareMetadataChange(nil, trashing: false)
            let document: LibraryDocument
            do { document = try await library.create(title: args.string("title"), text: args.string("source")) }
            catch {
                await host.agentFinishMetadataChange(nil)
                throw error
            }
            await host.agentFinishMetadataChange(document)
            let data = Data(args.string("source").utf8)
            let snapshot = AgentProjectSnapshot(root: document.folderURL, files: ["main.typ": data], omitted: [])
            let projectRevision = projectRevision(snapshot, document: document)
            var description = metadata(document).objectValues
            description["project_revision"] = .string(projectRevision)
            return AgentToolResult(.object([
                "request_id": args["request_id"],
                "status": .string("applied"),
                "document": .object(description),
                "project_revision": .string(projectRevision), "path_base": .string("document_root"),
                "files": .array([.object([
                    "path": .string("main.typ"), "before_revision": .null,
                    "after_revision": .string(revision(data, document: document, path: "main.typ")),
                    "save_status": .string("saved"),
                ])]),
            ]))
        }
        if name == "import_project" {
            return try await importProject(args, access: access)
        }
        let document = try await document(args, access: access)
        if ["rename_document", "trash_document", "restore_document"].contains(name) {
            try host.agentPrepareMetadataChange(document, trashing: name == "trash_document")
            let updated: LibraryDocument
            do {
                let revision = args.string("expected_metadata_revision")
                switch name {
                case "rename_document": updated = try await library.rename(
                        document.id,
                        title: args.string("title"),
                        expectedMetadataRevision: revision,
                    )
                case "trash_document": updated = try await library.trash(
                        document.id,
                        expectedMetadataRevision: revision,
                    )
                default: updated = try await library.restore(document.id, expectedMetadataRevision: revision)
                }
            } catch {
                await host.agentFinishMetadataChange(document)
                throw error
            }
            await host.agentFinishMetadataChange(updated)
            return AgentToolResult(.object([
                "request_id": args["request_id"],
                "status": .string("applied"),
                "document": metadata(updated),
            ]))
        }
        if name == "list_file_versions" {
            let path = args.string("path")
            _ = try AgentProjectFiles.url(path, in: document.folderURL)
            let revisions = try await history.revisions(for: historyKey(document, path: path))
            return AgentToolResult(.object(["versions": .array(revisions.map { revision in .object([
                "version_id": .string(revision.id.uuidString),
                "created_at": .string(revision.createdAt.ISO8601Format()),
                "bytes": .number(Double(revision.bytes)), "reason": .string(revision.reason.rawValue),
            ]) })]))
        }
        if name == "read_file", !args["version_id"].isNull {
            let source = try await historicalText(
                document,
                path: args.string("path"),
                version: args.string("version_id"),
            )
            return try AgentToolResult(read(
                source,
                revision: nil,
                versionID: args.string("version_id"),
                args: args,
                access: access,
            ))
        }
        guard !document.isTrashed else {
            throw AgentToolError(
                "document_trashed",
                "Restore the document before reading or editing its current files.",
            )
        }
        if name == "get_editor_context" {
            return try editorContext(document)
        }
        if name == "get_diagnostics" {
            let values = host.agentDiagnostics(in: document).filter { item in
                (args["path"].isNull || item["path"].string == args.string("path")) &&
                    (args["severity"].isNull || item["severity"].string == args.string("severity"))
            }
            var result = try page(
                values,
                args: args,
                name: name,
                snapshot: AgentTools.digest(AgentTools.canonical(.array(values))),
                access: access,
            ).objectValues
            result["freshness"] = .string("unknown")
            return AgentToolResult(.object(result))
        }
        let paths: Set<String>? = ["read_file", "read_image", "str_replace", "restore_file_version"].contains(name)
            ? [args.string("path")] : nil
        let snapshot = try await capture(document, paths: paths)
        let projectRevision = projectRevision(snapshot, document: document)
        switch name {
        case "get_document":
            var value = metadata(document).objectValues
            value["project_revision"] = .string(projectRevision)
            value["incomplete"] = .bool(!snapshot.omitted.isEmpty)
            return AgentToolResult(.object(value))
        case "list_files": return try AgentToolResult(listFiles(
                snapshot,
                document: document,
                args: args,
                access: access,
            ))
        case "read_file":
            let path = args.string("path")
            _ = try AgentProjectFiles.url(path, in: document.folderURL)
            // Reads are windowed, so UTF-8 text past the 2 MiB edit limit is still readable.
            guard let data = snapshot.files[path], !data.contains(0),
                  let source = String(data: data, encoding: .utf8)
            else {
                throw unreadable(path, snapshot: snapshot)
            }
            return try AgentToolResult(read(
                source,
                revision: revision(data, document: document, path: path),
                versionID: nil,
                args: args,
                access: access,
            ))
        case "read_image":
            let path = args.string("path")
            _ = try AgentProjectFiles.url(path, in: document.folderURL)
            guard let data = snapshot.files[path] else {
                throw unreadable(path, snapshot: snapshot)
            }
            let prepared = try AgentImage.prepare(data)
            return AgentToolResult(.object([
                "path": .string(path),
                "revision": .string(revision(data, document: document, path: path)),
                "mime_type": .string(prepared.image.mimeType),
                "bytes": .number(Double(prepared.image.data.count)),
                "width": .number(Double(prepared.width)),
                "height": .number(Double(prepared.height)),
                "converted": .bool(prepared.converted),
            ]), images: [prepared.image])
        case "search_text": return try AgentToolResult(search(snapshot, document: document, args: args, access: access))
        case "compile_document":
            guard projectRevision == args.string("expected_project_revision") else {
                throw AgentToolError(
                    "revision_conflict",
                    "Read the current project revision before compiling.",
                )
            }
            guard snapshot.omitted.isEmpty else {
                throw AgentToolError(
                    "incomplete_project",
                    "The project contains unavailable files or symlinks.",
                )
            }
            var result = try await host.agentCompile(snapshot, entry: entry(document)).objectValues
            result["compiled_project_revision"] = .string(projectRevision)
            let current = try? await capture(document)
            result["is_current"] = .bool(current
                .map { self.projectRevision($0, document: document) == projectRevision } ?? false)
            // "unverified" compiled cleanly; only its package and font inputs are not pinned.
            let compiled = ["succeeded", "unverified"].contains(result["status"]?.string ?? "")
            return AgentToolResult(.object(result), isError: !compiled)
        case "render_page":
            return try await renderPage(snapshot, document: document, revision: projectRevision, args: args)
        case "query_document": return try await queryDocument(
                snapshot,
                document: document,
                revision: projectRevision,
                args: args,
                access: access,
            )
        default: return try await edit(name, args: args, document: document, snapshot: snapshot)
        }
    }

    /// Missing, unavailable, oversized and binary inputs need different repair steps.
    func unreadable(_ path: String, snapshot: AgentProjectSnapshot) -> AgentToolError {
        let details: [String: JSONValue] = ["path": .string(path)]
        guard let data = snapshot.files[path] else {
            if snapshot.omitted.contains(path) {
                do {
                    let url = try AgentProjectFiles.url(path, in: snapshot.root)
                    if LibraryCloudEnvironment.state(of: url) == .waitingForDownload {
                        return AgentToolError(
                            "download_pending",
                            "The file is still downloading from iCloud.",
                            details: details,
                        )
                    }
                    return AgentToolError("unavailable", "The path is a special or unavailable file.", details: details)
                } catch let error as AgentToolError {
                    return AgentToolError(error.code, error.message, details: details)
                } catch {
                    return AgentToolError("unavailable", "The path cannot currently be accessed.", details: details)
                }
            }
            return AgentToolError(
                "not_found",
                "No file exists at the requested document-relative path. Use list_files to find project paths.",
                details: details.merging(["suggested_tool": .string("list_files")]) { $1 },
            )
        }
        if !data.contains(0), String(data: data, encoding: .utf8) != nil {
            return AgentToolError(
                "file_too_large",
                "The file is \(data.count) bytes; the edit limit is 2 MiB. " +
                    "Use read_file with start_line and max_lines to read large text in line windows.",
                details: details.merging(["suggested_tool": .string("read_file"), "bytes": .number(Double(data.count)),
                                          "maximum_bytes": .number(Double(AgentTools.maximumTextBytes))]) { $1 },
            )
        }
        if AgentImage.isImage(data) {
            return AgentToolError(
                "not_text", "The file is an image. Use read_image to view it.",
                details: details.merging(["suggested_tool": .string("read_image")]) { $1 },
            )
        }
        return AgentToolError("not_text", "The file is binary or not valid UTF-8 text.", details: details)
    }

    func document(_ args: AgentArguments, access: AgentToolAccess) async throws -> LibraryDocument {
        guard let id = UUID(uuidString: args.string("document_id")), access.permits(id) else {
            throw AgentToolError("permission_denied", "The document is outside this connection's scope.")
        }
        guard let document = try await library.list(includeTrashed: true, allowedDocumentIDs: [id])
            .first(where: { $0.id == id })
        else {
            throw AgentToolError(
                "not_found",
                "The document is unavailable.",
                details: ["resource": .string("document")],
            )
        }
        return document
    }

    func capture(_ document: LibraryDocument, paths: Set<String>? = nil) async throws -> AgentProjectSnapshot {
        let root = document.folderURL
        var snapshot = try await Task.detached(priority: .utility) {
            try AgentProjectFiles.capture(root: root, paths: paths)
        }.value
        try Task.checkCancellation()
        guard let current = try await library.list(includeTrashed: true, allowedDocumentIDs: [document.id])
            .first(where: { $0.id == document.id }),
            current.folderURL == document.folderURL, current.metadataRevision == document.metadataRevision
        else {
            throw AgentToolError("revision_conflict", "The library or document metadata changed.")
        }
        if let live = try host?.agentLiveText(in: document), paths == nil || paths?.contains(live.path) == true {
            snapshot.files[live.path] = Data(live.text.utf8)
        }
        return snapshot
    }

    func entry(_ document: LibraryDocument)
        -> String
    {
        String(document.sourceURL.path.dropFirst(document.folderURL.path.count + 1))
    }

    func historyKey(_ document: LibraryDocument, path: String) -> String {
        // Matches Workspace.historyKey, preserving access to existing native history.
        let base = document.sourceURL.deletingLastPathComponent().path + "/"
        let url = document.folderURL.appendingPathComponent(path)
        let relative = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : "external:" + url
            .absoluteString
        return "library:\(document.id.uuidString)/\(relative)"
    }

    func metadata(_ document: LibraryDocument) -> JSONValue {
        .object(["document_id": .string(document.id.uuidString), "title": .string(document.title),
                 "metadata_revision": .string(document.metadataRevision), "entry": .string(entry(document)),
                 "path_base": .string("document_root"), "typst_root": .string("library_root"),
                 "typst_document_prefix": .string("/" + document.folderURL.lastPathComponent + "/"),
                 "trashed": .bool(document.isTrashed), "has_conflicts": .bool(document.hasUnresolvedConflicts)])
    }

    func revision(_ data: Data, document: LibraryDocument, path: String) -> String {
        AgentTools.digest(Data((epoch + document.folderURL.path + "/" + path + "\0").utf8) + data)
    }

    func projectRevision(_ snapshot: AgentProjectSnapshot, document: LibraryDocument) -> String {
        let values = snapshot.files.mapValues(AgentTools.digest)
        let json: JSONValue = .object(values.mapValues(JSONValue.string))
        return AgentTools
            .digest(Data((epoch + document.metadataRevision + snapshot.omitted.joined(separator: "\0")).utf8) +
                ((try? AgentTools.canonical(json)) ?? Data()))
    }

    func historicalText(_ document: LibraryDocument, path: String, version: String) async throws -> String {
        _ = try AgentProjectFiles.url(path, in: document.folderURL)
        let key = historyKey(document, path: path)
        guard let revision = try await history.revisions(for: key).first(where: { $0.id.uuidString == version }) else {
            throw AgentToolError("version_unavailable", "The retained file version is unavailable.")
        }
        return try await history.source(for: revision, key: key)
    }
}

extension JSONValue {
    var objectValues: [String: JSONValue] {
        if case let .object(values) = self {
            return values
        }
        return [:]
    }
}
