import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func agentCompilePreservesLibraryRootWithoutCapturingOtherDocuments() async throws {
        let app = try WritingFixture(text: "= Root fixture\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let document = try await workspace.library.store.create(title: "Root paths", text: "Placeholder\n")
        let reference = "/" + document.id.uuidString + "/shared.typ"
        try Data("#include \"\(reference)\"\n".utf8).write(to: document.sourceURL)
        try Data("= Shared source\n".utf8).write(to: document.folderURL.appendingPathComponent("shared.typ"))
        try await workspace.library.open(document.id)
        try await app.ready()
        let tools = AgentToolDispatcher(
            library: workspace.library.store, history: workspace.history.store, host: workspace,
        )
        let access = AgentToolAccess(documentIDs: [document.id], canWrite: true)
        let id = JSONValue.string(document.id.uuidString)
        let metadata = await tools.call("get_document", arguments: .object(["document_id": id]), access: access)
        #expect(metadata.value["path_base"].string == "document_root")
        #expect(metadata.value["typst_document_prefix"].string == "/" + document.id.uuidString + "/")
        let compiled = await tools.call("compile_document", arguments: .object([
            "document_id": id, "expected_project_revision": metadata.value["project_revision"],
        ]), access: access)
        #expect(!compiled.isError, "\(compiled.value)")
        #expect(compiled.value["project_sources_compiled"].foundationValue as? Bool == true)
        let other = try await workspace.library.store.create(title: "Outside grant", text: "Private source\n")
        let read = await tools.call("read_file", arguments: .object([
            "document_id": id, "path": .string("main.typ"),
        ]), access: access)
        let changed = await tools.call("str_replace", arguments: .object([
            "document_id": id, "path": .string("main.typ"), "old_str": .string(reference),
            "new_str": .string("/" + other.id.uuidString + "/main.typ"),
            "expected_revision": read.value["revision"], "request_id": .string("uncaptured-reference"),
        ]), access: access)
        #expect(!changed.isError)
        let uncaptured = await tools.call("compile_document", arguments: .object([
            "document_id": id, "expected_project_revision": changed.value["project_revision"],
        ]), access: access)
        #expect(uncaptured.isError)
        #expect(uncaptured.value["error"]["code"].string == "compile_failed")
        #expect(!uncaptured.value["error"]["recovery"]["next_calls"].array.isEmpty)
        #expect(uncaptured.value["engine_message"].string?.contains(workspace.stateDirectory.path) != true)
    }
}
