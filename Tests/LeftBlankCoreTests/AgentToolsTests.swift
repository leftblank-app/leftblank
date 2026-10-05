import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing

@MainActor
struct AgentToolsTests {
    @Test func documentLifecycleAndVersionedProjectEdits() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let created = await fixture.call(
            "create_document",
            ["title": .string("Test"), "source": .string("= Draft\nHello 中文 😀\n"), "request_id": .string("create")],
        )
        #expect(!created.isError)
        let id = try #require(created.value["document"]["document_id"].string)
        let base: [String: JSONValue] = ["document_id": .string(id), "path": .string("main.typ")]
        let read = await fixture.call("read_file", base)
        #expect(read.value["text"].string == "= Draft\nHello 中文 😀\n")
        let revision = try #require(read.value["revision"].string)
        var edit = base
        edit.merge([
            "old_str": .string("Hello"),
            "new_str": .string("Welcome"),
            "expected_revision": .string(revision),
            "request_id": .string("edit"),
        ]) { _, new in new }
        let result = await fixture.call("str_replace", edit)
        #expect(!result.isError)
        #expect(result.value["status"].string == "applied")
        #expect(fixture.host.writes == 1)
        let retry = await fixture.call("str_replace", edit)
        #expect(!retry.isError && fixture.host.writes == 1)
        edit["new_str"] = .string("Different")
        #expect(await fixture.call("str_replace", edit).value["error"]["code"].string == "request_id_conflict")
        edit["request_id"] = .string("old-revision")
        edit["old_str"] = .string("Welcome")
        #expect(await fixture.call("str_replace", edit).value["error"]["code"].string == "revision_conflict")
        let versions = await fixture.call("list_file_versions", base)
        let version = try #require(versions.value["versions"].array.first?["version_id"].string)
        var historical = base
        historical["version_id"] = .string(version)
        let old = await fixture.call("read_file", historical)
        #expect(old.value["text"].string?.contains("Hello") == true)
        #expect(old.value["revision"].isNull)
        var restore = historical
        restore["expected_revision"] = result.value["files"].array[0]["after_revision"]
        restore["request_id"] = .string("restore")
        #expect(await fixture.call("restore_file_version", restore).value["status"].string == "applied")
        let added = await fixture.call("apply_patch", ["document_id": .string(id), "request_id": .string("add"),
                                                       "expected_revisions": .object([
                                                           "chapters/one.typ": .null,
                                                           "data.json": .null,
                                                       ]),
                                                       "input": .string(
                                                           "*** Begin Patch\n*** Add File: chapters/one.typ\n+Chapter\n*** Add File: data.json\n+{\"value\":1}\n*** End Patch",
                                                       )])
        #expect(!added.isError)
        let chapterRead = await fixture.call(
            "read_file",
            ["document_id": .string(id), "path": .string("chapters/one.typ")],
        )
        let deleted = await fixture.call("apply_patch", ["document_id": .string(id), "request_id": .string("delete"),
                                                         "expected_revisions": .object(["chapters/one.typ": chapterRead
                                                                 .value["revision"]]),
                                                         "input": .string(
                                                             "*** Begin Patch\n*** Delete File: chapters/one.typ\n*** End Patch",
                                                         )])
        #expect(!deleted.isError)
        let preimage = try #require(deleted.value["files"].array.first?["before_version_id"].string)
        #expect(await fixture.call(
            "restore_file_version",
            [
                "document_id": .string(id),
                "path": .string("chapters/one.typ"),
                "version_id": .string(preimage),
                "expected_revision": .null,
                "request_id": .string("recover-deleted"),
            ],
        ).value["status"].string == "applied")
        let metadata = await fixture.call("get_document", ["document_id": .string(id)])
        #expect(metadata.value["project_revision"].string != nil)
        let renamed = await fixture.call(
            "rename_document",
            [
                "document_id": .string(id),
                "title": .string("Renamed"),
                "expected_metadata_revision": metadata.value["metadata_revision"],
                "request_id": .string("rename"),
            ],
        )
        #expect(renamed.value["document"]["title"].string == "Renamed")
        let trashed = await fixture.call(
            "trash_document",
            [
                "document_id": .string(id),
                "expected_metadata_revision": renamed.value["document"]["metadata_revision"],
                "request_id": .string("trash"),
            ],
        )
        #expect(!trashed.isError)
        #expect(await fixture.call("read_file", base).isError)
        #expect(await fixture.call("list_documents", [:]).value["items"].array.isEmpty)
        #expect(await fixture.call("list_documents", ["include_trashed": .bool(true)]).value["items"].array.count == 1)
        #expect(await fixture.call(
            "restore_document",
            [
                "document_id": .string(id),
                "expected_metadata_revision": trashed.value["document"]["metadata_revision"],
                "request_id": .string("untrash"),
            ],
        ).value["status"].string == "applied")
    }

    @Test func scopesUnknownFieldsSymlinksAndStaleMetadataAreRejected() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "One", text: "word word\n")
        let id = document.id.uuidString
        let denied = AgentToolAccess(documentIDs: [], canWrite: true)
        #expect(await fixture.dispatcher.call(
            "get_document",
            arguments: .object(["document_id": .string(id)]),
            access: denied,
        ).isError)
        #expect(await fixture.dispatcher.call(
            "create_document",
            arguments: .object(["title": .string("X"), "source": .string(""), "request_id": .string("r")]),
            access: denied,
        ).isError)
        let readonly = AgentToolAccess(documentIDs: nil, canWrite: false)
        #expect(await fixture.dispatcher.call(
            "trash_document",
            arguments: .object([
                "document_id": .string(id),
                "expected_metadata_revision": .string(document.metadataRevision),
                "request_id": .string("r"),
            ]),
            access: readonly,
        ).isError)
        #expect(await fixture.call("get_app_state", ["unknown": .bool(true)]).value["error"]["code"]
            .string == "invalid_params")
        #expect(await fixture.call("unknown_tool", [:]).value["error"]["code"].string == "unknown_tool")
        let state = await fixture.dispatcher.call("get_app_state", arguments: .object([:]), access: readonly)
        #expect(!state.value["available_tools"].array.contains { $0.string == "apply_patch" })
        #expect(await fixture.call("list_documents", ["limit": .number(0)]).isError)
        #expect(await fixture.call("list_documents", ["include_trashed": .string("true")]).isError)
        for path in ["../other", "/etc/passwd", "x/../main.typ", ".leftblank.json", "x\\y", "x//y"] {
            #expect(await fixture.call("read_file", ["document_id": .string(id), "path": .string(path)]).isError)
        }
        let outside = fixture.root.appendingPathComponent("outside.typ")
        try Data("Secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: document.folderURL.appendingPathComponent("link.typ"),
            withDestinationURL: outside,
        )
        #expect(await fixture.call("read_file", ["document_id": .string(id), "path": .string("link.typ")])
            .value["error"]["code"].string == "unsafe_path")
        #expect(await fixture.call("list_files", ["document_id": .string(id)]).value["incomplete"]
            .foundationValue as? Bool == true)
        _ = try await fixture.library.rename(document.id, title: "Changed by user")
        #expect(await fixture.call(
            "rename_document",
            [
                "document_id": .string(id),
                "title": .string("Wrong"),
                "expected_metadata_revision": .string(document.metadataRevision),
                "request_id": .string("rename"),
            ],
        ).isError)
        #expect(try await fixture.library.read(document.id).document.title == "Changed by user")
    }

    @Test func paginationSearchAndLongLineReadsStayBoundedAndInvalidate() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let original = String(repeating: "😀", count: 20000) + "\nneedle needle\n"
        let document = try await fixture.library.create(
            title: "Search",
            text: original,
            assets: ["chapter.typ": Data("= Chapter\nneedle\n".utf8)],
        )
        let id = document.id.uuidString
        var read: [String: JSONValue] = ["document_id": .string(id), "path": .string("main.typ")]
        let first = await fixture.call("read_file", read)
        #expect(first.value["text"].string?.utf16.count == 32768)
        read["cursor"] = first.value["next_cursor"]
        let second = await fixture.call("read_file", read)
        #expect((first.value["text"].string ?? "") + (second.value["text"].string ?? "") == original)
        var listing: [String: JSONValue] = ["document_id": .string(id), "limit": .number(1)]
        let files = await fixture.call("list_files", listing)
        #expect(files.value["items"].array.count == 1)
        listing["cursor"] = files.value["next_cursor"]
        #expect(await fixture.call("list_files", listing).value["items"].array.count == 1)
        let search = await fixture.call(
            "search_text",
            ["document_id": .string(id), "query": .string("needle"), "context_lines": .number(0)],
        )
        #expect(search.value["items"].array.count == 3)
        #expect(search.value["items"].array.first?["position_encoding"].string == "utf-16")
        #expect(await fixture.call(
            "search_text",
            ["document_id": .string(id), "query": .string("["), "mode": .string("regex")],
        ).isError)
        let regex = await fixture.call(
            "search_text",
            [
                "document_id": .string(id),
                "query": .string("NEE.LE"),
                "mode": .string("regex"),
                "case_sensitive": .bool(false),
                "paths": .array([.string("chapter.*")]),
            ],
        )
        #expect(regex.value["items"].array.count == 1)
        try Data("changed".utf8).write(to: document.sourceURL)
        #expect(await fixture.call("read_file", read).value["error"]["code"].string == "cursor_expired")
        #expect(await fixture.call("list_files", listing).value["error"]["code"].string == "cursor_expired")
    }

    @Test func patchesAreValidatedBeforeWritesAndPartialFailureIsExplicit() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Patch", text: "A\nB\nA\nB\n")
        let id = document.id.uuidString
        let read = await fixture.call("read_file", ["document_id": .string(id), "path": .string("main.typ")])
        let ambiguous = await fixture.call(
            "str_replace",
            [
                "document_id": .string(id),
                "path": .string("main.typ"),
                "old_str": .string("A"),
                "new_str": .string("X"),
                "expected_revision": read.value["revision"],
                "request_id": .string("ambiguous"),
            ],
        )
        #expect(ambiguous.value["error"]["code"].string == "ambiguous_match")
        let badPatch = await fixture.call(
            "apply_patch",
            [
                "document_id": .string(id),
                "expected_revisions": .object(["a.typ": .null, "main.typ": read.value["revision"]]),
                "input": .string(
                    "*** Begin Patch\n*** Add File: a.typ\n+ok\n*** Update File: main.typ\n@@\n-missing\n+new\n*** End Patch",
                ),
                "request_id": .string("bad"),
            ],
        )
        #expect(badPatch.isError && fixture.host.writes == 0)
        #expect(!FileManager.default.fileExists(atPath: document.folderURL.appendingPathComponent("a.typ").path))
        fixture.host.failPath = "b.typ"
        let partial = await fixture.call(
            "apply_patch",
            [
                "document_id": .string(id),
                "expected_revisions": .object(["a.typ": .null, "b.typ": .null]),
                "input": .string(
                    "*** Begin Patch\n*** Add File: a.typ\n+ok\n*** Add File: b.typ\n+later\n*** End Patch",
                ),
                "request_id": .string("partial"),
            ],
        )
        #expect(partial.isError)
        #expect(partial.value["status"].string == "partially_applied")
        #expect(partial.value["files"].array.count == 1)
    }

    @Test func lineLimitsHandleCRLFAndLargeCombiningSequences() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Lines", text: "One\r\nTwo\r\n")
        let arguments: [String: JSONValue] = [
            "document_id": .string(document.id.uuidString),
            "path": .string("main.typ"),
            "max_lines": .number(1),
        ]
        let first = await fixture.call("read_file", arguments)
        #expect(first.value["text"].string == "One\r\n")
        let pathological = "a" + String(repeating: "\u{0301}", count: 40000)
        try Data(pathological.utf8).write(to: document.sourceURL)
        let bounded = await fixture.call("read_file", arguments)
        #expect(bounded.value["text"].string?.utf16.count == 32768)
        #expect(AgentTools.excerpt(pathological, limit: 300).unicodeScalars.count == 300)
    }

    @Test func exactPatchHunksHandleUnicodeCRLFAndAmbiguity() throws {
        let patch = "*** Begin Patch\n*** Update File: main.typ\n@@\n A\r\n-B 😀\r\n+C 中文\r\n*** End of File\n*** End Patch"
        #expect(try AgentPatch.parse(patch, sources: ["main.typ": "A\r\nB 😀\r\n"]).first?.text == "A\r\nC 中文\r\n")
        #expect(throws: AgentToolError.self) { try AgentPatch.parse(
            "*** Begin Patch\n*** Update File: a.typ\n@@\n-A\n+B\n*** End Patch",
            sources: ["a.typ": "A\nA\n"],
        ) }
        #expect(try AgentPatch.parse(
            "*** Begin Patch\n*** Update File: a.typ\n@@\n+Hello\n*** End Patch",
            sources: ["a.typ": ""],
        ).first?.text == "Hello\n")
        #expect(try AgentPatch.parse(
            "*** Begin Patch\n*** Update File: a.typ\n@@\n-A\n+B\n*** End Patch",
            sources: ["a.typ": "A"],
        ).first?.text == "B")
    }
}

