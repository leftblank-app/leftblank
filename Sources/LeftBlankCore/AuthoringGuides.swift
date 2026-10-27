import Foundation

/// Bundled methods and starter sources. Catalog entries, not tool names, define new capabilities.
enum AuthoringGuides {
    struct File: Decodable, Sendable {
        let path: String
        let resource: String
        let description: String
        let entrypoint: Bool?

        var json: JSONValue {
            .object([
                "path": .string(path), "description": .string(description),
                "entrypoint": .bool(entrypoint ?? false),
            ])
        }
    }

    struct Guide: Decodable, Sendable {
        let id: String
        let title: String
        let summary: String
        let version: String
        let keywords: [String]
        let files: [File]

        var json: JSONValue {
            .object([
                "id": .string(id), "title": .string(title), "summary": .string(summary),
                "version": .string(version), "keywords": .array(keywords.map(JSONValue.string)),
            ])
        }

        func matches(_ query: String) -> Bool {
            let text = ([id, title, summary] + keywords).joined(separator: " ")
            return query.split(whereSeparator: \.isWhitespace).allSatisfy {
                text.localizedStandardContains(String($0))
            }
        }
    }

    static let maximumFileBytes = 32 * 1024
    private static let catalog = Result {
        let data = try resource("authoring-guides.json")
        return try JSONDecoder().decode([Guide].self, from: data)
    }

    static func list(query: String = "") throws -> [JSONValue] {
        try catalog.get().filter { $0.matches(query) }.map(\.json)
    }

    static func read(id: String, path: String = "guide.md") throws -> JSONValue {
        guard let guide = try catalog.get().first(where: { $0.id == id }) else {
            throw AgentToolError(
                "not_found",
                "No bundled authoring guide has this id. Use list_authoring_guides to discover available guides.",
                details: ["suggested_tool": .string("list_authoring_guides")],
            )
        }
        // Only exact catalog entries are addressable; caller paths never become filesystem paths.
        guard let file = guide.files.first(where: { $0.path == path }) else {
            throw AgentToolError(
                "not_found",
                "This file is not part of the guide. Read guide.md for the available file paths.",
                details: ["suggested_tool": .string("read_authoring_guide")],
            )
        }
        let data = try resource(file.resource)
        guard data.count <= maximumFileBytes, let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError("unavailable", "The bundled guide file is not bounded UTF-8 text.")
        }
        return .object([
            "guide": guide.json, "path": .string(file.path), "text": .string(text),
            "files": .array(guide.files.map(\.json)),
        ])
    }

    private static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw AgentToolError("unavailable", "A bundled authoring guide resource is missing.")
        }
        return try Data(contentsOf: url)
    }
}
