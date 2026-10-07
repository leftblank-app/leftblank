import CoreGraphics
import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing
import UniformTypeIdentifiers

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

    @Test func writeResultsShowEachChangedRegion() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let source = (1 ... 40).map { "第\($0)行" }.joined(separator: "\n") + "\n"
        let document = try await fixture.library.create(title: "Diff", text: source)
        let id = JSONValue.string(document.id.uuidString)
        let read = await fixture.call("read_file", ["document_id": id, "path": .string("main.typ")])
        let replaced = await fixture.call("str_replace", [
            "document_id": id, "path": .string("main.typ"), "old_str": .string("第20行"),
            "new_str": .string("第二十行 😀"), "expected_revision": read.value["revision"],
            "request_id": .string("diff-replace"),
        ])
        let diff = replaced.value["files"].array.first?["diff"] ?? .null
        #expect(diff["abbreviated"].foundationValue as? Bool == false)
        let hunk = try #require(diff["hunks"].array.first)
        #expect(diff["hunks"].array.count == 1)
        #expect(hunk["before_start_line"].int == 17 && hunk["after_line_count"].int == 7)
        #expect(hunk["text"].string == " 第17行\n 第18行\n 第19行\n-第20行\n+第二十行 😀\n 第21行\n 第22行\n 第23行\n")
        let patched = await fixture.call("apply_patch", [
            "document_id": id, "request_id": .string("diff-patch"),
            "expected_revisions": .object([
                "main.typ": replaced.value["files"].array.first?["after_revision"] ?? .null,
                "new.typ": .null,
            ]),
            "input": .string(
                "*** Begin Patch\n*** Update File: main.typ\n@@\n 第2行\n-第3行\n+三\n@@\n 第35行\n-第36行\n" +
                    "*** Add File: new.typ\n+新文件\n*** End Patch",
            ),
        ])
        #expect(!patched.isError)
        let files = patched.value["files"].array
        let hunks = files.first { $0["path"].string == "main.typ" }?["diff"]["hunks"].array ?? []
        #expect(hunks.map { $0["before_start_line"].int } == [1, 33])
        #expect(hunks.last?["after_line_count"].int == 6)
        #expect(hunks.last?["text"].string?.contains("-第36行\n 第37行") == true)
        let added = files.first { $0["path"].string == "new.typ" }?["diff"]["hunks"].array.first
        #expect(added?["text"].string == "+新文件\n" && added?["before_line_count"].int == 0)
    }

    @Test func unreadableFilesExplainWhyAndWhatToUseInstead() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Files", text: "= Files\n")
        let folder = document.folderURL
        try #require(testImage(width: 2, height: 2, type: .png)).write(to: folder.appendingPathComponent("figure.png"))
        try Data([0, 1, 2, 255]).write(to: folder.appendingPathComponent("data.bin"))
        let large = String(repeating: "长行 0123456789\n", count: 160_000)
        try Data(large.utf8).write(to: folder.appendingPathComponent("large.txt"))
        func read(_ path: String, _ extra: [String: JSONValue] = [:]) async -> AgentToolResult {
            await fixture.call(
                "read_file",
                ["document_id": .string(document.id.uuidString), "path": .string(path)]
                    .merging(extra) { _, new in new },
            )
        }
        let image = await read("figure.png")
        #expect(image.value["error"]["code"].string == "not_text")
        #expect(image.value["error"]["suggested_tool"].string == "read_image")
        #expect(image.value["error"]["message"].string?.contains("read_image") == true)
        let binary = await read("data.bin")
        #expect(binary.value["error"]["code"].string == "not_text" && binary.value["error"]["suggested_tool"].isNull)
        let missing = await read("missing.typ")
        #expect(missing.value["error"]["code"].string == "not_found")
        #expect(missing.value["error"]["suggested_tool"].string == "list_files")
        // Text past the 2 MiB edit limit is read in windows but cannot be edited.
        #expect(large.utf8.count > AgentTools.maximumTextBytes)
        let window = await read("large.txt", ["start_line": .number(150_000), "max_lines": .number(2)])
        #expect(!window.isError && window.value["text"].string == "长行 0123456789\n长行 0123456789\n")
        #expect(window.value["truncated"].foundationValue as? Bool == true)
        let edit = await fixture.call("str_replace", [
            "document_id": .string(document.id.uuidString), "path": .string("large.txt"),
            "old_str": .string("长行"), "new_str": .string("短"), "expected_revision": window.value["revision"],
            "request_id": .string("large-edit"),
        ])
        #expect(edit.value["error"]["code"].string == "file_too_large")
        #expect(edit.value["error"]["message"].string?.contains("start_line") == true)
    }

    @Test func patchMismatchNamesTheHunkAndPartialLines() throws {
        func failure(_ body: String, source: String) -> AgentToolError? {
            do {
                _ = try AgentPatch.parse(
                    "*** Begin Patch\n*** Update File: main.typ\n" + body + "*** End Patch",
                    sources: ["main.typ": source],
                )
                return nil
            } catch { return error as? AgentToolError }
        }
        let paragraph = "这是一段很长的中文段落，" + String(repeating: "包含许多内容", count: 30) + "。"
        let source = "= 标题\n\n" + paragraph + "\n结尾\n"
        let partial = try #require(failure("@@\n-= 标题\n+= 新标题\n@@\n-包含许多内容\n+新\n", source: source))
        #expect(partial.code == "patch_mismatch")
        #expect(partial.details["hunk"]?.int == 2 && partial.details["matches"]?.int == 0)
        #expect(partial.details["partial_line_match"]?.int == 3)
        #expect(partial.message.contains("Hunk 2 in main.typ") && partial.message.contains("part of file line 3"))
        let long = try #require(failure("@@\n-" + paragraph + "X\n+新\n", source: source))
        #expect(long.details["first_line"]?.string?.hasSuffix("…") == true)
        #expect(long.details["unmatched_line"]?.string.map { $0.count <= 81 } == true)
        #expect(long.message.contains("does not occur"))
        let repeated = try #require(failure("@@\n-x\n+y\n", source: "x\nx\n"))
        #expect(repeated.details["matches"]?.int == 2 && repeated.message.contains("matched 2 times"))
        let spaced = try #require(failure("@@\n-结尾 \n+完\n", source: source))
        #expect(spaced.details["whitespace_mismatch_line"]?.int == 4)
        let order = try #require(failure("@@\n-结尾\n-= 标题\n+x\n", source: source))
        #expect(order.message.contains("not consecutively"))
        let anchor = try #require(failure("@@ x\n-y\n+z\n", source: "x\ny\nx\ny\n"))
        #expect(anchor.code == "ambiguous_match" && anchor.details["hunk"]?.int == 1)
    }

    @Test func readImageReturnsViewableImagesAndConvertsOtherFormats() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let document = try await fixture.library.create(title: "Images", text: "#image(\"a.png\")\n")
        let png = try #require(testImage(width: 3, height: 2, type: .png))
        try png.write(to: document.folderURL.appendingPathComponent("a.png"))
        try #require(testImage(width: 4, height: 4, type: .tiff))
            .write(to: document.folderURL.appendingPathComponent("b.tiff"))
        try #require(testImage(width: 3000, height: 1000, type: .png))
            .write(to: document.folderURL.appendingPathComponent("wide.png"))
        func read(_ path: String) async -> AgentToolResult {
            await fixture.call("read_image", ["document_id": .string(document.id.uuidString), "path": .string(path)])
        }
        let original = await read("a.png")
        #expect(original.images == [AgentToolImage(data: png, mimeType: "image/png")])
        #expect(original.value["mime_type"].string == "image/png")
        #expect(original.value["width"].int == 3 && original.value["height"].int == 2)
        #expect(original.value["converted"].foundationValue as? Bool == false)
        #expect(original.value["revision"].string?.isEmpty == false)
        let tiff = await read("b.tiff")
        #expect(tiff.images.first?.mimeType == "image/png")
        #expect(tiff.value["converted"].foundationValue as? Bool == true)
        #expect(tiff.images.first.flatMap { try? AgentImage.prepare($0.data) }?.width == 4)
        let wide = await read("wide.png")
        #expect(wide.value["converted"].foundationValue as? Bool == true)
        #expect(wide.value["width"].int == AgentImage.maximumEdge)
        #expect((wide.value["height"].int ?? .max) < 700)
        #expect(await read("main.typ").value["error"]["code"].string == "not_image")
        #expect(await read("missing.png").value["error"]["code"].string == "unavailable")
        #expect(await read("../a.png").value["error"]["code"].string == "unsafe_path")
        #expect(await read("main.typ").images.isEmpty)
    }

    @Test func gateAdmitsReadersTogetherWritersAloneInArrivalOrder() async {
        let gate = AgentToolGate()
        #expect(await gate.acquire(exclusive: false))
        #expect(await gate.acquire(exclusive: false))
        #expect(gate.shared == 2)
        let writer = Task { await gate.acquire(exclusive: true) }
        while gate.waiters.count < 1 {
            await Task.yield()
        }
        // A reader arriving after a waiting writer queues behind it instead of starving it.
        let lateReader = Task { await gate.acquire(exclusive: false) }
        while gate.waiters.count < 2 {
            await Task.yield()
        }
        gate.release(exclusive: false)
        #expect(!gate.exclusive && gate.waiters.count == 2)
        gate.release(exclusive: false)
        #expect(await writer.value)
        #expect(gate.exclusive && gate.shared == 0 && gate.waiters.count == 1)
        gate.release(exclusive: true)
        #expect(await lateReader.value)
        #expect(!gate.exclusive && gate.shared == 1 && gate.waiters.isEmpty)
        gate.release(exclusive: false)
    }

    @Test func gateCancelledWaitersLeaveWithoutBlockingOthers() async {
        let gate = AgentToolGate()
        #expect(await gate.acquire(exclusive: true))
        let first = Task { await gate.acquire(exclusive: false) }
        while gate.waiters.count < 1 {
            await Task.yield()
        }
        let writer = Task { await gate.acquire(exclusive: true) }
        while gate.waiters.count < 2 {
            await Task.yield()
        }
        let second = Task { await gate.acquire(exclusive: false) }
        while gate.waiters.count < 3 {
            await Task.yield()
        }
        writer.cancel()
        #expect(await writer.value == false)
        gate.release(exclusive: true)
        // With the writer gone, both readers are admitted together.
        let admitted = await (first.value, second.value)
        #expect(admitted == (true, true))
        #expect(gate.shared == 2 && gate.waiters.isEmpty)
    }

    @Test func readToolsRunBesideOtherReadsAndWritesWaitForThem() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let dispatcher = fixture.dispatcher
        // An in-flight read holds the gate.
        #expect(await dispatcher.gate.acquire(exclusive: false))
        #expect(await !fixture.call("list_documents", [:]).isError)
        #expect(await !fixture.call("get_app_state", [:]).isError)
        let write = Task {
            await fixture.call(
                "create_document",
                ["title": .string("Queued"), "source": .string("Hi"), "request_id": .string("queued")],
            )
        }
        while dispatcher.gate.waiters.count < 1 {
            await Task.yield()
        }
        #expect(try await fixture.library.list().isEmpty)
        dispatcher.gate.release(exclusive: false)
        #expect(await !write.value.isError)
        #expect(try await fixture.library.list().count == 1)
        // Compiles are reads, but each starts an engine, so they take turns.
        #expect(await dispatcher.compiles.acquire(exclusive: true))
        let document = try #require(try await fixture.library.list().first)
        let metadata = await fixture.call("get_document", ["document_id": .string(document.id.uuidString)])
        let compile = Task {
            await fixture.call("compile_document", [
                "document_id": .string(document.id.uuidString),
                "expected_project_revision": metadata.value["project_revision"],
            ])
        }
        while dispatcher.compiles.waiters.count < 1 {
            await Task.yield()
        }
        #expect(await !fixture.call("list_documents", [:]).isError)
        dispatcher.compiles.release(exclusive: true)
        #expect(await compile.value.value["status"].string == "unverified")
        #expect(dispatcher.gate.shared == 0 && !dispatcher.gate.exclusive && dispatcher.compiles.waiters.isEmpty)
    }

    @Test func everyToolParameterHasAMeaningfulDescription() {
        func undescribed(_ schema: JSONValue, name: String) -> [String] {
            let description = schema["description"].string ?? ""
            var missing = description.isEmpty || description == name.components(separatedBy: ".").last ? [name] : []
            for (key, field) in schema["properties"].objectValues.sorted(by: { $0.key < $1.key }) {
                missing += undescribed(field, name: name + "." + key)
            }
            if case .object = schema["items"] {
                missing += undescribed(schema["items"], name: name + "[]")
            }
            if case .object = schema["additionalProperties"] {
                missing += undescribed(schema["additionalProperties"], name: name + "{}")
            }
            return missing
        }
        for tool in AgentTools.definitions {
            #expect(!tool.description.isEmpty, "\(tool.name) needs a description")
            let missing = tool.inputSchema["properties"].objectValues.sorted { $0.key < $1.key }
                .flatMap { undescribed($0.value, name: tool.name + "." + $0.key) }
            #expect(missing.isEmpty, "Describe \(missing.joined(separator: ", "))")
        }
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

func testImage(width: Int, height: Int, type: UTType) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
          )
    else {
        return nil
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage().flatMap { AgentImage.encode($0, type: type, quality: 1) }
}

@MainActor
final class AgentFixture {
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
final class DiskAgentHost: AgentToolHost {
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

    var exports: [AgentEngineExport] = []
    var exportOutput: (AgentEngineExport) -> AgentEngineOutput = { _ in AgentEngineOutput(status: .engineUnavailable) }
    var engines = 0
    func agentEngine<T>(
        _ snapshot: AgentProjectSnapshot,
        entry: String,
        _ body: (any AgentEngineSession) async throws -> T,
    ) async throws -> T {
        await Task.yield()
        engines += 1
        return try await body(FakeEngineSession(host: self))
    }

    var editorContext: AgentEditorContext?
    func agentEditorContext(in document: LibraryDocument) -> AgentEditorContext? {
        editorContext
    }
}

@MainActor
private final class FakeEngineSession: AgentEngineSession {
    let host: DiskAgentHost
    init(host: DiskAgentHost) {
        self.host = host
    }

    func run(_ export: AgentEngineExport) -> AgentEngineOutput {
        host.exports.append(export)
        return host.exportOutput(export)
    }
}
