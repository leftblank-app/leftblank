import Foundation
@testable import LeftBlankCore
import Testing

@MainActor
struct AgentRecoveryTests {
    @Test func missingImportedPathCanBeRepairedUsingReturnedDiscoveryCall() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let source = fixture.root.appendingPathComponent("Import")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let entry = source.appendingPathComponent("main.typ")
        try Data("Imported content\n".utf8).write(to: entry)
        let document = try await fixture.library.importProject(at: source, mainFile: entry)
        let id = JSONValue.string(document.id.uuidString)
        let missing = await fixture.call("read_file", ["document_id": id, "path": .string("main.typ")])
        #expect(missing.isError)
        #expect(missing.value["error"]["code"].string == "not_found")
        #expect(missing.value["error"]["path_base"].string == "document_root")
        #expect(missing.value["error"]["mutation_state"].string == "not_applicable")
        let step = try #require(missing.value["error"]["recovery"]["next_calls"].array.first)
        let discovered = try await fixture.dispatcher.call(
            #require(step["tool"].string),
            arguments: step["arguments"],
            access: fixture.access,
        )
        #expect(!discovered.isError)
        let path = try #require(discovered.value["items"].array.first?["path"].string)
        #expect(path == "Project/main.typ")
        let read = await fixture.call("read_file", ["document_id": id, "path": .string(path)])
        #expect(read.value["text"].string == "Imported content\n")
    }

    @Test func patchNamesMissingBinaryAndOversizedInputsBeforeAnyWrite() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Failures", text: "Main\n")
        try Data([0, 255, 1]).write(to: document.folderURL.appendingPathComponent("binary.dat"))
        try Data(repeating: 65, count: AgentTools.maximumTextBytes + 1)
            .write(to: document.folderURL.appendingPathComponent("large.typ"))
        for (path, code) in [("missing.typ", "not_found"), ("binary.dat", "not_text"), (
            "large.typ",
            "file_too_large",
        )] {
            let result = await fixture.call("apply_patch", [
                "document_id": .string(document.id.uuidString), "request_id": .string(path),
                "expected_revisions": .object([path: .null]),
                "input": .string("*** Begin Patch\n*** Update File: \(path)\n@@\n-old\n+new\n*** End Patch"),
            ])
            #expect(result.value["error"]["code"].string == code)
            #expect(result.value["error"]["path"].string == path)
            #expect(result.value["error"]["mutation_state"].string == "not_applied")
            #expect(!result.value["error"]["recovery"]["instructions"].isNull)
        }
        #expect(fixture.host.writes == 0)
    }

    @Test func staleWriteCanFollowRecoveryThenUseANewRequestID() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Revision", text: "A\n")
        let base: [String: JSONValue] = ["document_id": .string(document.id.uuidString), "path": .string("main.typ")]
        let initial = await fixture.call("read_file", base)
        var write = base.merging(["old_str": .string("A"), "new_str": .string("B"),
                                  "expected_revision": initial.value["revision"], "request_id": .string("first")])
        { $1
        }
        #expect(await !(fixture.call("str_replace", write)).isError)
        write["old_str"] = .string("B")
        write["new_str"] = .string("C")
        write["request_id"] = .string("stale")
        let rejected = await fixture.call("str_replace", write)
        #expect(rejected.value["error"]["code"].string == "revision_conflict")
        let next = try #require(rejected.value["error"]["recovery"]["next_calls"].array.first)
        let current = try await fixture.dispatcher.call(
            #require(next["tool"].string),
            arguments: next["arguments"],
            access: fixture.access,
        )
        #expect(current.value["text"].string == "B\n")
        write["expected_revision"] = current.value["revision"]
        #expect(await fixture.call("str_replace", write).value["error"]["code"].string == "request_id_conflict")
        write["request_id"] = .string("corrected")
        #expect(await !(fixture.call("str_replace", write)).isError)
        #expect(await fixture.call("read_file", base).value["text"].string == "C\n")
    }

    @Test func partialWriteIdentifiesAppliedUnconfirmedAndUnattemptedPaths() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Partial", text: "Main\n")
        fixture.host.failPath = "b.typ"
        let result = await fixture.call("apply_patch", [
            "document_id": .string(document.id.uuidString), "request_id": .string("partial"),
            "expected_revisions": .object(["a.typ": .null, "b.typ": .null, "c.typ": .null]),
            "input": .string(
                "*** Begin Patch\n*** Add File: a.typ\n+A\n*** Add File: b.typ\n+B\n*** Add File: c.typ\n+C\n*** End Patch",
            ),
        ])
        #expect(result.value["status"].string == "partially_applied")
        #expect(result.value["files"].array.compactMap { $0["path"].string } == ["a.typ"])
        #expect(result.value["remaining_paths"].array.compactMap(\.string) == ["b.typ", "c.typ"])
        #expect(result.value["unconfirmed_paths"].array.compactMap(\.string) == ["b.typ"])
        #expect(result.value["error"]["path"].string == "b.typ")
        #expect(result.value["error"]["mutation_state"].string == "partially_applied")
        #expect(result.value["error"]["recovery"]["retry"].string == "inspect_state_first")
        #expect(fixture.host.writes == 1)
    }

    @Test func nativeFilesystemFailuresDoNotExposeAbsolutePrivatePaths() throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let native = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [NSFilePathErrorKey: "/private/secret/credentials"],
        )
        let result = fixture.dispatcher.failure(native)
        #expect(result.value["error"]["code"].string == "not_found")
        #expect(try !String(decoding: AgentTools.canonical(result.value), as: UTF8.self).contains("/private/secret"))
    }

    @Test func engineFailureKeepsDiagnosticsAndProvidesReadOnlyRepairCalls() {
        let document = UUID()
        let diagnostics: JSONValue = .array([.object([
            "path": .string("Project/main.typ"), "message": .string("file not found"),
            "range": .object(["start": .object(["line": .number(7), "character": .number(0)])]),
        ])])
        let result = AgentToolRecovery.enrich(AgentToolResult(.object([
            "status": .string("failed"), "diagnostics": diagnostics,
        ]), isError: true), tool: "compile_document", arguments: .object(["document_id": .string(document.uuidString)]))
        #expect(result.value["status"].string == "failed")
        #expect(result.value["diagnostics"].array.count == 1)
        #expect(result.value["error"]["code"].string == "compile_failed")
        let calls = result.value["error"]["recovery"]["next_calls"].array
        #expect(calls.compactMap { $0["tool"].string } == ["get_document", "list_files", "read_file"])
        #expect(calls.last?["arguments"]["path"].string == "Project/main.typ")
        #expect(calls.last?["arguments"]["start_line"].int == 8)
        #expect(calls.allSatisfy { call in
            AgentTools.definitions.contains { $0.name == call["tool"].string && $0.readOnly }
        })
    }

    @Test func missingDocumentSuggestsDocumentDiscoveryAndExpiredCursorRetainsQuery() {
        let id = JSONValue.string(UUID().uuidString)
        let missing = AgentToolRecovery.enrich(AgentToolResult(.object([
            "error": AgentToolError("not_found", "Document unavailable", details: ["resource": .string("document")])
                .json,
        ]), isError: true), tool: "read_file", arguments: .object(["document_id": id, "path": .string("main.typ")]))
        #expect(missing.value["error"]["recovery"]["next_calls"].array.first?["tool"].string == "list_documents")
        let expired = AgentToolRecovery.enrich(AgentToolResult(.object([
            "error": AgentToolError("cursor_expired", "Changed snapshot").json,
        ]), isError: true), tool: "search_text", arguments: .object([
            "document_id": id, "query": .string("needle"), "mode": .string("literal"),
            "paths": .array([.string("chapters/**")]), "limit": .number(17), "cursor": .string("old"),
        ]))
        let retry = expired.value["error"]["recovery"]["next_calls"].array.first
        #expect(retry?["tool"].string == "search_text")
        #expect(retry?["arguments"]["query"].string == "needle")
        #expect(retry?["arguments"]["paths"].array.first?.string == "chapters/**")
        #expect(retry?["arguments"]["limit"].int == 17)
        #expect(retry?["arguments"]["cursor"].isNull == true)
    }

    @Test func unknownToolAndInvalidArgumentsAlsoCarryRecovery() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let unknown = await fixture.call("made_up", [:])
        #expect(unknown.value["error"]["code"].string == "unknown_tool")
        #expect(!unknown.value["error"]["recovery"]["instructions"].isNull)
        let invalid = await fixture.call("read_file", ["document_id": .string(UUID().uuidString), "path": .number(1)])
        #expect(invalid.value["error"]["code"].string == "invalid_params")
        #expect(!invalid.value["error"]["recovery"]["instructions"].isNull)
    }
}
