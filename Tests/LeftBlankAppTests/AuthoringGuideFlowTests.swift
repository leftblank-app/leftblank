import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func mcpAuthoringContentWorksWithoutDocumentAccess() async throws {
        let app = try WritingFixture(text: "= Private manuscript\n", startService: false)
        defer { app.close() }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let connection = MCPConnection(
            workspace: app.workspace, helperURL: checkout.appendingPathComponent(".tools/leftblank-mcp"),
        )
        defer { connection.disable() }
        try await connection.enable(documentIDs: [], canWrite: false)
        let descriptor = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: connection.descriptorURL))
        let endpoint = try #require(descriptor["url"].string.flatMap(URL.init(string:)))
        let token = try #require(descriptor["authentication"]["token"].string)
        func post(
            _ method: String, _ params: [String: JSONValue], version: String, status: Int = 200,
        ) async throws -> JSONValue {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
            var arguments = params
            if version == "2026-07-28" {
                request.setValue(method, forHTTPHeaderField: "Mcp-Method")
                if let name = params["name"]?.string ?? params["uri"]?.string {
                    request.setValue(name, forHTTPHeaderField: "Mcp-Name")
                }
                arguments["_meta"] = .object([
                    "io.modelcontextprotocol/protocolVersion": .string(version),
                    "io.modelcontextprotocol/clientInfo": .object([
                        "name": .string("authoring-test"), "version": .string("1"),
                    ]),
                    "io.modelcontextprotocol/clientCapabilities": .object([:]),
                ])
            }
            request.httpBody = try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method),
                "params": .object(arguments),
            ]))
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == status, "\(version) \(method)")
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        for version in ["2025-11-25", "2026-07-28"] {
            let prompts = try await post("prompts/list", [:], version: version)["result"]
            #expect(prompts["prompts"].array.contains { $0["name"].string == "xiaohei-illustrations" })
            #expect(prompts["ttlMs"].int == (version == "2026-07-28" ? 0 : nil))
            let resources = try await post("resources/list", [:], version: version)["result"]
            let workflow = try #require(resources["resources"].array.first {
                $0["name"].string == "xiaohei-illustrations/guide.md"
            })
            let read = try await post("resources/read", ["uri": workflow["uri"]], version: version)["result"]
            let prompt = try await post("prompts/get", [
                "name": .string("xiaohei-illustrations"),
                "arguments": .object(["request": .string("把反馈帮助改进设计画成一张配图")]),
            ], version: version)["result"]
            try #require(prompt["messages"].array.count == 3)
            #expect(prompt["messages"].array[1]["content"]["resource"]["text"].string ==
                read["contents"].array.first?["text"].string)
            let errorStatus = version == "2026-07-28" ? 400 : 200
            let invalid = try await post(
                "resources/read", ["uri": .string("file:///etc/passwd")], version: version, status: errorStatus,
            )
            #expect(invalid["error"]["code"].int == -32602)
            let missing = try await post(
                "prompts/get", ["name": .string("xiaohei-illustrations")], version: version, status: errorStatus,
            )
            #expect(missing["error"]["code"].int == -32602)
        }
    }

    @Test func agentAuthoringStartersRenderThroughDocumentToolsWithRealEngine() async throws {
        let app = try WritingFixture(text: "= Existing manuscript\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let tools = AgentToolDispatcher(
            library: workspace.library.store, history: workspace.history.store, host: workspace,
        )
        let access = AgentToolAccess(documentIDs: nil, canWrite: true)
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            let result = await tools.call(name, arguments: .object(arguments), access: access)
            try #require(!result.isError, "\(name): \(result.value)")
            return result.value
        }
        let resources = try AuthoringGuides.resources()
        for guide in try AuthoringGuides.prompts() {
            let id = try #require(guide["name"].string)
            let files = resources.filter { $0["_meta"]["app.leftblank/authoringGuide"]["id"].string == id }
            let entries = files.filter { $0["_meta"]["app.leftblank/entrypoint"].foundationValue as? Bool == true }
            for entry in entries {
                let path = try #require(entry["_meta"]["app.leftblank/path"].string)
                let source = try AuthoringGuides.readResource(uri: #require(entry["uri"].string))["contents"].array[0]
                let created = try await call("create_document", [
                    "title": .string(id + "/" + path), "source": source["text"],
                    "request_id": .string(UUID().uuidString),
                ])
                let document = created["document"]["document_id"]
                var revisions: [String: JSONValue] = [:]
                var patch = "*** Begin Patch\n"
                for file in files where file["_meta"]["app.leftblank/path"].string != "main.typ" {
                    let filename = try #require(file["_meta"]["app.leftblank/path"].string)
                    let content = try AuthoringGuides.readResource(uri: #require(file["uri"].string))
                    let text = try #require(content["contents"].array.first?["text"].string)
                    revisions[filename] = .null
                    patch += "*** Add File: \(filename)\n" + text.components(separatedBy: "\n").map { "+" + $0 }
                        .joined(separator: "\n") + "\n"
                }
                patch += "*** End Patch"
                _ = try await call("apply_patch", [
                    "document_id": document, "input": .string(patch), "expected_revisions": .object(revisions),
                    "request_id": .string(UUID().uuidString),
                ])
                let metadata = try await call("get_document", ["document_id": document])
                let rendered = await tools.call("render_page", arguments: .object([
                    "document_id": document, "expected_project_revision": metadata["project_revision"],
                    "ppi": .number(72),
                ]), access: access)
                #expect(!rendered.isError, "\(id)/\(path): \(rendered.value)")
                #expect((rendered.value["page_count"].int ?? 0) >= 1)
                #expect(rendered.value["is_current"].foundationValue as? Bool == true)
                let png = try #require(rendered.images.first)
                let bitmap = try #require(NSBitmapImageRep(data: png.data))
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            }
        }
    }
}
