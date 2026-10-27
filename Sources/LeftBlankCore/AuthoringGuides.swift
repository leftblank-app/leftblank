import Foundation

/// Shared authoring content, exposed through MCP Resources and Prompts on macOS.
public enum AuthoringGuides {
    private struct File: Decodable, Sendable {
        let path: String
        let description: String
        let entrypoint: Bool?

        var mimeType: String {
            path.hasSuffix(".md") ? "text/markdown" : "text/plain"
        }
    }

    private struct Guide: Decodable, Sendable {
        let id: String
        let title: String
        let summary: String
        let version: String
        let keywords: [String]
        let fallback: Bool?
        let files: [File]

        var metadata: JSONValue {
            .object([
                "id": .string(id), "version": .string(version),
                "fallback": .bool(fallback ?? false),
            ])
        }

        func uri(_ file: File) -> String {
            "leftblank://guides/\(id)/\(file.path)"
        }
    }

    static let maximumFileBytes = 32 * 1024
    private static let catalog = Result {
        let data = try resource("catalog.json")
        return try JSONDecoder().decode([Guide].self, from: data)
    }

    /// Standard resource descriptors. Metadata supplements the human-readable descriptions.
    public static func resources() throws -> [JSONValue] {
        try catalog.get().flatMap { guide in
            guide.files.map { file in
                .object([
                    "uri": .string(guide.uri(file)), "name": .string("\(guide.id)/\(file.path)"),
                    "title": .string("\(guide.title): \(file.path)"),
                    "description": .string("\(guide.summary) \(file.description)"),
                    "mimeType": .string(file.mimeType),
                    "_meta": .object([
                        "app.leftblank/authoringGuide": guide.metadata,
                        "app.leftblank/path": .string(file.path),
                        "app.leftblank/entrypoint": .bool(file.entrypoint ?? false),
                    ]),
                ])
            }
        }
    }

    /// Standard prompt descriptors; the client chooses a workflow from these descriptions.
    public static func prompts() throws -> [JSONValue] {
        try catalog.get().map { guide in
            .object([
                "name": .string(guide.id), "title": .string(guide.title),
                "description": .string(guide.summary + " Keywords: " + guide.keywords.joined(separator: ", ")),
                "arguments": .array([.object([
                    "name": .string("request"), "required": .bool(true),
                    "description": .string("The user's authoring request, including any known constraints."),
                ])]),
                "_meta": .object(["app.leftblank/authoringGuide": guide.metadata]),
            ])
        }
    }

    public static func readResource(uri: String) throws -> JSONValue {
        // Exact catalog lookup only. Do not normalize or interpret caller URIs as filesystem paths.
        for guide in try catalog.get() {
            if let file = guide.files.first(where: { guide.uri($0) == uri }) {
                return try .object(["contents": .array([contents(guide: guide, file: file)])])
            }
        }
        throw AgentToolError("invalid_params", "Unknown authoring resource URI. Discover URIs with resources/list.")
    }

    public static func getPrompt(name: String, arguments: JSONValue) throws -> JSONValue {
        guard let guide = try catalog.get().first(where: { $0.id == name }) else {
            throw AgentToolError("invalid_params", "Unknown authoring prompt. Discover names with prompts/list.")
        }
        guard case let .object(values) = arguments, values.count == 1,
              let request = values["request"]?.string,
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.utf8.count <= maximumFileBytes
        else {
            throw AgentToolError(
                "invalid_params",
                "Supply one nonempty string argument named request (at most 32 KiB).",
            )
        }
        guard let workflow = guide.files.first(where: { $0.path == "guide.md" }) else {
            throw AgentToolError("unavailable", "The bundled authoring workflow is missing.")
        }
        let links = guide.files.map { "- \($0.path): \(guide.uri($0)) — \($0.description)" }.joined(separator: "\n")
        return try .object([
            "description": .string(guide.title),
            "messages": .array([
                .object(["role": .string("user"), "content": .object([
                    "type": .string("text"),
                    "text": .string("Use the attached authoring workflow for the request below. " +
                        "Follow the user's explicit constraints. Read supporting files with resources/read " +
                        "as needed, then use document tools to create, compile, render and inspect the result.\n" +
                        links),
                ])]),
                .object(["role": .string("user"), "content": .object([
                    "type": .string("resource"), "resource": contents(guide: guide, file: workflow),
                ])]),
                .object(["role": .string("user"), "content": .object([
                    "type": .string("text"), "text": .string("User request:\n" + request),
                ])]),
            ]),
        ])
    }

    private static func contents(guide: Guide, file: File) throws -> JSONValue {
        let data = try resource(file.path, directory: "AuthoringGuides/\(guide.id)")
        guard data.count <= maximumFileBytes, let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError("unavailable", "The bundled guide file is not bounded UTF-8 text.")
        }
        return .object([
            "uri": .string(guide.uri(file)), "mimeType": .string(file.mimeType), "text": .string(text),
        ])
    }

    private static func resource(_ name: String, directory: String = "AuthoringGuides") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: directory) else {
            throw AgentToolError("unavailable", "A bundled authoring guide resource is missing.")
        }
        return try Data(contentsOf: url)
    }
}
