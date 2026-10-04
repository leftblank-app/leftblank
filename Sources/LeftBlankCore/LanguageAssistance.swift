import Foundation

public struct LanguageHover: Equatable, Sendable {
    public let text: String
}

public struct LanguageSignature: Equatable, Sendable {
    public let label: String
    public let documentation: String
    public let activeParameter: String?
    public let parameterDocumentation: String
}

/// A complete, validated edit against the exact document revision requested.
/// The caller must recheck the URL and version before applying every edit in one undo operation.
public struct SourceCodeAction: Equatable, Sendable {
    public let title: String
    public let kind: String?
    public let isPreferred: Bool
    public let edits: [TextReplacement]
    public let documentURL: URL
    public let sourceVersion: Int
}

public struct SourceCompletion: Equatable, Sendable {
    public let label: String
    public let detail: String
    public let edits: [TextReplacement]
    public let insertionEnd: Int
    public let selections: [NSRange]
}

public enum LanguageAssistance {
    /// Completion edits remain local; numbered placeholders use the native snippet navigation.
    public static func completions(
        _ response: JSONValue,
        source: String,
        selection: NSRange,
    ) -> [SourceCompletion] {
        let positions = SourcePositions(source)
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= positions.units.count,
              selection.length <= positions.units.count - selection.location,
              scalarBoundary(selection.location, in: positions.units),
              scalarBoundary(NSMaxRange(selection), in: positions.units)
        else {
            return []
        }
        let defaults = response["itemDefaults"]
        let items = response.array.isEmpty ? response["items"].array : response.array
        return items.prefix(100).compactMap { item in
            let format = item["insertTextFormat"].int ?? defaults["insertTextFormat"].int ?? 1
            guard let label = item["label"].string, !label.isEmpty,
                  [1, 2].contains(format), item["command"].isNull
            else {
                return nil
            }
            let edit = item["textEdit"]
            let rawContent = edit["newText"].string ?? item["textEditText"].string
                ?? item["insertText"].string ?? label
            guard rawContent.utf16.count <= 1_000_000,
                  let snippet = format == 2 ? CompletionSnippet.decode(rawContent) : Snippet(text: rawContent)
            else {
                return nil
            }
            let content = snippet.text
            var range = selection
            let declaredRange = edit.isNull ? defaults["editRange"]
                : (edit["range"].isNull ? edit["replace"] : edit["range"])
            if !declaredRange.isNull {
                let value = declaredRange["replace"].isNull ? declaredRange : declaredRange["replace"]
                guard let start = positions.offset(value["start"]),
                      let end = positions.offset(value["end"]), end >= start
                else {
                    return nil
                }
                range = NSRange(location: start, length: end - start)
            } else if !edit.isNull {
                return nil
            }
            var edits = [TextReplacement(range: range, text: content)]
            if !item["additionalTextEdits"].isNull {
                guard case let .array(additional) = item["additionalTextEdits"] else {
                    return nil
                }
                if !additional.isEmpty {
                    guard let extra = decodeEdits(item["additionalTextEdits"], positions: positions) else {
                        return nil
                    }
                    edits += extra
                }
            }
            edits.sort { $0.range.location < $1.range.location }
            for (first, next) in zip(edits, edits.dropFirst()) {
                guard next.range.location >= NSMaxRange(first.range),
                      next.range.location != first.range.location
                else {
                    return nil
                }
            }
            let deltaBefore = edits.filter { $0.range.location < range.location }
                .reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
            return SourceCompletion(
                label: String(label.prefix(240)), detail: documentation(item["detail"]),
                edits: edits, insertionEnd: range.location + content.utf16.count + deltaBefore,
                selections: snippet.selections.map { NSRange(
                    location: range.location + deltaBefore + $0.location,
                    length: $0.length,
                ) },
            )
        }
    }

    public static func hover(_ response: JSONValue) -> LanguageHover? {
        let text = documentation(response["contents"])
        return text.isEmpty ? nil : LanguageHover(text: text)
    }

