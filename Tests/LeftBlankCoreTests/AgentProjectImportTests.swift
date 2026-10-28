import Foundation
@testable import LeftBlankCore
import Testing

@MainActor
struct AgentProjectImportTests {
    @Test func importPreservesNestedEntryResourcesAndRevisions() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let binary = Data([0, 255, 10, 3, 4, 5])
        let arguments = upload(files: [
            text("book/main.typ", "#include \"../chapters/intro.typ\"\n"),
            text("chapters/intro.typ", "= Introduction\nHello 中文"),
            .object(["path": .string("assets/image.bin"), "data_base64": .string(binary.base64EncodedString())]),
            .object(["path": .string("assets/empty.bin"), "data_base64": .string("")]),
        ], entry: "book/main.typ")
        let imported = await fixture.call("import_project", arguments)
        #expect(!imported.isError)
        #expect(imported.value["status"].string == "applied")
        #expect(imported.value["path_base"].string == "document_root")
        #expect(imported.value["document"]["entry"].string == "book/main.typ")
        let id = try #require(imported.value["document"]["document_id"].string)
        let metadata = await fixture.call("get_document", ["document_id": .string(id)])
        #expect(metadata.value["project_revision"].string == imported.value["project_revision"].string)
        let read = await fixture.call("read_file", ["document_id": .string(id), "path": .string("chapters/intro.typ")])
        #expect(read.value["text"].string == "= Introduction\nHello 中文")
        let chapter = try #require(imported.value["files"].array.first {
            $0["path"].string == "chapters/intro.typ"
        })
        #expect(chapter["after_revision"].string == read.value["revision"].string)
        #expect(chapter["path_base"].string == "document_root")
        let document = try #require(try await fixture.library.list().first)
        #expect(try Data(contentsOf: document.folderURL.appendingPathComponent("assets/image.bin")) == binary)
        #expect(try Data(contentsOf: document.folderURL.appendingPathComponent("assets/empty.bin")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: document.folderURL.appendingPathComponent("Project").path))
        let listing = await fixture.call("list_files", ["document_id": .string(id)])
        #expect(listing.value["items"].array.compactMap { $0["path"].string } == [
            "assets/empty.bin", "assets/image.bin", "book/main.typ", "chapters/intro.typ",
        ])
        let compile = await fixture.call("compile_document", [
            "document_id": .string(id), "expected_project_revision": imported.value["project_revision"],
        ])
        #expect(!compile.isError)
        let retry = await fixture.call("import_project", arguments)
        #expect(retry.value["document"]["document_id"].string == id)
        #expect(try await fixture.library.list().count == 1)
    }

    @Test func invalidManifestLeavesNoPartialDocumentsOrStagingDirectories() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let invalid: [[JSONValue]] = [
            [text("../outside.typ", "bad")],
            [text("/main.typ", "bad")],
            [text(".leftblank.json", "bad")],
            [text("document.json", "metadata is not a project file")],
            [text("Document.json/child.typ", "reserved metadata parent")],
            [text("hidden/.secret", "bad")],
            [text("a\\main.typ", "bad")],
            [text("main.typ", "one"), text("main.typ", "two")],
            [text("main.typ", "one"), text("MAIN.typ", "two")],
            [text("main.typ", "one"), text("a", "file"), text("a/b.typ", "child")],
            [text("main.typ", "one"), text("Dir/a.typ", "a"), text("dir/b.typ", "b")],
            [text("main.typ", "one"), text("caf\u{00e9}/a.typ", "a"), text("cafe\u{0301}/b.typ", "b")],
            [text("other.typ", "entry missing")],
            [.object(["path": .string("main.typ"), "text": .string("x"), "data_base64": .string("eA==")])],
            [.object(["path": .string("main.typ")])],
            [.object(["path": .string("main.typ"), "data_base64": .string("not base64")])],
            [.object(["path": .string("main.typ"), "data_base64": .string(Data([0, 255]).base64EncodedString())])],
        ]
        for (index, files) in invalid.enumerated() {
            let result = await fixture.call("import_project", upload(files: files, request: "invalid-\(index)"))
            #expect(result.isError)
            #expect(try await fixture.library.list(includeTrashed: true).isEmpty)
            try expectNoStaging(fixture)
        }
        // A corrected import is independent of rejected requests and can immediately succeed.
        let repaired = await fixture.call(
            "import_project",
            upload(files: [text("main.typ", "Repaired")], request: "repair"),
        )
        #expect(!repaired.isError)
        #expect(try await fixture.library.list().count == 1)
        try expectNoStaging(fixture)
    }

    @Test func importRequiresLibraryWideWriteAccess() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Existing", text: "Keep this")
        for access in [AgentToolAccess(documentIDs: nil, canWrite: false),
                       AgentToolAccess(documentIDs: [document.id], canWrite: true)]
        {
            let result = await fixture.dispatcher.call(
                "import_project",
                arguments: .object(upload(files: [text("main.typ", "New")])),
                access: access,
            )
            #expect(result.isError)
            #expect(result.value["error"]["code"].string == "permission_denied")
        }
        #expect(try await fixture.library.list().count == 1)
        #expect(try await fixture.library.read(document.id).text == "Keep this")
    }

    @Test func entryAndUploadLimitsAreExplicitBeforePublication() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let oversizedText = String(repeating: "x", count: AgentTools.maximumTextBytes + 1)
        let oversizedEntry = await fixture.call("import_project", upload(files: [text("main.typ", oversizedText)]))
        #expect(oversizedEntry.isError)
        let payload = String(repeating: "x", count: AgentTools.maximumTextBytes)
        let oversizedManifest = await fixture.call("import_project", upload(files: [
            text("main.typ", payload), text("a.typ", payload), text("b.typ", payload),
        ], request: "oversized-manifest"))
        #expect(oversizedManifest.isError)
        #expect(oversizedManifest.value["error"]["code"].string == "project_too_large")
        #expect(oversizedManifest.value["error"]["maximum_bytes"].int == AgentProjectImport.maximumPayloadBytes)
        #expect(try await fixture.library.list().isEmpty)
        try expectNoStaging(fixture)
    }

    @Test func fileAndFolderBudgetIncludesImplicitDirectories() throws {
        let deepFiles = (0 ..< 1000).map { text("folder-\($0)/file.typ", "") }
        let valid = try AgentProjectImport(entry: "folder-0/file.typ", files: deepFiles)
        #expect(valid.files.count == 1000)
        #expect(throws: AgentToolError.self) {
            try AgentProjectImport(entry: "folder-0/file.typ", files: deepFiles + [text("extra.typ", "")])
        }
    }

    @Test func directManifestValidationRejectsUnknownFieldsAndWrongPayloadTypes() throws {
        for file: JSONValue in [
            .string("not an object"),
            .object(["path": .string("main.typ"), "text": .number(1)]),
            .object(["path": .string("main.typ"), "data_base64": .bool(true)]),
            .object(["path": .string("main.typ"), "text": .string("x"), "symlink": .string("elsewhere")]),
        ] {
            #expect(throws: AgentToolError.self) { try AgentProjectImport(entry: "main.typ", files: [file]) }
        }
        #expect(throws: AgentToolError.self) {
            try AgentProjectImport(entry: "main.txt", files: [text("main.txt", "x")])
        }
        #expect(throws: AgentToolError.self) { try AgentProjectImport(entry: "main.typ", files: []) }
        #expect(throws: AgentToolError.self) {
            try AgentProjectImport(entry: "main.typ", files: [text("main.typ", "\0")])
        }
    }

    @Test func invalidTitleAndCancelledImportDoNotPublishFiles() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        var arguments = upload(files: [text("main.typ", "Hello")])
        arguments["title"] = .string(String(repeating: "x", count: 201))
        #expect(await fixture.call("import_project", arguments).isError)
        let manifest = try AgentProjectImport(entry: "main.typ", files: [text("main.typ", "Cancelled")])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.library.importProject(title: "Cancelled", manifest: manifest)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled import was published.")
        } catch is CancellationError {}
        #expect(try await fixture.library.list().isEmpty)
        try expectNoStaging(fixture)
    }

    private func text(_ path: String, _ value: String) -> JSONValue {
        .object(["path": .string(path), "text": .string(value)])
    }

    private func upload(
        files: [JSONValue],
        entry: String = "main.typ",
        request: String = "import",
    ) -> [String: JSONValue] {
        [
            "title": .string("Uploaded project"),
            "entry": .string(entry),
            "files": .array(files),
            "request_id": .string(request),
        ]
    }

    private func expectNoStaging(_ fixture: AgentFixture) throws {
        let directory = fixture.root.appendingPathComponent("Library/Documents")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasPrefix(".pending-") })
    }
}
