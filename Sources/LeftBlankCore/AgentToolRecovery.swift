import Foundation

/// Turns business failures into a bounded repair plan without granting additional access.
@MainActor
enum AgentToolRecovery {
    static func enrich(_ result: AgentToolResult, tool: String, arguments: JSONValue) -> AgentToolResult {
        guard result.isError else {
            return result
        }
        var value = result.value.objectValues
        var issue = value["error"]?.objectValues ?? [:]
        if issue["code"]?.string == nil {
            let status = value["status"]?.string ?? "failed"
            let code = ["timeout", "engine_unavailable"].contains(status) ? status : "compile_failed"
            issue = AgentToolError(
                code,
                "The engine did not complete successfully. Inspect diagnostics and engine_message.",
            )
            .json.objectValues
        }
        let code = issue["code"]?.string ?? "unavailable"
        let document = arguments["document_id"].string.flatMap { UUID(uuidString: $0) }
        let path = safePath(issue["path"]?.string ?? arguments["path"].string)
        issue["tool"] = .string(tool)
        if let document {
            issue["document_id"] = .string(document.uuidString)
        }
        if let path {
            issue["path"] = .string(path)
        } else {
            issue.removeValue(forKey: "path")
        }
        issue["path_base"] = .string("document_root")
        if AgentToolDispatcher.engineTools.contains(tool) {
            issue["typst_root"] = .string("library_root")
            if let document {
                issue["typst_document_prefix"] = .string("/" + document.uuidString + "/")
            }
        }
        let writing = AgentTools.definitions.first { $0.name == tool }?.readOnly == false
        let state = issue["mutation_state"]?.string ?? mutationState(value, writing: writing, code: code)
        issue["mutation_state"] = .string(state)
        issue["recovery"] = plan(
            code,
            tool: tool,
            document: document,
            path: path,
            issue: issue,
            value: value,
            writing: writing,
            state: state,
            arguments: arguments,
        )
        value["error"] = .object(issue)
        return AgentToolResult(.object(value), isError: true, images: result.images)
    }

    private static func safePath(_ path: String?) -> String? {
        guard let path, (try? AgentProjectFiles.validate(path)) != nil else {
            return nil
        }
        return path
    }

    private static func mutationState(_ value: [String: JSONValue], writing: Bool, code: String) -> String {
        guard writing else {
            return "not_applicable"
        }
        switch value["status"]?.string {
        case "applied": return "applied"
        case "partially_applied": return "partially_applied"
        default:
            return ["cancelled", "timeout", "outcome_unknown", "save_failed", "unavailable"].contains(code)
                ? "unknown" : "not_applied"
        }
    }

