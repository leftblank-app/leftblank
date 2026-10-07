import Foundation

/// One Tinymist export that a host runs on a fresh engine over a captured project snapshot.
public enum AgentEngineExport: Sendable, Equatable {
    case png(page: Int, ppi: Double)
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
            .object(["pages": .array([.string(String(page))]), "ppi": .number(ppi)])
        case let .query(selector, field, one):
            .object(["format": .string("json"), "selector": .string(selector), "one": .bool(one)]
                .merging(field.map { ["field": .string($0)] } ?? [:]) { $1 })
        }
    }
}

/// A fresh engine over a private copy of one snapshot. Exports on it share one compilation.
@MainActor
public protocol AgentEngineSession: AnyObject {
    func run(_ export: AgentEngineExport) async throws -> AgentEngineOutput
}

/// Chooses a render resolution before rasterizing, so a huge page cannot exhaust memory.
enum AgentPageFit {
    static let maximumEdge = Double(AgentImage.maximumEdge)
    static let maximumPixels = 3_145_728.0
    static let minimumPPI = 1.0
    /// 1e-5 px per pt keeps the first probe under 256 px for pages up to about 9 km.
    static let firstProbePPI = 72e-5
    /// Probes this long on their longer edge measure the page within 0.4%.
    static let preciseProbeEdge = 128.0
    static let probeEdge = 256.0
    static let maximumProbes = 5

    /// The page size in pt cannot exceed this, given a probe's pixels. Typst rounds pt × px-per-pt.
    static func bound(pixels: Int, ppi: Double) -> Double {
        (Double(pixels) + 0.5) * 72 / ppi * 1.001
    }

    /// The largest ppi up to `requested`, in 0.01 steps, that keeps both edges and the area in bounds.
    static func ppi(requested: Double, width: Double, height: Double) -> Double? {
        let fitted = min(
            requested,
            72 * maximumEdge / width,
            72 * maximumEdge / height,
            72 * (maximumPixels / (width * height)).squareRoot(),
        )
        let rounded = (fitted * 100).rounded(.down) / 100
        return rounded >= minimumPPI ? rounded : nil
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
        let requested = Double(args.integer("ppi", default: AgentEngineExport.defaultPPI))
        var value: [String: JSONValue] = [:]
        let rendered: (AgentEngineOutput, AgentImage.Prepared, Double)? = try await withEngine(
            snapshot: snapshot,
            document: document,
            revision: revision,
            args: args,
        ) { session in
            // Measure the page with tiny probes first; each later probe stays under 256 px.
            var probe = AgentPageFit.firstProbePPI, width = 0.0, height = 0.0
            for _ in 0 ..< AgentPageFit.maximumProbes {
                let output = try await session.run(.png(page: page, ppi: probe))
                guard let image = try pageImage(output, page: page, into: &value) else {
                    return nil
                }
                width = AgentPageFit.bound(pixels: image.width, ppi: probe)
                height = AgentPageFit.bound(pixels: image.height, ppi: probe)
                if Double(max(image.width, image.height)) >= AgentPageFit.preciseProbeEdge {
                    break
                }
                probe = 72 * AgentPageFit.probeEdge / max(width, height)
            }
            guard let ppi = AgentPageFit.ppi(requested: requested, width: width, height: height) else {
                value["error"] = AgentToolError(
                    "page_too_large",
                    "Even at 1 ppi the page exceeds 2048 px per edge or 3 megapixels.",
                ).json
                return nil
            }
            let output = try await session.run(.png(page: page, ppi: ppi))
            return try pageImage(output, page: page, into: &value).map { (output, $0, ppi) }
        }
        await value.merge(provenance(document, revision: revision)) { old, _ in old }
        guard let (output, prepared, ppi) = rendered else {
            return AgentToolResult(.object(value), isError: true)
        }
        value.merge([
            "page": .number(Double(page)),
            "ppi": .number(ppi),
            "requested_ppi": .number(requested),
            "ppi_reduced": .bool(ppi < requested),
            "mime_type": .string(prepared.image.mimeType),
            "bytes": .number(Double(prepared.image.data.count)),
            "width": .number(Double(prepared.width)),
            "height": .number(Double(prepared.height)),
            "downscaled": .bool(prepared.converted),
            "diagnostics": .array(output.diagnostics),
        ]) { $1 }
        return AgentToolResult(.object(value), images: [prepared.image])
    }

    /// The page's image, or nil after recording why there is none in `value`.
    private func pageImage(
        _ output: AgentEngineOutput,
        page: Int,
        into value: inout [String: JSONValue],
    ) throws -> AgentImage.Prepared? {
        guard output.status == .completed else {
            value.merge(engineFailure(output, code: "render_failed")) { $1 }
            return nil
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
            return nil
        }
        guard let encoded = output.response["items"].array.first(where: { $0["page"].int == page - 1 })?["data"]
            .string, let data = Data(base64Encoded: encoded)
        else {
            throw AgentToolError("render_failed", "The engine returned no image for the page.")
        }
        return try AgentImage.prepare(data)
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
        let output = try await withEngine(snapshot: snapshot, document: document, revision: revision, args: args) {
            try await $0.run(.query(selector: selector, field: field, one: one))
        }
        var value = await provenance(document, revision: revision)
        guard output.status == .completed else {
            return AgentToolResult(
                .object(value.merging(engineFailure(output, code: "query_failed")) { $1 }),
                isError: true,
            )
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

    private func withEngine<T>(
        snapshot: AgentProjectSnapshot,
        document: LibraryDocument,
        revision: String,
        args: AgentArguments,
        _ body: (any AgentEngineSession) async throws -> T,
    ) async throws -> T {
        if let expected = args["expected_project_revision"].string, expected != revision {
            throw AgentToolError("revision_conflict", "Read the current project revision first.")
        }
        guard snapshot.omitted.isEmpty else {
            throw AgentToolError("incomplete_project", "The project contains unavailable files or symlinks.")
        }
        guard let host else {
            throw AgentToolError("unavailable", "The application has closed.")
        }
        let result = try await host.agentEngine(snapshot, entry: entry(document), body)
        try Task.checkCancellation()
        return result
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

    private func engineFailure(_ output: AgentEngineOutput, code: String) -> [String: JSONValue] {
        // Tinymist reports a document that does not compile this way for every export.
        let compileFailed = output.message?.contains("document is not available for export") == true
        let issue = switch output.status {
        case .failed where compileFailed:
            AgentToolError("compile_failed", "The document does not compile. Fix the diagnostics and retry.")
        case .failed: AgentToolError(code, "The engine rejected the request. See engine_message.")
        case .timeout: AgentToolError("timeout", "The engine timed out.")
        case .engineUnavailable, .completed: AgentToolError("engine_unavailable", "The engine could not start.")
        }
        return [
            "status": .string(output.status.rawValue),
            "error": issue.json,
            "engine_message": output.message.map { .string(AgentTools.excerpt($0, limit: 2000)) } ?? .null,
            "diagnostics": .array(output.diagnostics),
        ]
    }
}
