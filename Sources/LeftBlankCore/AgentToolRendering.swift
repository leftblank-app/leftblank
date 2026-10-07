import Foundation

/// One Tinymist export that a host runs on a fresh engine over a captured project snapshot.
public enum AgentEngineExport: Sendable, Equatable {
    case png(page: Int, ppi: Int)
    case query(selector: String, field: String?, one: Bool)

    public static let ppiRange = 36 ... 288
    public static let defaultPPI = 144

    public var command: String {
        switch self {
        case .png: "tinymist.exportPng"
        case .query: "tinymist.exportQuery"
        }
    }

    /// The command's options. Hosts pass `{"write": false}` after them, so data returns in memory as base64.
    public var options: JSONValue {
        switch self {
        case let .png(page, ppi):
            .object(["pages": .array([.string(String(page))]), "ppi": .number(Double(ppi))])
        case let .query(selector, field, one):
            .object(["format": .string("json"), "selector": .string(selector), "one": .bool(one)]
                .merging(field.map { ["field": .string($0)] } ?? [:]) { $1 })
        }
    }
}

public struct AgentEngineOutput: Sendable {
    public enum Status: String, Sendable {
        case completed
        case failed
        case timeout
        case engineUnavailable = "engine_unavailable"
    }

    public let status: Status
    /// The engine's command result when completed.
    public let response: JSONValue
    /// The engine's error, with private paths removed, when failed.
    public let message: String?
    public let diagnostics: [JSONValue]
    public init(status: Status, response: JSONValue = .null, message: String? = nil, diagnostics: [JSONValue] = []) {
        self.status = status
        self.response = response
        self.message = message
        self.diagnostics = diagnostics
    }
}

/// The view of one open document. Hosts report nothing for documents that are not open.
public struct AgentEditorContext: Sendable {
    public struct File: Sendable {
        public let path: String
        public let text: String
        public let selection: NSRange
        public let visible: NSRange?
        public let saved: Bool
        public init(path: String, text: String, selection: NSRange, visible: NSRange?, saved: Bool) {
            self.path = path
            self.text = text
            self.selection = selection
            self.visible = visible
            self.saved = saved
        }
    }

    public let layout: String
    /// 1-based page at the top of the visible preview, when the preview is shown and reported its position.
    public let previewPage: Int?
    /// The active source, or nil when it is outside the project, such as a read-only package file.
    public let file: File?
    public init(layout: String, previewPage: Int?, file: File?) {
        self.layout = layout
        self.previewPage = previewPage
        self.file = file
    }
}

extension AgentToolDispatcher {
    /// Each of these starts its own engine, so they take turns.
    static let engineTools: Set<String> = ["compile_document", "render_page", "query_document"]
    static let selectionLimit = 4000

    func editorContext(_ document: LibraryDocument) throws -> AgentToolResult {
        guard let context = host?.agentEditorContext(in: document) else {
            throw AgentToolError(
                "document_not_open",
                "The document is not open in LeftBlank. Ask the user to open it, or use read_file.",
            )
        }
        var value: [String: JSONValue] = [
            "document_id": .string(document.id.uuidString),
            "layout": .string(context.layout),
            "preview_page": context.previewPage.map { .number(Double($0)) } ?? .null,
            "active_path": .null,
            "active_file_in_project": .bool(context.file != nil),
        ]
        guard let file = context.file else {
            return AgentToolResult(.object(value))
        }
        let metrics = DocumentMetrics(file.text)
        let length = file.text.utf16.count
        func clamp(_ offset: Int) -> Int {
            min(max(0, offset), length)
        }
        func line(_ offset: Int) -> Int {
            metrics.position(at: clamp(offset)).line + 1
        }
        let start = clamp(file.selection.location), end = clamp(file.selection.location + file.selection.length)
        let caret = metrics.position(at: end)
        value["active_path"] = .string(file.path)
        value["is_entry"] = .bool(file.path == entry(document))
        value["revision"] = .string(revision(Data(file.text.utf8), document: document, path: file.path))
        value["unsaved"] = .bool(!file.saved)
        value["position_encoding"] = .string("utf-16")
        value["cursor"] = .object(["line_number": .number(Double(caret.line + 1)), "position": Self.position(caret)])
        if end > start {
            let selected = (file.text as NSString).substring(with: NSRange(location: start, length: end - start))
            let excerpt = AgentTools.excerpt(selected, limit: Self.selectionLimit)
            value["selection"] = .object([
                "text": .string(excerpt),
                "truncated": .bool(excerpt.unicodeScalars.count < selected.unicodeScalars.count),
                "range": .object([
                    "start": Self.position(metrics.position(at: start)),
                    "end": Self.position(caret),
                ]),
            ])
        } else {
            value["selection"] = .null
        }
        value["visible_lines"] = file.visible.map { visible in
            let first = clamp(visible.location)
            // A range ending just after a newline does not show the next line.
            let last = max(first, clamp(visible.location + visible.length) - 1)
            return .object([
                "first_line_number": .number(Double(line(first))),
                "last_line_number": .number(Double(line(last))),
            ])
        } ?? .null
        return AgentToolResult(.object(value))
    }

