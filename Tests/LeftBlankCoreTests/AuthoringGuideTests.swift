import Foundation
@testable import LeftBlankCore
import Testing

@MainActor
struct AuthoringGuideTests {
    @Test func discoveryIsReadOnlyAndAvailableWithoutDocumentAccess() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let access = AgentToolAccess(documentIDs: [], canWrite: false)
        let listed = await fixture.dispatcher.call("list_authoring_guides", arguments: .object([:]), access: access)
        #expect(!listed.isError)
        let ids = listed.value["items"].array.compactMap { $0["id"].string }
        #expect(ids.contains("dimensional-drawing") && ids.contains("xiaohei-illustrations"))
        let read = await fixture.dispatcher.call("read_authoring_guide", arguments: .object([
            "id": .string("xiaohei-illustrations"),
        ]), access: access)
        #expect(!read.isError)
        #expect(read.value["path"].string == "guide.md")
        #expect(read.value["text"].string?.isEmpty == false)
        #expect(fixture.host.writes == 0)
        #expect(try await fixture.library.list().isEmpty)
        for name in ["list_authoring_guides", "read_authoring_guide"] {
            #expect(AgentTools.definitions.first { $0.name == name }?.readOnly == true)
        }
    }

    @Test func bilingualSearchAndPaginationUseTheExistingQueryContract() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        for query in ["DIMENSIONAL", "工业", "xiaohei", "小黑"] {
            let result = await fixture.call("list_authoring_guides", ["query": .string(query)])
            #expect(!result.isError)
            #expect(!result.value["items"].array.isEmpty)
        }
        let absent = await fixture.call("list_authoring_guides", ["query": .string("unsupported-guide-xyz")])
        #expect(absent.value["items"].array.isEmpty)
        let first = await fixture.call("list_authoring_guides", ["limit": .number(1)])
        #expect(first.value["items"].array.count == 1)
        let cursor = try #require(first.value["next_cursor"].string)
        let next = await fixture.call("list_authoring_guides", ["limit": .number(1), "cursor": .string(cursor)])
        #expect(next.value["items"].array.count == 1)
        #expect(next.value["items"].array.first?["id"].string != first.value["items"].array.first?["id"].string)
        let changed = await fixture.call("list_authoring_guides", [
            "query": .string("xiaohei"), "limit": .number(1), "cursor": .string(cursor),
        ])
        #expect(changed.value["error"]["code"].string == "cursor_expired")
    }

    @Test func bundledFilesHaveUniquePathsAndRunnableExamples() throws {
        let rows = try AuthoringGuides.list()
        let ids = rows.compactMap { $0["id"].string }
        #expect(Set(ids).count == rows.count)
        for id in ids {
            let guide = try AuthoringGuides.read(id: id)
            #expect(guide["guide"]["version"].string?.isEmpty == false)
            let files = guide["files"].array
            let paths = files.compactMap { $0["path"].string }
            #expect(Set(paths).count == files.count)
            #expect(paths.contains("guide.md") && paths.contains("license.txt"))
            #expect(files.contains { $0["entrypoint"].foundationValue as? Bool == true })
            for path in paths {
                let file = try AuthoringGuides.read(id: id, path: path)
                let source = try #require(file["text"].string)
                #expect(!source.isEmpty && source.utf8.count <= AuthoringGuides.maximumFileBytes)
                #expect(file["path"].string == path)
            }
        }
    }

    @Test func guideSelectorsCannotReadProjectOrHostFiles() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let missing = await fixture.call("read_authoring_guide", ["id": .string("arxiv-not-yet-shipped")])
        #expect(missing.value["error"]["code"].string == "not_found")
        #expect(missing.value["error"]["suggested_tool"].string == "list_authoring_guides")
        for path in ["../guide.md", "/etc/passwd", "main.typ/../guide.md", "authoring-guides.json", ""] {
            let result = await fixture.call("read_authoring_guide", [
                "id": .string("dimensional-drawing"), "path": .string(path),
            ])
            #expect(result.value["error"]["code"].string == "not_found")
        }
        #expect(await fixture.call("read_authoring_guide", [:]).value["error"]["code"].string == "invalid_params")
        #expect(await fixture.call("list_authoring_guides", ["document_id": .string("x")])
            .value["error"]["code"].string == "invalid_params")
    }

    @Test func startersCanBeMaterializedThroughExistingDocumentTools() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let listed = await fixture.call("list_authoring_guides", [:])
        for row in listed.value["items"].array {
            let id = try #require(row["id"].string)
            let guide = await fixture.call("read_authoring_guide", ["id": .string(id)])
            let main = await fixture.call("read_authoring_guide", ["id": .string(id), "path": .string("main.typ")])
            let created = await fixture.call("create_document", [
                "title": .string(id), "source": main.value["text"], "request_id": .string(id + "-create"),
            ])
            #expect(!created.isError)
            let document = created.value["document"]["document_id"]
            var revisions: [String: JSONValue] = [:]
            var patch = "*** Begin Patch\n"
            for file in guide.value["files"].array where file["path"].string != "main.typ" {
                let path = try #require(file["path"].string)
                let content = await fixture.call("read_authoring_guide", ["id": .string(id), "path": .string(path)])
                let text = try #require(content.value["text"].string)
                revisions[path] = .null
                patch += "*** Add File: \(path)\n" + text.components(separatedBy: "\n").map { "+" + $0 }
                    .joined(separator: "\n") + "\n"
            }
            patch += "*** End Patch"
            let applied = await fixture.call("apply_patch", [
                "document_id": document, "input": .string(patch), "expected_revisions": .object(revisions),
                "request_id": .string(id + "-files"),
            ])
            #expect(!applied.isError, "\(applied.value)")
            let read = await fixture.call("read_file", ["document_id": document, "path": .string("main.typ")])
            #expect(read.value["text"].string == main.value["text"].string)
        }
    }
}
