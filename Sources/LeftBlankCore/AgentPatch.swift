import Foundation

/// Parse and validate completely before the caller mutates any buffer or file.
public enum AgentPatch {
    public struct Change: Sendable {
        public let path: String
        public let text: String?
    }

    public static func parse(_ input: String, sources: [String: String]) throws -> [Change] {
        var lines = input.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard lines.first == "*** Begin Patch", lines.last == "*** End Patch" else {
            throw AgentToolError("invalid_patch", "Expected *** Begin Patch and *** End Patch.")
        }
        var index = 1, changes: [Change] = []
        while index < lines.count - 1 {
            let header = lines[index]
            index += 1
            let kind: String, path: String
            if header.hasPrefix("*** Add File: ") {
                kind = "add"
                path = String(header.dropFirst(14))
            } else if header.hasPrefix("*** Update File: ") {
                kind = "update"
                path = String(header.dropFirst(17))
            } else if header.hasPrefix("*** Delete File: ") {
                kind = "delete"
                path = String(header.dropFirst(17))
            } else {
                throw AgentToolError("invalid_patch", "Unsupported patch operation.")
            }
            try AgentProjectFiles.validate(path)
            guard !changes.contains(where: { $0.path == path }), changes.count < 50 else {
                throw AgentToolError("invalid_patch", "Use one operation per path, at most 50 files.")
            }
            var body: [String] = []
            while index < lines.count - 1 {
                let line = lines[index]
                if line.hasPrefix("*** "), line != "*** End of File" {
                    break
                }
                body.append(line)
                index += 1
            }
            switch kind {
            case "add":
                guard sources[path] == nil, body.allSatisfy({ $0.hasPrefix("+") }) else {
                    throw AgentToolError("invalid_patch", "Add requires an absent path and + prefixed lines.")
                }
                changes.append(Change(path: path, text: body.map { String($0.dropFirst()) + "\n" }.joined()))
            case "delete":
                guard sources[path] != nil, body.isEmpty else {
                    throw AgentToolError("invalid_patch", "Delete requires an existing UTF-8 file and no hunks.")
                }
                changes.append(Change(path: path, text: nil))
            default:
                guard let source = sources[path], !body.isEmpty else {
                    throw AgentToolError("invalid_patch", "Update requires an existing UTF-8 file and hunks.")
                }
                try changes.append(Change(path: path, text: update(source, body: body, path: path)))
            }
        }
        guard !changes.isEmpty else {
            throw AgentToolError("invalid_patch", "The patch contains no operations.")
        }
        return changes
    }

    private static func update(_ source: String, body: [String], path: String) throws -> String {
        var original = source.components(separatedBy: "\n")
        let newline = source.utf8.last == 10
        if newline || source.isEmpty {
            original.removeLast()
        }
        var output: [String] = [], consumed = 0, index = 0, hunk = 0
        while index < body.count {
            hunk += 1
            guard body[index] == "@@" || body[index].hasPrefix("@@ ") else {
                throw AgentToolError(
                    "invalid_patch",
                    "Every update hunk must start with @@ or @@ followed by an exact anchor.",
                )
            }
            let anchor = body[index] == "@@" ? nil : String(body[index].dropFirst(3))
            index += 1
            var old: [String] = [], new: [String] = [], eof = false, changed = false
            while index < body.count, !body[index].hasPrefix("@@") {
                let line = body[index]
                index += 1
                if line == "*** End of File" {
                    eof = true
                    guard index == body.count else {
                        throw AgentToolError(
                            "invalid_patch",
                            "EOF must end the final hunk.",
                        )
                    }
                    break
                }
                switch line.first {
                case " ": old.append(String(line.dropFirst()))
                    new.append(String(line.dropFirst()))
                case "-": old.append(String(line.dropFirst()))
                    changed = true
                case "+": new.append(String(line.dropFirst()))
                    changed = true
                default: throw AgentToolError("invalid_patch", "Invalid hunk line prefix.")
                }
            }
            guard changed, !old.isEmpty || original.isEmpty else {
                throw AgentToolError(
                    "invalid_patch",
                    "A hunk needs changes and exact surrounding context; only an empty file allows an unanchored insertion.",
                )
            }
            var start = consumed
            if let anchor {
                let matches = original.indices.filter { $0 >= consumed && original[$0] == anchor }
                guard matches.count == 1, let match = matches.first else {
                    throw AgentToolError(
                        "ambiguous_match",
                        "Hunk \(hunk) in \(path): anchor \(quote(anchor)) matched \(matches.count) times " +
                            "after the preceding hunk; it must match one whole line exactly once.",
                        details: ["path": .string(path), "hunk": .number(Double(hunk)),
                                  "matches": .number(Double(matches.count))],
                    )
                }
                start = match + 1
            }
            let end = original.count - old.count
            let candidates = start <= end ? (start ... end).filter { position in
                (!eof || position + old.count == original.count) &&
                    Array(original[position ..< (position + old.count)]) == old
            } : []
            guard candidates.count == 1, let match = candidates.first else {
                throw mismatch(hunk, path: path, old: old, original: original, from: start, matches: candidates.count)
            }
            output.append(contentsOf: original[consumed ..< match])
            output.append(contentsOf: new)
            consumed = match + old.count
        }
        output.append(contentsOf: original[consumed...])
        return output.joined(separator: "\n") + ((newline || source.isEmpty) && !output.isEmpty ? "\n" : "")
    }

    /// Names the failing hunk and, for zero matches, the first line that cannot be found as a whole line.
    private static func mismatch(
        _ hunk: Int,
        path: String,
        old: [String],
        original: [String],
        from start: Int,
        matches: Int,
    ) -> AgentToolError {
        let first = old.first ?? ""
        var message = "Hunk \(hunk) in \(path), starting \(quote(first)), matched \(matches) times after the preceding hunk"
        var details: [String: JSONValue] = [
            "path": .string(path), "hunk": .number(Double(hunk)), "matches": .number(Double(matches)),
            "first_line": .string(excerpt(first)),
        ]
        guard matches == 0 else {
            return AgentToolError(
                "patch_mismatch",
                message + ". Add context lines or an @@ anchor so it matches exactly once.",
                details: details,
            )
        }
        let remaining = original[min(start, original.count)...]
        if let offset = old.firstIndex(where: { !remaining.contains($0) }) {
            let line = old[offset]
            details["unmatched_line"] = .string(excerpt(line))
            details["unmatched_hunk_line"] = .number(Double(offset + 1))
            let label = "hunk line \(offset + 1), \(quote(line)),"
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let spaced = remaining.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            }) {
                details["whitespace_mismatch_line"] = .number(Double(spaced + 1))
                message += ". The \(label) differs from file line \(spaced + 1) only in surrounding whitespace " +
                    "or line ending."
            } else if !trimmed.isEmpty, let partial = remaining.firstIndex(where: { $0.contains(line) }) {
                details["partial_line_match"] = .number(Double(partial + 1))
                message += ". The \(label) only matches part of file line \(partial + 1); " +
                    "context and removed lines must repeat entire lines."
            } else {
                message += ". The \(label) does not occur in the file after the preceding hunk."
            }
        } else {
            message += ". Every line exists, but not consecutively in this order."
        }
        return AgentToolError("patch_mismatch", message + " Read the file again before retrying.", details: details)
    }

    private static func excerpt(_ line: String) -> String {
        line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    private static func quote(_ line: String) -> String {
        "\"" + excerpt(line) + "\""
    }
}
