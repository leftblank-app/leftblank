import Foundation
@testable import LeftBlankCore
import Testing

@MainActor
struct AgentProjectAccessTests {
    @Test func singleFileReadsDoNotScanUnrelatedOversizedResources() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Targeted reads", text: "Small source\n")
        let resource = document.folderURL.appendingPathComponent("large.bin")
        try Data().write(to: resource)
        let handle = try FileHandle(forWritingTo: resource)
        try handle.truncate(atOffset: 16 * 1024 * 1024 + 1)
        try handle.close()
        let id = JSONValue.string(document.id.uuidString)
        let read = await fixture.call("read_file", ["document_id": id, "path": .string("main.typ")])
        #expect(!read.isError)
        #expect(read.value["text"].string == "Small source\n")
        // A complete project snapshot still enforces the resource budget.
        let project = await fixture.call("get_document", ["document_id": id])
        #expect(project.value["error"]["code"].string == "project_too_large")
    }

    @Test func internalMetadataIsNeitherListedNorEditable() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Metadata boundary", text: "Source\n")
        let id = JSONValue.string(document.id.uuidString)
        let listing = await fixture.call("list_files", ["document_id": id])
        #expect(listing.value["items"].array.compactMap { $0["path"].string } == ["main.typ"])
        for path in ["document.json", "Document.json", "document.json/child.typ"] {
            let read = await fixture.call("read_file", ["document_id": id, "path": .string(path)])
            #expect(read.value["error"]["code"].string == "unsafe_path")
        }
        let patched = await fixture.call("apply_patch", [
            "document_id": id, "request_id": .string("metadata-must-not-change"),
            "expected_revisions": .object(["document.json": .null]),
            "input": .string("*** Begin Patch\n*** Add File: document.json\n+{}\n*** End Patch"),
        ])
        #expect(patched.value["error"]["code"].string == "unsafe_path")
        #expect(try await fixture.library.read(document.id).document.title == "Metadata boundary")
    }
}
