import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
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
        let listed = try await call("list_authoring_guides", [:])
        for guide in listed["items"].array {
            let id = try #require(guide["id"].string)
            let manifest = try await call("read_authoring_guide", ["id": .string(id)])
            let entries = manifest["files"].array.filter { $0["entrypoint"].foundationValue as? Bool == true }
            for entry in entries {
                let path = try #require(entry["path"].string)
                let source = try await call("read_authoring_guide", ["id": .string(id), "path": .string(path)])
                let created = try await call("create_document", [
                    "title": .string(id + "/" + path), "source": source["text"],
                    "request_id": .string(UUID().uuidString),
                ])
                let document = created["document"]["document_id"]
                var revisions: [String: JSONValue] = [:]
                var patch = "*** Begin Patch\n"
                for file in manifest["files"].array where file["path"].string != "main.typ" {
                    let filename = try #require(file["path"].string)
                    let content = try await call("read_authoring_guide", [
                        "id": .string(id), "path": .string(filename),
                    ])
                    let text = try #require(content["text"].string)
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
