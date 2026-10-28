import Foundation

/// An explicit upload, not permission to read arbitrary paths on the server's Mac.
public struct AgentProjectImport: Sendable {
    /// Leaves room for the RPC/IPC envelopes beneath the bridge's 8 MiB frame limit.
    public static let maximumPayloadBytes = 6 * 1024 * 1024
    public static let maximumEntries = 2000
    public static let maximumFileBytes = 16 * 1024 * 1024
    public static let maximumProjectBytes = 64 * 1024 * 1024

    public let entry: String
    public let files: [String: Data]

    public init(entry: String, files uploads: [JSONValue]) throws {
        do { try AgentProjectFiles.validate(entry) }
        catch let error as AgentToolError {
            throw AgentToolError(error.code, error.message, details: [
                "parameter": .string("entry"), "path": .string(entry),
            ])
        }
        guard URL(fileURLWithPath: entry).pathExtension.lowercased() == "typ" else {
            throw Self.invalid("The entry must name a .typ file in files.", parameter: "entry", path: entry)
        }
        guard !uploads.isEmpty, uploads.count <= Self.maximumEntries else {
            throw Self.invalid("files must contain 1–2000 regular files.", parameter: "files")
        }
        let payloadBytes = try AgentTools.canonical(.array(uploads)).count
        guard payloadBytes <= Self.maximumPayloadBytes else {
            throw AgentToolError(
                "project_too_large",
                "The encoded files manifest exceeds the 6 MiB upload limit. " +
                    "Exclude generated PDFs and previews, reduce resource sizes, or use smaller text-only patch batches.",
                details: ["parameter": .string("files"),
                          "actual_bytes": .number(Double(payloadBytes)),
                          "maximum_bytes": .number(Double(Self.maximumPayloadBytes))],
            )
        }

        var files: [String: Data] = [:], entries: [String: String] = [:], directories: Set<String> = []
        var size = 0
        for (index, upload) in uploads.enumerated() {
            let parameter = "files[\(index)]"
            guard case let .object(fields) = upload,
                  Set(fields.keys).isSubset(of: ["path", "text", "data_base64"]),
                  let path = fields["path"]?.string
            else {
                throw Self.invalid(
                    "Each file requires path and exactly one string payload: text or data_base64. Unknown fields are rejected.",
                    parameter: parameter,
                )
            }
            do { try AgentProjectFiles.validate(path) }
            catch let error as AgentToolError {
                throw AgentToolError(error.code, error.message, details: [
                    "parameter": .string(parameter + ".path"), "path": .string(path),
                ])
            }
            let data = try Self.decode(fields, parameter: parameter, path: path)
            guard data.count <= Self.maximumFileBytes, size + data.count <= Self.maximumProjectBytes else {
                throw AgentToolError(
                    "project_too_large",
                    "Imported files are limited to 16 MiB each and 64 MiB per project.",
                    details: ["parameter": .string(parameter), "path": .string(path)],
                )
            }
            guard files[path] == nil else {
                throw Self.invalid("A path may appear only once in files.", parameter: parameter + ".path", path: path)
            }
            try Self.register(path, in: &entries, parameter: parameter + ".path")
            let components = path.split(separator: "/")
            for count in 1 ..< components.count {
                let parent = components.prefix(count).joined(separator: "/")
                try Self.register(parent, in: &entries, parameter: parameter + ".path")
                directories.insert(parent)
            }
            guard entries.count <= Self.maximumEntries else {
                throw Self.invalid("Files and their parent folders exceed 2000 project entries.", parameter: "files")
            }
            files[path] = data
            size += data.count
        }
        if let collision = directories.first(where: { files[$0] != nil }) {
            throw Self.invalid("A path cannot be both a file and a parent folder.", parameter: "files", path: collision)
        }
        guard let entryData = files[entry] else {
            throw Self.invalid(
                "The entry file was not uploaded. Set entry to an exact path from files and include that file.",
                parameter: "entry",
                path: entry,
            )
        }
        guard entryData.count <= AgentTools.maximumTextBytes, !entryData.contains(0),
              String(data: entryData, encoding: .utf8) != nil
        else {
            throw Self.invalid("The entry must be UTF-8 text no larger than 2 MiB.", parameter: "entry", path: entry)
        }
        self.entry = entry
        self.files = files
    }