    public static func signatureHelp(_ response: JSONValue) -> LanguageSignature? {
        let signatures = response["signatures"].array
        guard !signatures.isEmpty else {
            return nil
        }
        let index = response["activeSignature"].int ?? 0
        let signature = signatures[signatures.indices.contains(index) ? index : 0]
        guard let label = signature["label"].string, !label.isEmpty else {
            return nil
        }
        let parameters = signature["parameters"].array
        let activeIndex = signature["activeParameter"].int ?? response["activeParameter"].int ?? 0
        let parameter = parameters.indices.contains(activeIndex) ? parameters[activeIndex] : .null
        let parameterLabel: String?
        if let text = parameter["label"].string {
            parameterLabel = text
        } else {
            let offsets = parameter["label"].array
            if offsets.count == 2, let start = offsets[0].int, let end = offsets[1].int,
               start >= 0, end >= start, end <= label.utf16.count,
               scalarBoundary(start, in: Array(label.utf16)), scalarBoundary(end, in: Array(label.utf16))
            {
                parameterLabel = (label as NSString).substring(with: NSRange(location: start, length: end - start))
            } else {
                parameterLabel = nil
            }
        }
        return LanguageSignature(
            label: String(label.prefix(8000)),
            documentation: documentation(signature["documentation"]),
            activeParameter: parameterLabel,
            parameterDocumentation: documentation(parameter["documentation"]),
        )
    }

    /// Reads LSP MarkupContent, MarkedString, and MarkedString arrays as inert text.
    /// No HTML renderer, network resource, or executable link is involved.
    public static func documentation(_ value: JSONValue) -> String {
        let parts: [String]
        switch value {
        case let .string(text): parts = [readableMarkdown(text)]
        case let .array(values): parts = values.prefix(32).map(documentation)
        case .object:
            guard let text = value["value"].string else {
                return ""
            }
            parts = [value["kind"].string == "plaintext" || value["language"].string != nil
                ? String(text.prefix(8000)) : readableMarkdown(text)]
        default: return ""
        }
        return String(parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(8000))
    }

    public static func codeActions(
        _ response: JSONValue,
        source: String,
        documentURL: URL,
        version: Int,
    ) -> [SourceCodeAction] {
        guard documentURL.isFileURL else {
            return []
        }
        let positions = SourcePositions(source)
        return response.array.prefix(64).compactMap { action in
            guard let title = action["title"].string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  action["command"].isNull, action["disabled"].isNull,
                  case let .object(workspaceEdit) = action["edit"],
                  action["edit"]["changeAnnotations"].isNull
            else {
                return nil
            }
            var edits: [TextReplacement] = []
            let changes = workspaceEdit["changes"] ?? .null
            let documentChanges = workspaceEdit["documentChanges"] ?? .null
            // Do not silently prefer one representation and discard potentially required changes.
            guard changes.isNull || documentChanges.isNull else {
                return nil
            }
            if case let .object(files) = changes {
                guard files.count == 1, let (uri, values) = files.first,
                      sameDocument(uri, documentURL),
                      let decoded = decodeEdits(values, positions: positions)
                else {
                    return nil
                }
                edits = decoded
            } else if case let .array(documents) = documentChanges, !documents.isEmpty, documents.count <= 64 {
                for document in documents {
                    guard document["kind"].isNull, let uri = document["textDocument"]["uri"].string,
                          sameDocument(uri, documentURL)
                    else {
                        return nil
                    }
                    let documentVersion = document["textDocument"]["version"]
                    guard documentVersion.isNull || documentVersion.int == version,
                          let decoded = decodeEdits(document["edits"], positions: positions)
                    else {
                        return nil
                    }
                    edits.append(contentsOf: decoded)
                }
            } else {
                return nil
            }
            guard !edits.isEmpty, edits.count <= 256 else {
                return nil
            }
            let ordered = edits.sorted {
                $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1
                    .range.location
            }
            for (first, next) in zip(ordered, ordered.dropFirst()) {
                guard next.range.location >= NSMaxRange(first.range),
                      next.range.location != first.range.location
                else {
                    return nil
                }
            }
            let preferred: Bool = if case let .bool(value) = action["isPreferred"] {
                value
            } else {
                false
            }
            return SourceCodeAction(
                title: String(title.prefix(240)),
                kind: action["kind"].string,
                isPreferred: preferred,
                edits: ordered,
                documentURL: documentURL,
                sourceVersion: version,
            )
        }
    }

