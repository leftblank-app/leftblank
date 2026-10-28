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
                throw unreadable(path, snapshot: snapshot)
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
            do { changes = try AgentPatch.parse(args.string("input"), sources: snapshot.texts) }
            catch let error as AgentToolError {
                if case .bool(true)? = error.details["requires_existing_text"],
                   let path = error.details["path"]?.string, snapshot.texts[path] == nil
                {
                    throw unreadable(path, snapshot: snapshot)
                }
                throw error
            }
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
                    throw unreadable(change.path, snapshot: snapshot)
                }
                guard expected[change.path]?.string == revision(data, document: document, path: change.path) else {
                    throw AgentToolError(
                        "revision_conflict",
                        "Read the current file revision before editing.",
                        details: ["path": .string(change.path)],
                    )
                }
            } else {
                guard expected[change.path]?.isNull == true, !snapshot.omitted.contains(change.path) else {
                    throw AgentToolError(
                        "revision_conflict",
                        "An absent file requires a null revision and an available parent directory.",
                        details: ["path": .string(change.path)],
                    )
                }
            }
            if let text = change.text, text.utf8.count > AgentTools.maximumTextBytes {
                throw AgentToolError(
                    "file_too_large",
                    "Edited text exceeds 2 MiB.",
                    details: [
                        "path": .string(change.path),
                        "maximum_bytes": .number(Double(AgentTools.maximumTextBytes)),
                    ],
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
        let current = try await capture(document, paths: Set(changes.map(\.path)))
        for change in changes where current.files[change.path] != snapshot.files[change.path] {
            throw AgentToolError(
                "revision_conflict",
                "The file changed while preparing the edit.",
                details: ["path": .string(change.path)],
            )
        }
        try Task.checkCancellation()
        try host.agentValidate(changes, document: document)
        var results: [JSONValue] = [], issue: JSONValue?, saved = true
        var unconfirmed: [JSONValue] = []
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
                    "diff": AgentDiff.json(before: snapshot.texts[change.path], after: change.text),
                ]))
                if saveStatus != "saved", issue == nil {
                    issue = AgentToolError(
                        "save_failed",
                        "The change was applied but has not been saved successfully.",
                        details: ["path": .string(change.path),
                                  "mutation_state": .string("applied")],
                    ).json
                }
            } catch {
                var details = failure(error).value["error"].objectValues
                details["path"] = .string(change.path)
                details["mutation_state"] = .string(results.isEmpty ? "unknown" : "partially_applied")
                issue = .object(details)
                unconfirmed.append(.string(change.path))
                break
            }
        }
        let updated = try? await capture(document)
        let applied = Set(results.compactMap { $0["path"].string })
        let remaining = changes.filter { !applied.contains($0.path) }.map { JSONValue.string($0.path) }
        return AgentToolResult(.object([
            "request_id": args["request_id"],
            "status": .string(issue == nil || remaining.isEmpty ? "applied" : results
                .isEmpty ? "rejected" : "partially_applied"),
            "files": .array(results), "error": issue ?? .null,
            "remaining_paths": .array(remaining), "unconfirmed_paths": .array(unconfirmed),
            "project_revision": updated.map { .string(projectRevision($0, document: document)) } ?? .null,
        ]), isError: issue != nil || !saved)
    }
}