    private static func decode(_ fields: [String: JSONValue], parameter: String, path: String) throws -> Data {
        guard (fields["text"] == nil) != (fields["data_base64"] == nil) else {
            throw invalid("Supply exactly one of text or data_base64.", parameter: parameter, path: path)
        }
        if let value = fields["text"] {
            guard let text = value.string else {
                throw invalid("text must be a UTF-8 string.", parameter: parameter + ".text", path: path)
            }
            guard !text.utf8.contains(0), text.utf8.count <= AgentTools.maximumTextBytes else {
                throw invalid(
                    "text must not contain NUL and must be no larger than 2 MiB. " +
                        "Use data_base64 for binary resources.",
                    parameter: parameter + ".text",
                    path: path,
                )
            }
            return Data(text.utf8)
        }
        guard let encoded = fields["data_base64"]?.string, let data = Data(base64Encoded: encoded) else {
            throw invalid(
                "data_base64 must be a standard base64 string without whitespace or a data: prefix.",
                parameter: parameter + ".data_base64",
                path: path,
            )
        }
        return data
    }

    /// Avoid overwrites and divergent trees on case-insensitive or Unicode-normalizing filesystems.
    private static func register(_ path: String, in entries: inout [String: String], parameter: String) throws {
        let key = path.precomposedStringWithCanonicalMapping.folding(
            options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX"),
        )
        if let previous = entries[key], !previous.utf8.elementsEqual(path.utf8) {
            throw invalid(
                "Paths must not differ only by letter case or Unicode normalization: \(previous) and \(path).",
                parameter: parameter,
                path: path,
            )
        }
        entries[key] = path
    }

    private static func invalid(_ message: String, parameter: String, path: String? = nil) -> AgentToolError {
        var details: [String: JSONValue] = ["parameter": .string(parameter)]
        if let path {
            details["path"] = .string(path)
        }
        return AgentToolError("invalid_project", message, details: details)
    }
}

extension AgentToolDispatcher {
    func importProject(_ args: AgentArguments, access: AgentToolAccess) async throws -> AgentToolResult {
        guard access.documentIDs == nil else {
            throw AgentToolError("permission_denied", "Importing a project requires library-wide write access.")
        }
        guard let host else {
            throw AgentToolError("unavailable", "The application has closed.")
        }
        let manifest = try AgentProjectImport(entry: args.string("entry"), files: args["files"].array)
        try host.agentPrepareMetadataChange(nil, trashing: false)
        let document: LibraryDocument
        do { document = try await library.importProject(title: args.string("title"), manifest: manifest) }
        catch {
            await host.agentFinishMetadataChange(nil)
            throw error
        }
        await host.agentFinishMetadataChange(document)
        let snapshot = AgentProjectSnapshot(root: document.folderURL, files: manifest.files, omitted: [])
        let projectRevision = projectRevision(snapshot, document: document)
        var description = metadata(document).objectValues
        description["project_revision"] = .string(projectRevision)
        description["path_base"] = .string("document_root")
        return AgentToolResult(.object([
            "request_id": args["request_id"], "status": .string("applied"),
            "document": .object(description), "project_revision": .string(projectRevision),
            "path_base": .string("document_root"),
            "files": .array(manifest.files.sorted { $0.key < $1.key }.map { path, data in .object([
                "path": .string(path), "path_base": .string("document_root"), "before_revision": .null,
                "after_revision": .string(revision(data, document: document, path: path)),
                "bytes": .number(Double(data.count)), "save_status": .string("saved"),
            ]) }),
        ]))
    }
}