    func renderPage(
        _ snapshot: AgentProjectSnapshot,
        document: LibraryDocument,
        revision: String,
        args: AgentArguments,
    ) async throws -> AgentToolResult {
        let page = args.integer("page", default: 1)
        let ppi = args.integer("ppi", default: AgentEngineExport.defaultPPI)
        let output = try await export(
            .png(page: page, ppi: ppi),
            snapshot: snapshot,
            document: document,
            revision: revision,
            args: args,
        )
        var value = await provenance(document, revision: revision)
        guard output.status == .completed else {
            return engineFailure(output, value: value, code: "render_failed")
        }
        guard let count = output.response["total_pages"].int else {
            throw AgentToolError("render_failed", "The engine returned no page count.")
        }
        value["page_count"] = .number(Double(count))
        guard page <= count else {
            value["error"] = AgentToolError(
                "page_out_of_range",
                "The document has \(count) page\(count == 1 ? "" : "s").",
            ).json
            return AgentToolResult(.object(value), isError: true)
        }
        guard let encoded = output.response["items"].array.first(where: { $0["page"].int == page - 1 })?["data"]
            .string, let data = Data(base64Encoded: encoded)
        else {
            throw AgentToolError("render_failed", "The engine returned no image for the page.")
        }
        let prepared = try AgentImage.prepare(data)
        value.merge([
            "page": .number(Double(page)),
            "ppi": .number(Double(ppi)),
            "mime_type": .string(prepared.image.mimeType),
            "bytes": .number(Double(prepared.image.data.count)),
            "width": .number(Double(prepared.width)),
            "height": .number(Double(prepared.height)),
            "downscaled": .bool(prepared.converted),
            "diagnostics": .array(output.diagnostics),
        ]) { $1 }
        return AgentToolResult(.object(value), images: [prepared.image])
    }

    func queryDocument(
        _ snapshot: AgentProjectSnapshot,
        document: LibraryDocument,
        revision: String,
        args: AgentArguments,
        access: AgentToolAccess,
    ) async throws -> AgentToolResult {
        let selector = args.string("selector")
        guard !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, selector.utf8.count <= 2000 else {
            throw AgentToolError("invalid_params", "selector must contain 1–2000 bytes.")
        }
        let field = args["field"].string
        if let field, field.range(of: "^[A-Za-z_][A-Za-z0-9_-]{0,99}$", options: .regularExpression) == nil {
            throw AgentToolError("invalid_params", "field must be a Typst field name.")
        }
        let one = args.bool("one", default: false)
        let output = try await export(
            .query(selector: selector, field: field, one: one),
            snapshot: snapshot,
            document: document,
            revision: revision,
            args: args,
        )
        var value = await provenance(document, revision: revision)
        guard output.status == .completed else {
            return engineFailure(output, value: value, code: "query_failed")
        }
        guard let encoded = output.response["data"].string, let data = Data(base64Encoded: encoded),
              let result = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            throw AgentToolError("query_failed", "The engine returned no query result.")
        }
        if one {
            guard try AgentTools.canonical(result).count < 128 * 1024 else {
                throw AgentToolError("result_too_large", "The match exceeds the output budget. Query a field.")
            }
            value["value"] = result
        } else {
            let matches = result.array
            try value.merge(page(
                matches,
                args: args,
                name: "query_document",
                snapshot: revision + AgentTools.digest(AgentTools.canonical(result)),
                access: access,
            ).objectValues) { $1 }
            value["count"] = .number(Double(matches.count))
        }
        value["diagnostics"] = .array(output.diagnostics)
        return AgentToolResult(.object(value))
    }

    private func export(
        _ request: AgentEngineExport,
        snapshot: AgentProjectSnapshot,
        document: LibraryDocument,
        revision: String,
        args: AgentArguments,
    ) async throws -> AgentEngineOutput {
        if let expected = args["expected_project_revision"].string, expected != revision {
            throw AgentToolError("revision_conflict", "Read the current project revision first.")
        }
        guard snapshot.omitted.isEmpty else {
            throw AgentToolError("incomplete_project", "The project contains unavailable files or symlinks.")
        }
        guard let host else {
            throw AgentToolError("unavailable", "The application has closed.")
        }
        let output = try await host.agentExport(snapshot, entry: entry(document), export: request)
        try Task.checkCancellation()
        return output
    }

    /// Which input produced a result. Packages and system fonts are not pinned, as for compile_document.
    private func provenance(_ document: LibraryDocument, revision: String) async -> [String: JSONValue] {
        let current = try? await capture(document)
        return [
            "status": .string("unverified"),
            "compiled_project_revision": .string(revision),
            "is_current": .bool(current.map { projectRevision($0, document: document) == revision } ?? false),
            "limitation": .string("External packages and system fonts are not pinned."),
        ]
    }

    private func engineFailure(
        _ output: AgentEngineOutput,
        value: [String: JSONValue],
        code: String,
    ) -> AgentToolResult {
        var value = value
        // Tinymist reports a document that does not compile this way for every export.
        let compileFailed = output.message?.contains("document is not available for export") == true
        let issue = switch output.status {
        case .failed where compileFailed:
            AgentToolError("compile_failed", "The document does not compile. Fix the diagnostics and retry.")
        case .failed: AgentToolError(code, "The engine rejected the request. See engine_message.")
        case .timeout: AgentToolError("timeout", "The engine timed out.")
        case .engineUnavailable, .completed: AgentToolError("engine_unavailable", "The engine could not start.")
        }
        value["status"] = .string(output.status.rawValue)
        value["error"] = issue.json
        value["engine_message"] = output.message.map { .string(AgentTools.excerpt($0, limit: 2000)) } ?? .null
        value["diagnostics"] = .array(output.diagnostics)
        return AgentToolResult(.object(value), isError: true)
    }
}
