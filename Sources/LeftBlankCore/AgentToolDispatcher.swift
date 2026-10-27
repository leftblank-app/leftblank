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
                return failure(CancellationError())
            }
        }
        defer {
            if compiling {
                compiles.release(exclusive: true)
            }
        }
        guard await gate.acquire(exclusive: exclusive) else {
            return failure(CancellationError())
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
            if let key {
                cachedWrites[key] = (fingerprint, result)
                writeOrder.append(key)
                if writeOrder.count > 256 {
                    cachedWrites.removeValue(forKey: writeOrder.removeFirst())
                }
            }
            return result
        } catch { return failure(error) }
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
            issue = AgentToolError(
                "unavailable",
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
            return AgentToolResult(.object([
                "request_id": args["request_id"],
                "status": .string("applied"),
                "document": metadata(document),
            ]))
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
        let snapshot = try await capture(document)
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
                throw AgentToolError("unavailable", "The file is unavailable or still downloading.")
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
        case "get_diagnostics":
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

    /// Why a path has no text in the snapshot. Codes stay stable; hints say what to do instead.
    func unreadable(_ path: String, snapshot: AgentProjectSnapshot) -> AgentToolError {
        guard let data = snapshot.files[path] else {
            if snapshot.omitted.contains(path) {
                return AgentToolError(
                    "unavailable",
                    "\(path) is still downloading, or is a symlink or special file that agent tools cannot read.",
                )
            }
            return AgentToolError(
                "not_found",
                "No file exists at \(path). Use list_files to find project paths.",
                details: ["suggested_tool": .string("list_files")],
            )
        }
        if !data.contains(0), String(data: data, encoding: .utf8) != nil {
            return AgentToolError(
                "file_too_large",
                "\(path) is \(data.count) bytes; files over 2 MiB can be read with read_file " +
                    "(start_line and max_lines) but not edited.",
                details: ["suggested_tool": .string("read_file")],
            )
        }
        if AgentImage.isImage(data) {
            return AgentToolError(
                "not_text",
                "\(path) is an image. Use read_image to view it.",
                details: ["suggested_tool": .string("read_image")],
            )
        }
        return AgentToolError(
            "not_text",
            "\(path) is binary or not valid UTF-8 text; only UTF-8 text files can be read or edited as text.",
        )
    }

    func document(_ args: AgentArguments, access: AgentToolAccess) async throws -> LibraryDocument {
        guard let id = UUID(uuidString: args.string("document_id")), access.permits(id) else {
            throw AgentToolError("permission_denied", "The document is outside this connection's scope.")
        }
        guard let document = try await library.list(includeTrashed: true, allowedDocumentIDs: [id])
            .first(where: { $0.id == id })
        else {
            throw AgentToolError("not_found", "The document is unavailable.")
        }
        return document
    }

    func capture(_ document: LibraryDocument) async throws -> AgentProjectSnapshot {
        let root = document.folderURL
        var snapshot = try await Task.detached(priority: .utility) { try AgentProjectFiles.capture(root: root) }.value
        try Task.checkCancellation()
        guard let current = try await library.list(includeTrashed: true, allowedDocumentIDs: [document.id])
            .first(where: { $0.id == document.id }),
            current.folderURL == document.folderURL, current.metadataRevision == document.metadataRevision
        else {
            throw AgentToolError("revision_conflict", "The library or document metadata changed.")
        }
        if let live = try host?.agentLiveText(in: document) {
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
