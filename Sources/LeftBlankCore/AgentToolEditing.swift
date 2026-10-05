import Foundation

extension AgentToolDispatcher {
    func edit(
        _ name: String,
        args: AgentArguments,
        document: LibraryDocument,
        snapshot: AgentProjectSnapshot,
    ) async throws -> AgentToolResult {
        guard let host else {
            throw AgentToolError("unavailable", "The application has closed.")
        }
        guard !document.hasUnresolvedConflicts else {
            throw AgentToolError(
                "document_conflict",
                "Resolve the document's sync conflict first.",
            )
        }
        let changes: [AgentPatch.Change]
        let expected: [String: JSONValue]
        switch name {
        case "str_replace":
            let path = args.string("path")
            guard let source = snapshot.texts[path] else {
                throw AgentToolError(
                    "not_text",
                    "Read an available UTF-8 file first.",
                )
            }
            let old = args.string("old_str"), new = args.string("new_str")
            guard !old.isEmpty else {
                throw AgentToolError("invalid_params", "old_str cannot be empty.")
            }
            let text = source as NSString
            let match = text.range(of: old, options: .literal)
            guard match.location != NSNotFound else {
                throw AgentToolError(
                    "no_match",
                    "old_str does not match the current file.",
                )
            }
            let remaining = NSRange(location: match.location + 1, length: text.length - match.location - 1)
            guard text.range(of: old, options: .literal, range: remaining).location == NSNotFound else {
                throw AgentToolError(
                    "ambiguous_match",
                    "old_str matches more than once. Include more surrounding text.",
                )
            }
            changes = [AgentPatch.Change(path: path, text: text.replacingCharacters(in: match, with: new))]
            expected = [path: args["expected_revision"]]
        case "apply_patch":
            changes = try AgentPatch.parse(args.string("input"), sources: snapshot.texts)
            expected = args["expected_revisions"].objectValues
        case "restore_file_version":
            let path = args.string("path")
            let source = try await historicalText(document, path: path, version: args.string("version_id"))
            changes = [AgentPatch.Change(path: path, text: source)]
            expected = [path: args["expected_revision"]]
        default: throw AgentToolError("unknown_tool", "Unknown write tool.")
        }
        guard Set(expected.keys) == Set(changes.map(\.path)) else {
            throw AgentToolError("invalid_params", "expected_revisions must cover exactly the affected paths.")
        }
        for change in changes {
            _ = try AgentProjectFiles.url(change.path, in: document.folderURL)
            guard change.path != entry(document) || change.text != nil else {
                throw AgentToolError(
                    "entry_required",
                    "The compilation entry cannot be deleted. Use trash_document to remove the document.",
                )
            }
            if let data = snapshot.files[change.path] {
                guard snapshot.texts[change.path] != nil else {
                    throw AgentToolError(
                        "not_text",
                        "Binary or oversized files cannot be patched.",
                    )
                }
                guard expected[change.path]?.string == revision(data, document: document, path: change.path) else {
                    throw AgentToolError("revision_conflict", "Read the current revision of \(change.path).")
                }
            } else {
                guard expected[change.path]?.isNull == true, !snapshot.omitted.contains(change.path) else {
                    throw AgentToolError(
                        "revision_conflict",
                        "An absent file requires a null revision and an available parent directory.",
                    )
                }
            }
            if let text = change.text, text.utf8.count > AgentTools.maximumTextBytes {
                throw AgentToolError(
                    "file_too_large",
                    "Edited text exceeds 2 MiB.",
                )
            }
        }
        let paths = changes.map(\.path)
        for path in paths where paths.contains(where: { path.hasPrefix($0 + "/") }) {
            throw AgentToolError("invalid_patch", "A file and its descendant cannot both be patch targets.")
        }
        try host.agentValidate(changes, document: document)
        var versions: [String: String] = [:]
        // Preserve every preimage before applying the first change. Failed preservation changes no file.
        for change in changes {
            if let source = snapshot.texts[change.path] {
                let version = try await history.preserveBeforeAgentEdit(
                    source,
                    key: historyKey(document, path: change.path),
                    at: Date(),
                )
                versions[change.path] = version.id.uuidString
            }
        }
        let current = try await capture(document)
        for change in changes where current.files[change.path] != snapshot.files[change.path] {
            throw AgentToolError("revision_conflict", "\(change.path) changed while preparing the edit.")
        }
        try Task.checkCancellation()
        try host.agentValidate(changes, document: document)
        var results: [JSONValue] = [], issue: JSONValue?, saved = true
        for change in changes {
            do {
                let saveStatus = try host.agentApply(change, before: snapshot.files[change.path], document: document)
                saved = saved && saveStatus == "saved"
                results.append(.object([
                    "path": .string(change.path), "before_revision": expected[change.path] ?? .null,
                    "after_revision": change.text.map { .string(revision(
                        Data($0.utf8),
                        document: document,
                        path: change.path,
                    )) } ?? .null,
                    "before_version_id": versions[change.path].map(JSONValue.string) ?? .null,
                    "save_status": .string(saveStatus), "deleted": .bool(change.text == nil),
                    "diff": .object([
                        "before": .string(AgentTools.excerpt(snapshot.texts[change.path] ?? "", limit: 300)),
                        "after": .string(AgentTools.excerpt(change.text ?? "", limit: 300)),
                        "abbreviated": .bool(true),
                    ]),
                ]))
            } catch {
                issue = failure(error).value["error"]
                break
            }
        }
        let updated = try? await capture(document)
        return AgentToolResult(.object([
            "request_id": args["request_id"],
            "status": .string(issue == nil ? "applied" : results.isEmpty ? "rejected" : "partially_applied"),
            "files": .array(results), "error": issue ?? .null,
            "project_revision": updated.map { .string(projectRevision($0, document: document)) } ?? .null,
        ]), isError: issue != nil || !saved)
    }
}
