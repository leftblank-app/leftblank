import Foundation

extension AgentToolDispatcher {
    func queryKey(_ name: String, args: AgentArguments, access: AgentToolAccess) throws -> String {
        var values = args.values
        values.removeValue(forKey: "cursor")
        return try AgentTools.digest(Data((name + access.id.uuidString).utf8) + (AgentTools.canonical(.object(values))))
    }

    func offset(args: AgentArguments, query: String, snapshot: String) throws -> Int {
        guard let token = args["cursor"].string else {
            return 0
        }
        guard let cursor = cursors[token], cursor.query == query, cursor.snapshot == snapshot else {
            throw AgentToolError("cursor_expired", "The query or its snapshot changed; restart the read.")
        }
        return cursor.offset
    }

    func cursor(query: String, snapshot: String, offset: Int) -> JSONValue {
        let token = UUID().uuidString
        cursors[token] = (query, snapshot, offset)
        cursorOrder.append(token)
        if cursorOrder.count > 128 {
            cursors.removeValue(forKey: cursorOrder.removeFirst())
        }
        return .string(token)
    }

    func page(
        _ values: [JSONValue],
        args: AgentArguments,
        name: String,
        snapshot: String,
        access: AgentToolAccess,
    ) throws -> JSONValue {
        let query = try queryKey(name, args: args, access: access)
        let start = try offset(args: args, query: query, snapshot: snapshot)
        guard start <= values.count else {
            throw AgentToolError("cursor_expired", "Restart the query.")
        }
        let limit = args.integer("limit", default: 100)
        var end = start, bytes = 0
        while end < values.count, end - start < limit {
            let size = try AgentTools.canonical(values[end]).count
            guard size < 128 * 1024 else {
                throw AgentToolError(
                    "result_too_large",
                    "A result exceeds the output budget.",
                )
            }
            if end > start, bytes + size > 128 * 1024 {
                break
            }
            bytes += size
            end += 1
        }
        return .object(["items": .array(Array(values[start ..< end])), "truncated": .bool(end < values.count),
                        "next_cursor": end < values
                            .count ? cursor(query: query, snapshot: snapshot, offset: end) : .null])
    }

    func listFiles(
        _ snapshot: AgentProjectSnapshot,
        document: LibraryDocument,
        args: AgentArguments,
        access: AgentToolAccess,
    ) throws -> JSONValue {
        let folder = args.string("path")
        if !folder.isEmpty {
            _ = try AgentProjectFiles.url(folder, in: document.folderURL)
        }
        let prefix = folder.isEmpty ? "" : folder + "/"
        var rows: [JSONValue] = []
        let texts = snapshot.texts
        for path in (Set(snapshot.files.keys).union(snapshot.omitted)).sorted() {
            guard path.hasPrefix(prefix),
                  args.bool("recursive", default: true) || !path.dropFirst(prefix.count).contains("/"),
                  try AgentProjectFiles.matches(path, glob: args.string("glob", default: "**/*"))
            else {
                continue
            }
            let data = snapshot.files[path]
            rows.append(.object(["path": .string(path), "type": .string(texts[path] == nil ? "resource" : "text"),
                                 "bytes": data.map { .number(Double($0.count)) } ?? .null,
                                 "revision": data
                                     .map { .string(revision($0, document: document, path: path)) } ?? .null,
                                 "available": .bool(data != nil)]))
        }
        var value = try page(
            rows,
            args: args,
            name: "list_files",
            snapshot: projectRevision(snapshot, document: document),
            access: access,
        ).objectValues
        value["incomplete"] = .bool(!snapshot.omitted.isEmpty)
        return .object(value)
    }