    private static func plan(
        _ code: String,
        tool: String,
        document: UUID?,
        path: String?,
        issue: [String: JSONValue],
        value: [String: JSONValue],
        writing: Bool,
        state: String,
        arguments: JSONValue,
    ) -> JSONValue {
        var calls: [JSONValue] = []
        func call(_ name: String, _ args: [String: JSONValue] = [:]) {
            calls.append(.object(["tool": .string(name), "arguments": .object(args)]))
        }
        let doc = document.map { ["document_id": JSONValue.string($0.uuidString)] } ?? [:]
        func project() {
            if document != nil {
                call("get_document", doc)
            } else {
                call("list_documents")
            }
        }
        func files() {
            if document != nil {
                call("list_files", doc)
            } else {
                call("list_documents")
            }
        }
        func read() {
            if let path, document != nil {
                call("read_file", doc.merging(["path": .string(path)]) { $1 })
            } else {
                files()
            }
        }
        var retry = "after_correction"
        let instruction: String
        switch code {
        case "not_found", "file_not_found":
            instruction = "Use the returned entry and list_files paths exactly, relative to the document root. " +
                "Imported paths may start with Project/. If a text file is genuinely new, use apply_patch Add File " +
                "with its expected_revisions value set to null."
            if issue["resource"]?.string == "document" || path == nil {
                call("list_documents")
            } else {
                files()
            }
        case "unsafe_path", "path_not_allowed":
            instruction = "Use a document-relative path from list_files, without absolute paths, hidden components, " +
                "parent traversal or symlinks. Typst source references have separate resolution rules."
            files()
        case "download_pending":
            instruction = "Wait for iCloud to finish downloading the file in LeftBlank, then list files again. " +
                "Do not create a replacement for a file that is still downloading."
            retry = "after_wait"
            files()
        case "not_text":
            if issue["suggested_tool"]?.string == "read_image", let path, document != nil {
                instruction = "This is an image. View it with read_image; text editing cannot modify its bytes."
                call("read_image", doc.merging(["path": .string(path)]) { $1 })
            } else {
                instruction = "This file is binary or not UTF-8. Use an appropriate resource tool or provide a UTF-8 " +
                    "source file; do not retry text operations with the same bytes."
                files()
            }
            retry = "change_operation"
        case "not_image":
            instruction = "Use list_files to find the intended raster image. Use read_file for UTF-8 source; " +
                "convert unsupported image formats before importing them."
            files()
            retry = "change_operation"
        case "file_too_large", "too_large", "project_too_large", "result_too_large", "payload_too_large":
            instruction = "Respect the byte and item limits reported by the tool. Use read_file line windows for " +
                "large text, smaller batches for edits, or reduce resource/output size before trying again."
            files()
        case "revision_conflict":
            instruction = "Read the current content and revision, preserve intervening user edits, then rebuild the " +
                "change. Metadata and project revisions come from get_document; file revisions come from read_file."
            if ["str_replace", "apply_patch", "restore_file_version"].contains(tool) {
                read()
            } else {
                project()
            }
        case "no_match", "text_not_found", "ambiguous_match", "patch_mismatch", "invalid_patch", "overlapping_edits":
            instruction = "Read the current file. Rebuild the replacement using a unique exact match, or a patch " +
                "with complete context lines and the current revisions of every affected path. " +
                "Use one Add operation per new path; do not Update a path that does not exist."
            read()
        case "request_id_conflict":
            instruction = "Use a new request_id for corrected or different arguments. Reusing an ID is allowed " +
                "only for the identical request and may return its cached success or failure."
            project()
        case "permission_denied", "filesystem_permission_denied", "read_only_package":
            instruction = "Check the connection grant in get_app_state. Creating/importing requires library-wide " +
                "editing access. Ask the user to adjust access or provide a writable project copy when needed."
            retry = "user_action"
            call("get_app_state")
        case "document_conflict", "unresolved_conflict", "invalid_metadata":
            instruction = "Ask the user to resolve the document's sync or metadata problem in LeftBlank. " +
                "Preserve the existing files; do not overwrite them to bypass the conflict."
            retry = "user_action"
            project()
        case "document_trashed":
            instruction = "Find the document including trashed entries and read its metadata. Restore it only " +
                "when the requested task authorizes restoration, then reread its current files."
            call("list_documents", ["include_trashed": .bool(true)])
        case "version_unavailable":
            instruction = "List the retained versions and select an available version_id. A historical version " +
                "is not a writable current revision; reread the current file before restoring."
            if let path, document != nil {
                call("list_file_versions", doc.merging(["path": .string(path)]) { $1 })
            } else {
                files()
            }
        case "compile_failed", "render_failed", "query_failed", "incomplete_project":
            instruction = "Inspect diagnostics at their document-relative paths and line ranges. List the project " +
                "files to check missing imports/assets, then fix references or import the missing dependencies. " +
                "Do not assume local files were uploaded. Typst relative references start at their source file; " +
                "leading / starts at the library root, above the document UUID. Only this authorized document " +
                "is captured: references to other library documents are not included. " +
                "Read the current project revision before recompiling."
            project()
            files()
            if let diagnostic = value["diagnostics"]?.array.first,
               let source = safePath(diagnostic["path"].string), document != nil
            {
                let start = max(1, (diagnostic["range"]["start"]["line"].int ?? 0) + 1)
                call("read_file", doc.merging(["path": .string(source), "start_line": .number(Double(start)),
                                               "max_lines": .number(40)]) { $1 })
            }
        case "cursor_expired":
            instruction = "Restart this read or search without cursor, retaining the original query. Its snapshot changed."
            let args = arguments.objectValues.filter { $0.key != "cursor" }
            if AgentTools.definitions.contains(where: { $0.name == tool && $0.readOnly }) {
                call(tool, args)
            } else {
                project()
            }
        case "busy", "editor_busy", "engine_unavailable", "document_not_open":
            instruction = "Check get_app_state and wait for the current operation to finish. Finish input-method " +
                "composition or open the document in LeftBlank when required, then retry after reading fresh state."
            retry = "after_wait"
            call("get_app_state")
        case "invalid_params", "invalid_project", "already_exists", "entry_required", "unknown_tool":
            instruction = "Correct the named parameter using the tool schema and error details. Use the document " +
                "entry from get_document and exact file paths from list_files; preserve an existing destination."
            project()
        default:
            instruction = "Check get_app_state and read the current document/files. Use the reported details to " +
                "correct the request; if the operation remains unavailable, ask the user to check LeftBlank."
            call("get_app_state")
            if document != nil {
                project()
            }
        }
        let uncertain = ["unknown", "partially_applied", "applied"].contains(state)
        var instructions = instruction
        if writing, uncertain {
            retry = "inspect_state_first"
            instructions += " Some changes may already be applied. Inspect files and save_status, including " +
                "unconfirmed_paths, before planning only the remaining work. Never replay the whole write blindly."
            if document != nil, !calls.contains(where: { $0["tool"].string == "get_document" }) {
                project()
            }
        }
        return .object([
            "instructions": .string(instructions), "next_calls": .array(calls), "retry": .string(retry),
            "request_id": .string(writing
                ? "Use a new request_id after correction or replanning; reuse only for an identical request outcome."
                : "Not required for read-only calls."),
        ])
    }
}