    private static func decodeEdits(_ value: JSONValue, positions: SourcePositions) -> [TextReplacement]? {
        guard case let .array(values) = value, !values.isEmpty, values.count <= 256 else {
            return nil
        }
        var result: [TextReplacement] = []
        for edit in values {
            guard edit["annotationId"].isNull,
                  edit["insertTextFormat"].isNull || edit["insertTextFormat"].int == 1,
                  let text = edit["newText"].string, text.utf16.count <= 1_000_000,
                  let start = positions.offset(edit["range"]["start"]),
                  let end = positions.offset(edit["range"]["end"]),
                  end >= start
            else {
                return nil
            }
            result.append(TextReplacement(range: NSRange(location: start, length: end - start), text: text))
        }
        return result
    }

    private static func sameDocument(_ uri: String, _ documentURL: URL) -> Bool {
        guard let url = URL(string: uri), url.isFileURL,
              url.host == nil || url.host?.isEmpty == true || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.port == nil
        else {
            return false
        }
        return url.standardizedFileURL.path == documentURL.standardizedFileURL.path
    }

    private struct SourcePositions {
        let units: [UInt16]
        let lines: [Range<Int>]

        init(_ text: String) {
            units = Array(text.utf16)
            var ranges: [Range<Int>] = []
            var start = 0
            var index = 0
            while index < units.count {
                if units[index] == 10 || units[index] == 13 {
                    ranges.append(start ..< index)
                    if units[index] == 13, index + 1 < units.count, units[index + 1] == 10 {
                        index += 1
                    }
                    start = index + 1
                }
                index += 1
            }
            ranges.append(start ..< units.count)
            lines = ranges
        }

        func offset(_ value: JSONValue) -> Int? {
            guard let line = value["line"].int, let character = value["character"].int,
                  lines.indices.contains(line), character >= 0, character <= lines[line].count
            else {
                return nil
            }
            let offset = lines[line].lowerBound + character
            return scalarBoundary(offset, in: units) ? offset : nil
        }
    }

    private static func scalarBoundary(_ offset: Int, in units: [UInt16]) -> Bool {
        offset == 0 || offset == units.count || !(0xD800 ... 0xDBFF).contains(units[offset - 1]) || !(0xDC00 ... 0xDFFF)
            .contains(units[offset])
    }

    private static func readableMarkdown(_ source: String) -> String {
        var text = String(source.prefix(16000)).replacingOccurrences(of: "\r\n", with: "\n")
        let replacements: [(String, String)] = [
            (#"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, ""),
            (#"(?is)<!--.*?-->"#, ""),
            (#"!\[[^\]]*\]\([^\n]*?\)|!\[[^\]]*\]\[[^\]]*\]"#, ""),
            (#"(?i)<br\s*/?>|</p\s*>|</div\s*>"#, "\n"),
            (#"<[^>\n]*>"#, ""),
            (#"\[([^\]]+)\]\([^\n]*?\)|\[([^\]]+)\]\[[^\]]*\]"#, "$1$2"),
            (#"(?m)^\s*\[[^\]]+\]:\s+\S+.*$"#, ""),
            (#"(?m)^\s*(`{3,}|~{3,})[^\n]*$"#, ""),
            (#"(?m)^\s*#{1,6}\s+"#, ""),
            (#"(?m)^\s*>\s?"#, ""),
            (#"`([^`\n]+)`"#, "$1"),
            (#"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#, "$1$2"),
            (#"\n[ \t]*\n(?:[ \t]*\n)+"#, "\n\n"),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