    func read(
        _ source: String,
        revision: String?,
        versionID: String?,
        args: AgentArguments,
        access: AgentToolAccess,
    ) throws -> JSONValue {
        let query = try queryKey("read_file", args: args, access: access)
        let snapshot = revision ?? AgentTools.digest(Data(source.utf8))
        let text = source as NSString
        let lines = source.components(separatedBy: "\n")
        let startLine = args.integer("start_line", default: 1)
        guard startLine <= lines.count else {
            throw AgentToolError("invalid_params", "start_line is beyond the file.")
        }
        let start: Int = if args["cursor"].isNull {
            lines.prefix(startLine - 1).reduce(0) { $0 + $1.utf16.count + 1 }
        } else {
            try offset(args: args, query: query, snapshot: snapshot)
        }
        guard start <= text.length else {
            throw AgentToolError("cursor_expired", "Restart the read.")
        }
        var end = start, count = 0
        let maxLines = args.integer("max_lines", default: 200)
        while end < text.length, count < maxLines, end - start < 32768 {
            let unit = text.character(at: end)
            if unit == 13, end + 1 < text.length, text.character(at: end + 1) == 10 {
                end += 2
                count += 1
            } else {
                if unit == 10 {
                    count += 1
                }
                end += (0xD800 ... 0xDBFF).contains(unit) ? 2 : 1
            }
        }
        let truncated = end < text.length
        let actualStart = text.substring(to: start).utf8.filter { $0 == 10 }.count + 1
        var value: [String: JSONValue] = [
            "path": args["path"],
            "text": .string(text.substring(with: NSRange(location: start, length: end - start))),
            "start_line": .number(Double(actualStart)),
            "end_line": .number(Double(actualStart + count -
                    (end > start && text.character(at: end - 1) == 10 ? 1 : 0))),
            "total_lines": .number(Double(lines.count)),
            "truncated": .bool(truncated),
            "next_cursor": truncated ? cursor(query: query, snapshot: snapshot, offset: end) : .null,
        ]
        if let revision {
            value["revision"] = .string(revision)
        }
        if let versionID {
            value["version_id"] = .string(versionID)
        }
        return .object(value)
    }

    func search(
        _ snapshot: AgentProjectSnapshot,
        document: LibraryDocument,
        args: AgentArguments,
        access: AgentToolAccess,
    ) throws -> JSONValue {
        let query = args.string("query")
        guard !query.isEmpty, query.utf8.count <= 4096 else {
            throw AgentToolError(
                "invalid_params",
                "query must contain 1–4096 bytes.",
            )
        }
        let pattern = args.string("mode", default: "literal") == "regex" ? query : NSRegularExpression
            .escapedPattern(for: query)
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(
            pattern: pattern,
            options: args.bool("case_sensitive", default: true) ? [] : [.caseInsensitive],
        ) } catch { throw AgentToolError("invalid_params", "Invalid regular expression.") }
        let deadline = Date().addingTimeInterval(0.25)
        let texts = snapshot.texts
        var rows: [JSONValue] = [], incomplete = snapshot.omitted, exhausted = false
        for path in snapshot.files.keys.sorted() {
            if !args["paths"].isNull,
               try !args["paths"].array.compactMap(\.string).contains(where: { try AgentProjectFiles.matches(
                   path,
                   glob: $0,
               ) })
            {
                continue
            }
            guard let source = texts[path], let data = snapshot.files[path] else {
                // Binary assets are not search targets. Oversized UTF-8 candidates must be reported.
                if let data = snapshot.files[path], !data.contains(0),
                   String(data: data, encoding: .utf8) != nil
                {
                    incomplete.append(path)
                }
                continue
            }
            if exhausted || Date() >= deadline {
                incomplete.append(path)
                exhausted = true
                continue
            }
            let metrics = DocumentMetrics(source)
            let lines = source.components(separatedBy: "\n")
            let revision = revision(data, document: document, path: path)
            regex.enumerateMatches(
                in: source,
                options: [.reportProgress],
                range: NSRange(location: 0, length: source.utf16.count),
            ) { match, _, stop in
                if Date() >= deadline || rows.count >= 5000 {
                    exhausted = true
                    stop.pointee = true
                    return
                }
                guard let match else {
                    return
                }
                let start = metrics.position(at: match.range.location),
                    end = metrics.position(at: NSMaxRange(match.range))
                let context = args.integer("context_lines", default: 2)
                let lower = max(0, start.line - context), upper = min(lines.count, end.line + context + 1)
                let excerpt = lines[lower ..< upper].joined(separator: "\n")
                rows.append(.object([
                    "path": .string(path),
                    "revision": .string(revision),
                    "position_encoding": .string("utf-16"),
                    "line_number": .number(Double(start.line + 1)),
                    "context": .string(AgentTools.excerpt(excerpt, limit: 1500)),
                    "context_truncated": .bool(excerpt.unicodeScalars.count > 1500),
                    "range": .object(["start": Self.position(start), "end": Self.position(end)]),
                ]))
            }
            if exhausted {
                incomplete.append(path)
            }
        }
        var value = try page(
            rows,
            args: args,
            name: "search_text",
            snapshot: projectRevision(snapshot, document: document) + AgentTools
                .digest(AgentTools.canonical(.array(rows))),
            access: access,
        ).objectValues
        value["incomplete"] = .bool(!incomplete.isEmpty)
        value["unsearched_paths"] = .array(Array(Set(incomplete)).sorted().prefix(500).map(JSONValue.string))
        value["budget_exhausted"] = .bool(exhausted)
        return .object(value)
    }

    static func position(_ value: TextPosition) -> JSONValue {
        .object(["line": .number(Double(value.line)), "character": .number(Double(value.character))])
    }
}