@MainActor
private final class AgentFixture {
    let root: URL
    let library: DocumentLibrary
    let history: DocumentHistory
    let host = DiskAgentHost()
    let dispatcher: AgentToolDispatcher
    let access = AgentToolAccess(documentIDs: nil, canWrite: true)
    init() throws {
        root = TestPaths.temporaryDirectory.appendingPathComponent("agent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = DocumentLibrary(rootURL: root.appendingPathComponent("Library"))
        history = DocumentHistory(root: root.appendingPathComponent("History"))
        dispatcher = AgentToolDispatcher(library: library, history: history, host: host)
    }

    func call(_ name: String, _ arguments: [String: JSONValue]) async -> AgentToolResult {
        await dispatcher.call(name, arguments: .object(arguments), access: access)
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class DiskAgentHost: AgentToolHost {
    var writes = 0
    var failPath: String?
    func agentState() -> JSONValue {
        .object(["platform": .string("test"), "open_documents": .array([])])
    }

    func agentLiveText(in document: LibraryDocument) -> (path: String, text: String)? {
        nil
    }

    func agentValidate(_ changes: [AgentPatch.Change], document: LibraryDocument) {}
    func agentApply(_ change: AgentPatch.Change, before: Data?, document: LibraryDocument) throws -> String {
        if change.path == failPath {
            throw AgentToolError("injected_failure", "Test failure")
        }
        try AgentProjectFiles.write(change.text, path: change.path, root: document.folderURL, expected: before)
        writes += 1
        return "saved"
    }

    func agentPrepareMetadataChange(_ document: LibraryDocument?, trashing: Bool) {}
    func agentFinishMetadataChange(_ document: LibraryDocument?) async {
        await Task.yield()
    }

    func agentDiagnostics(in document: LibraryDocument) -> [JSONValue] {
        []
    }

    func agentCompile(_ snapshot: AgentProjectSnapshot, entry: String) async -> JSONValue {
        await Task.yield()
        return .object(["status": .string("unverified")])
    }
}
