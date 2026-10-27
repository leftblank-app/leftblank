import Foundation
@testable import LeftBlankCore
import Testing

@MainActor
struct AuthoringGuideTests {
    @Test func discoverySeparatesContentFromDocumentTools() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let prompts = try AuthoringGuides.prompts()
        let names = prompts.compactMap { $0["name"].string }
        #expect(names.contains("dimensional-drawing") && names.contains("xiaohei-illustrations"))
        #expect(Set(names).count == prompts.count)
        #expect(prompts.contains { $0["description"].string?.contains("小黑") == true })
        let resources = try AuthoringGuides.resources()
        #expect(!resources.isEmpty)
        for prompt in prompts {
            let result = try AuthoringGuides.getPrompt(name: #require(prompt["name"].string), arguments: .object([
                "request": .string("请根据现有内容设计一张配图"),
            ]))
            #expect(!result["messages"].array.isEmpty)
        }
        #expect(AgentTools.definitions.allSatisfy { !$0.name.contains("authoring_guide") })
        #expect(fixture.host.writes == 0)
        #expect(try await fixture.library.list().isEmpty)
    }

    @Test func promptPreservesTheRequestAndEmbedsTheMatchingWorkflow() throws {
        let request = "画一个设备外壳，尺寸未知。\n保留 {{request}} 和中文，不推测测量值。"
        let result = try AuthoringGuides.getPrompt(name: "dimensional-drawing", arguments: .object([
            "request": .string(request),
        ]))
        let messages = result["messages"].array
        #expect(messages.last?["content"]["text"].string == "User request:\n" + request)
        let embedded = try #require(messages.first { $0["content"]["type"].string == "resource" })
        let uri = try #require(embedded["content"]["resource"]["uri"].string)
        let read = try AuthoringGuides.readResource(uri: uri)
        #expect(embedded["content"]["resource"]["text"].string == read["contents"].array.first?["text"].string)
        #expect(messages.first?["content"]["text"].string?.contains("product.typ") == true)
    }

    @Test func unmatchedRequestsCanDiscoverTheGeneralFallback() throws {
        let fallback = try #require(AuthoringGuides.prompts().first {
            $0["_meta"]["app.leftblank/authoringGuide"]["fallback"].foundationValue as? Bool == true
        })
        let result = try AuthoringGuides.getPrompt(name: #require(fallback["name"].string), arguments: .object([
            "request": .string("制作数学演示文稿"),
        ]))
        let embedded = try #require(result["messages"].array.first { $0["content"]["type"].string == "resource" })
        #expect(embedded["content"]["resource"]["text"].string?.contains("https://typst.app/universe/") == true)
    }

    @Test func bundledResourcesHaveUniqueURIsAndRunnableExamples() throws {
        let resources = try AuthoringGuides.resources()
        let uris = resources.compactMap { $0["uri"].string }
        #expect(Set(uris).count == resources.count)
        for prompt in try AuthoringGuides.prompts() {
            let files = resources.filter {
                $0["_meta"]["app.leftblank/authoringGuide"]["id"].string == prompt["name"].string
            }
            #expect(files.contains { $0["_meta"]["app.leftblank/entrypoint"].foundationValue as? Bool == true })
            let paths = files.compactMap { $0["_meta"]["app.leftblank/path"].string }
            #expect(paths.contains("guide.md") && paths.contains("license.txt"))
        }
        for descriptor in resources {
            let uri = try #require(descriptor["uri"].string)
            let read = try AuthoringGuides.readResource(uri: uri)
            let file = try #require(read["contents"].array.first)
            let source = try #require(file["text"].string)
            #expect(!source.isEmpty && source.utf8.count <= AuthoringGuides.maximumFileBytes)
            #expect(file["uri"].string == descriptor["uri"].string)
            #expect(file["mimeType"].string == descriptor["mimeType"].string)
        }
    }

    @Test func resourceSelectorsAndPromptArgumentsAreValidated() throws {
        for uri in [
            "file:///etc/passwd", "leftblank://guides/missing/guide.md",
            "leftblank://guides/dimensional-drawing/../catalog.json",
            "leftblank://guides/dimensional-drawing/%2e%2e/catalog.json",
            "leftblank://guides/dimensional-drawing/main.typ/../guide.md",
            "leftblank://guides/dimensional-drawing/../xiaohei-illustrations/main.typ", "",
        ] {
            #expect(throws: (any Error).self) { try AuthoringGuides.readResource(uri: uri) }
        }
        #expect(throws: (any Error).self) {
            try AuthoringGuides.getPrompt(name: "missing", arguments: .object(["request": .string("a")]))
        }
        for arguments: JSONValue in [
            .null, .object([:]), .object(["request": .string("  \n")]), .object(["request": .number(2)]),
            .object(["request": .string("a"), "unknown": .string("b")]),
            .object(["request": .string(String(repeating: "中", count: AuthoringGuides.maximumFileBytes))]),
        ] {
            #expect(throws: (any Error).self) {
                try AuthoringGuides.getPrompt(name: "dimensional-drawing", arguments: arguments)
            }
        }
    }

    @Test func startersCanBeMaterializedThroughExistingDocumentTools() async throws {
        let fixture = try AgentFixture()
        defer { fixture.close() }
        let resources = try AuthoringGuides.resources()
        for prompt in try AuthoringGuides.prompts() {
            let id = try #require(prompt["name"].string)
            let files = resources.filter { $0["_meta"]["app.leftblank/authoringGuide"]["id"].string == id }
            let main = try AuthoringGuides.readResource(uri: "leftblank://guides/\(id)/main.typ")["contents"].array[0]
            let created = await fixture.call("create_document", [
                "title": .string(id), "source": main["text"], "request_id": .string(id + "-create"),
            ])
            #expect(!created.isError)
            let document = created.value["document"]["document_id"]
            var revisions: [String: JSONValue] = [:]
            var patch = "*** Begin Patch\n"
            for file in files where file["_meta"]["app.leftblank/path"].string != "main.typ" {
                let path = try #require(file["_meta"]["app.leftblank/path"].string)
                let content = try AuthoringGuides.readResource(uri: #require(file["uri"].string))
                let text = try #require(content["contents"].array.first?["text"].string)
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
            #expect(read.value["text"].string == main["text"].string)
        }
    }
}
